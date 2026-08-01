#include "ssr/coordinator.hpp"
#include "ssr/proto_conversion.hpp"

#include <grpcpp/create_channel.h>
#include <grpcpp/security/credentials.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <exception>
#include <future>
#include <stdexcept>

namespace ssr {

namespace {
    // Internal helper functions can be defined here if needed
[[nodiscard]]
bool all_rpc_succeeded(const std::vector<AgentRPCResult>& results) noexcept
{
    return std::all_of(results.begin(), results.end(),
                       [](const AgentRPCResult& result) { return result.ok(); });
}

void set_local_error(AgentRPCResult& result, const grpc::StatusCode status_code, std::string message)
{
    result.status_code = status_code;
    result.message = std::move(message);
}

void validate_reply(AgentRPCResult& result,
                    const control::v1::AgentState expected_agent_state,
                    const control::v1::DataplaneState expected_dataplane_state)
{
    if (!result.ok()) {
        return;
    }

    if (result.reply.node_id() != static_cast<std::uint32_t>(result.node_id)) {
        set_local_error(result, grpc::StatusCode::DATA_LOSS,
                        "Node ID mismatch in reply");
        return;
    }

    if (result.reply.state() != expected_agent_state) {
        set_local_error(result, grpc::StatusCode::FAILED_PRECONDITION,
                        "Unexpected agent state in reply");
        return;
    }

    if (result.reply.has_dataplane_status()) {
        if (result.reply.dataplane_status().state() != expected_dataplane_state) {
            set_local_error(result, grpc::StatusCode::FAILED_PRECONDITION,
                            "Unexpected dataplane state in reply");
            return;
        }
    } else {
        set_local_error(result, grpc::StatusCode::DATA_LOSS,
                        "Missing dataplane status in reply");
        return;
    }
}

/*
 * 
 */
template<typename Function>
std::vector<AgentRPCResult> run_parallel(
    std::unordered_map<NodeId, AgentRPCClient>& agent_rpc_client_map,
    Function&& function
)
{
    std::vector<std::future<AgentRPCResult>> futures;
    futures.reserve(agent_rpc_client_map.size());

    for (auto& [node_id, agent_rpc_client] : agent_rpc_client_map) {
        AgentRPCClient* const agent_pointer = &agent_rpc_client;

        futures.push_back(std::async(std::launch::async, [agent_pointer, &function]() -> AgentRPCResult {
            try {
                return function(*agent_pointer);
            } catch (const std::exception& e) {
                AgentRPCResult result;
                result.node_id = agent_pointer->node_id;
                result.status_code = grpc::StatusCode::INTERNAL;
                result.message = e.what();
                return result;
            } catch (...) {
                AgentRPCResult result;
                result.node_id = agent_pointer->node_id;
                result.status_code = grpc::StatusCode::INTERNAL;
                result.message = "Unknown error";
                return result;
            }
        }));
    }

    std::vector<AgentRPCResult> results;
    results.reserve(futures.size());

    for (auto& future : futures) {
        results.push_back(future.get());
    }

    return results;
}

}

SSRCoordinator::SSRCoordinator(std::vector<AgentEndpoint> endpoints) {
        for (const auto& endpoint : endpoints) {
            agents_endpoints_.emplace(endpoint.node_id, endpoint);
            agent_rpc_client_map_.emplace(endpoint.node_id, AgentRPCClient{
                .node_id = endpoint.node_id,
                .channel = grpc::CreateChannel(endpoint.address, grpc::InsecureChannelCredentials()),
                .stub = control::v1::AgentService::NewStub(grpc::CreateChannel(endpoint.address, grpc::InsecureChannelCredentials()))
            });
        }
}

void SSRCoordinator::require_state(CoordinatorState expected, const char* const operation) const {
    const CoordinatorState actual = state();

    if (actual != expected) {
        throw std::runtime_error(
            std::string("Operation '") + operation + "' requires state " +
            std::to_string(static_cast<std::uint8_t>(expected)) +
            ", but current state is " +
            std::to_string(static_cast<std::uint8_t>(actual))
        );
    }
}

/*
 * Prepares the coordinator for operation.
 */
ClusterOptResult SSRCoordinator::agents_prepare(
    const SessionId& input_session_id,
    const RunConfig& run_config
) {
    printf("SSR::Coordinator::Prepare called with session_id: %lu-%lu\n", input_session_id.high, input_session_id.low);
    std::scoped_lock lock(operation_mutex_);

    require_state(CoordinatorState::Idle, "Prepare");
    session_id_ = input_session_id;

    // Run the prepare operation in parallel for all agents
    auto results = run_parallel(
        agent_rpc_client_map_,
        [this, &input_session_id, &run_config](AgentRPCClient& agent) {
            AgentRPCResult result{};
            result.node_id = agent.node_id;

            control::v1::PrepareRequest request;
            control::v1::AgentReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));
            session_id_to_proto(input_session_id, request.mutable_session_id());
            run_config_to_proto(run_config, request.mutable_run_config());

            grpc::ClientContext context;

            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            printf("SSR::Coordinator::Prepare::Node%u sending request\n", agent.node_id);
            const grpc::Status rpc_status = agent.stub->Prepare(&context, request, &reply);
            
            result.status_code = rpc_status.error_code();
            result.message = rpc_status.error_message();

            if (rpc_status.ok()) {
                result.reply = std::move(reply);
                validate_reply(result, control::v1::AGENT_STATE_CONFIGURED, control::v1::DATAPLANE_STATE_CONFIGURED);
            }

            return result;
        }
    );

    // Handle the results of the prepare operation
    ClusterOptResult operation_result{};
    operation_result.results = std::move(results);

    if (!all_rpc_succeeded(operation_result.results)) {
        printf("SSR::Coordinator::Prepare failed, transitioning to Idle state\n");
        state_.store(CoordinatorState::Idle, std::memory_order_release);
        operation_result.final_state = CoordinatorState::Idle;
        return operation_result;
    }

    printf("SSR::Coordinator::Prepare succeeded, transitioning to Ready state\n");
    state_.store(CoordinatorState::Ready, std::memory_order_release);
    operation_result.final_state = CoordinatorState::Ready;

    return operation_result;
}

ClusterOptResult SSRCoordinator::agents_start() {
    printf("SSR::Coordinator::Start called with session_id: %lu-%lu\n", session_id_.high, session_id_.low);
    std::scoped_lock lock(operation_mutex_);

    require_state(CoordinatorState::Ready, "Start");

    const SessionId current_session_id = session_id_;

    auto results = run_parallel(
        agent_rpc_client_map_,
        [this, &current_session_id](AgentRPCClient& agent) {
            AgentRPCResult result{};
            result.node_id = agent.node_id;

            control::v1::StartRequest request;
            control::v1::AgentReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));
            session_id_to_proto(current_session_id, request.mutable_session_id());

            grpc::ClientContext context;
            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            printf("SSR::Coordinator::Start::Node%u sending request\n", agent.node_id);
            const grpc::Status rpc_status = agent.stub->Start(&context, request, &reply);
            
            result.status_code = rpc_status.error_code();
            result.message = rpc_status.error_message();

            if (rpc_status.ok()) {
                result.reply = std::move(reply);
                validate_reply(result, control::v1::AGENT_STATE_RUNNING, control::v1::DATAPLANE_STATE_RUNNING);
            }

            return result;
        }
    );

    ClusterOptResult operation_result{};
    operation_result.results = std::move(results);

    if (!all_rpc_succeeded(operation_result.results)) {
        printf("SSR::Coordinator::Start failed, transitioning to Idle state\n");
        operation_result.final_state = CoordinatorState::Idle;
        state_.store(CoordinatorState::Idle, std::memory_order_release);
        return operation_result;
    }

    printf("SSR::Coordinator::Start succeeded, transitioning to Running state\n");
    state_.store(CoordinatorState::Running, std::memory_order_release);
    operation_result.final_state = CoordinatorState::Running;

    return operation_result;
}

ClusterOptResult SSRCoordinator::agents_stop() {
    printf("SSR::Coordinator::Stop called\n");
    std::scoped_lock lock(operation_mutex_);
    
    require_state(CoordinatorState::Running, "Stop");

    auto results = run_parallel(
        agent_rpc_client_map_,
        [this](AgentRPCClient& agent) {
            AgentRPCResult result{};
            result.node_id = agent.node_id;

            control::v1::StopRequest request;
            control::v1::AgentReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));
            request.mutable_session_id()->set_high(session_id_.high);
            request.mutable_session_id()->set_low(session_id_.low);

            grpc::ClientContext context;
            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            const grpc::Status rpc_status = agent.stub->Stop(&context, request, &reply);
            
            result.status_code = rpc_status.error_code();
            result.message = rpc_status.error_message();

            if (rpc_status.ok()) {
                result.reply = std::move(reply);
                validate_reply(result, control::v1::AGENT_STATE_STOPPED, control::v1::DATAPLANE_STATE_CLOSED);
            }

            return result;
        }
    );

    ClusterOptResult operation_result{};
    operation_result.results = std::move(results);

    if (!all_rpc_succeeded(operation_result.results)) {
        printf("SSR::Coordinator::Stop failed, transitioning to Idle state\n");
        operation_result.final_state = CoordinatorState::Idle;
        state_.store(CoordinatorState::Idle, std::memory_order_release);
        return operation_result;
    }

    printf("SSR::Coordinator::Stop succeeded, transitioning to Stopped state\n");
    state_.store(CoordinatorState::Stopped, std::memory_order_release);
    operation_result.final_state = CoordinatorState::Stopped;

    return operation_result;
}

std::vector<AgentRPCResult> SSRCoordinator::agents_get_status() {
    std::scoped_lock lock(operation_mutex_);

    auto results = run_parallel(
        agent_rpc_client_map_,
        [this](AgentRPCClient& agent) {
            AgentRPCResult result{};
            result.node_id = agent.node_id;

            control::v1::GetStatusRequest request;
            control::v1::AgentReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));

            grpc::ClientContext context;
            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            const grpc::Status rpc_status = agent.stub->GetStatus(&context, request, &reply);
            
            result.status_code = rpc_status.error_code();
            result.message = rpc_status.error_message();

            if (rpc_status.ok()) {
                result.reply = std::move(reply);
                // No specific validation for status; just return the reply
            }

            return result;
        }
    );

    return results;

}

} // namespace ssr
