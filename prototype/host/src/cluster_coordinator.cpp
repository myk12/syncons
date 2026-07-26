#include "ssr/cluster_coordinator.hpp"

#include "ssr/proto_conversion.hpp"

#include <grpcpp/create_channel.h>
#include <grpcpp/security/credentials.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <exception>
#include <future>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace ssr {
namespace {

//[[nodiscard]]
//bool same_session(const SessionId& left, const SessionId& right) noexcept
//{
//    return left.high == right.high && left.low == right.low;
//}

[[nodiscard]]
bool all_succeeded(const std::vector<NodeRpcResult>& results) noexcept
{
    return std::all_of(results.begin(), results.end(),
                       [](const NodeRpcResult& result) { return result.ok(); });
}

void set_local_error(NodeRpcResult& result, const grpc::StatusCode status_code, std::string message)
{
    result.status_code = status_code;
    result.message = std::move(message);
}

void validate_reply(NodeRpcResult& result,
                    const control::v1::NodeState expected_node_state,
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

    if (result.reply.state() != expected_node_state) {
        set_local_error(result, grpc::StatusCode::FAILED_PRECONDITION,
                        "Unexpected node state in reply");
        return;
    }

    if (!result.reply.has_dataplane_status()) {
        set_local_error(result, grpc::StatusCode::DATA_LOSS,
                        "Missing dataplane state in reply");
        return;
    }

    if (result.reply.dataplane_status().state() != expected_dataplane_state) {
        set_local_error(result, grpc::StatusCode::FAILED_PRECONDITION,
                        "Unexpected dataplane state in reply");
        return;
    }
}

template<typename Function>
std::vector<NodeRpcResult> run_parallel(
    std::vector<ClusterCoordinator::AgentClient>& agents,
    Function&& function
)
{
    std::vector<std::future<NodeRpcResult>> futures;
    futures.reserve(agents.size());

    for (auto& agent : agents) {
        ClusterCoordinator::AgentClient* const agent_pointer = &agent;
        
        futures.push_back(std::async(std::launch::async, [agent_pointer, &function]() -> NodeRpcResult {
            try {
                return function(*agent_pointer);
            } catch (const std::exception& e) {
                NodeRpcResult result;
                result.node_id = agent_pointer->node_id;
                set_local_error(result, grpc::StatusCode::INTERNAL, e.what());
                return result;
            } catch (...) {
                NodeRpcResult result;
                result.node_id = agent_pointer->node_id;
                set_local_error(result, grpc::StatusCode::INTERNAL, "Unknown error");
                return result;
            }
        }));
    }

    std::vector<NodeRpcResult> results;
    results.reserve(futures.size());

    for (auto& future : futures) {
        results.push_back(future.get());
    }

    return results;
}

void apply_rpc_status(NodeRpcResult& result, const grpc::Status& rpc_status)
{
    result.status_code = rpc_status.error_code();
    result.message = rpc_status.error_message();
}

} // namespace

bool ClusterOperationResult::ok() const noexcept
{
    return final_state != CoordinatorState::Failed && all_succeeded(node_results);
}

ClusterCoordinator::AgentClient::AgentClient(
    const NodeId input_node_id,
    std::string input_address
) : node_id(input_node_id),
    address(std::move(input_address)),
    channel(grpc::CreateChannel(address, grpc::InsecureChannelCredentials())),
    stub(control::v1::NodeAgentService::NewStub(channel))
{
    if (address.empty()) {
        throw std::invalid_argument("Agent address cannot be empty");
    }

    if (channel == nullptr) {
        throw std::runtime_error("Failed to create gRPC channel for agent at " + address);
    }

    if (stub == nullptr) {
        throw std::runtime_error("Failed to create gRPC stub for agent at " + address);
    }
}

ClusterCoordinator::ClusterCoordinator(
    std::vector<AgentEndpoint> endpoints,
    std::chrono::milliseconds rpc_timeout
) : rpc_timeout_(rpc_timeout)
{
    if (endpoints.empty()) {
        throw std::invalid_argument("At least one agent endpoint must be provided");
    }

    if (rpc_timeout_ <= std::chrono::milliseconds::zero()) {
        throw std::invalid_argument("RPC timeout must be positive");
    }

    std::set<NodeId> seen_node_ids;
    agents_.reserve(endpoints.size());

    for (auto& endpoint : endpoints) {
        if (!seen_node_ids.insert(endpoint.node_id).second) {
            throw std::invalid_argument("Duplicate node ID in endpoints: " + std::to_string(endpoint.node_id));
        }

        if (endpoint.address.empty()) {
            throw std::invalid_argument("Agent address cannot be empty for node ID: " + std::to_string(endpoint.node_id));
        }

        agents_.emplace_back(endpoint.node_id, std::move(endpoint.address));
    }

    std::sort(agents_.begin(), agents_.end(),
              [](const AgentClient& a, const AgentClient& b) {
                  return a.node_id < b.node_id;
              });
}


std::optional<SessionId>
ClusterCoordinator::session_id() const
{
    std::scoped_lock lock(operation_mutex_);
    return session_id_;
}

void ClusterCoordinator::require_state(CoordinatorState expected, const char* const operation) const
{
    const CoordinatorState actual = state();

    if (actual != expected) {
        throw ClusterControlError(
            std::string("Operation '") + operation + "' requires state " +
            std::to_string(static_cast<std::uint8_t>(expected)) +
            ", but current state is " +
            std::to_string(static_cast<std::uint8_t>(actual))
        );
    }
}

void ClusterCoordinator::require_startable_state() const
{
    const CoordinatorState actual = state();

    if (actual != CoordinatorState::Ready &&
        actual != CoordinatorState::Stopped) {
        throw ClusterControlError(
            std::string("Operation requires state Ready or Stopped, but current state is ") +
            std::to_string(static_cast<std::uint8_t>(actual))
        );
    }

    if (!session_id_.has_value()) {
        throw ClusterControlError("Operation requires a valid session ID, but none is set");
    }
}

bool ClusterCoordinator::fault_observed_since(const std::uint64_t generation) const noexcept
{
    return fault_generation_.load(std::memory_order_acquire) != generation;
}

ClusterOperationResult ClusterCoordinator::prepare(
    const SessionId& input_session_id,
    const ClusterConfig& cluster_config,
    const NodeSyncResults& sync_results
)
{
    std::scoped_lock lock(operation_mutex_);

    require_state(CoordinatorState::Idle, "prepare");

    cluster_config.validate();

    if (cluster_config.replica_count() != agents_.size()) {
        throw ClusterControlError(
            "Replica count in cluster configuration does not match number of agents"
        );
    }

    for (const auto& agent : agents_) {
        static_cast<void>(cluster_config.for_node(agent.node_id));

        const auto iterator = sync_results.find(agent.node_id);

        if (iterator == sync_results.end()) {
            throw ClusterControlError(
                "Missing synchronization result for node ID: " + std::to_string(agent.node_id)
            );
        }

        if (!iterator->second.synchronized) {
            throw ClusterControlError(
                "Node ID " + std::to_string(agent.node_id) + " is not synchronized"
            );
        }
    }

    state_.store(CoordinatorState::Preparing, std::memory_order_release);

    session_id_ = input_session_id;
    const std::uint64_t fault_generation = fault_generation_.load(std::memory_order_acquire);
    auto results = run_parallel(
        agents_,
        [this, &input_session_id, &cluster_config, &sync_results](AgentClient& agent) {
            NodeRpcResult result{};
            result.node_id = agent.node_id;

            control::v1::PrepareRequest request;
            control::v1::NodeReply reply;
            
            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));
            session_id_to_proto(input_session_id, request.mutable_session_id());
            cluster_config_to_proto(cluster_config, request.mutable_cluster_config());
            sync_result_to_proto(sync_results.at(agent.node_id), request.mutable_sync_result());

            grpc::ClientContext context;

            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            const grpc::Status rpc_status = agent.stub->Prepare(&context, request, &reply);
            apply_rpc_status(result, rpc_status);

            if (rpc_status.ok()) {
                result.reply = std::move(reply);

                validate_reply(result, control::v1::NODE_STATE_READY, control::v1::DATAPLANE_STATE_SYNCHRONIZED);
            }

            return result;
        }
    );

    const bool failed = !all_succeeded(results) || fault_observed_since(fault_generation);

    ClusterOperationResult operation_result{};
    operation_result.node_results = std::move(results);

    if (failed) {
        operation_result.rollback_results = reset_all_unlocked();
        state_.store(CoordinatorState::Failed, std::memory_order_release);
        operation_result.final_state = CoordinatorState::Failed;

        return operation_result;
    }

    state_.store(CoordinatorState::Ready, std::memory_order_release);
    operation_result.final_state = CoordinatorState::Ready;

    return operation_result;
}

ClusterOperationResult ClusterCoordinator::start(const StartConfig& start_config)
{
    std::scoped_lock lock(operation_mutex_);

    require_startable_state();
    start_config.validate();

    const SessionId current_session_id = session_id_.value();

    state_.store(CoordinatorState::Ready, std::memory_order_release);

    const std::uint64_t fault_generation = fault_generation_.load(std::memory_order_acquire);

    auto results = run_parallel(
        agents_,
        [this, &current_session_id, &start_config](AgentClient& agent) {
            NodeRpcResult result{};
            result.node_id = agent.node_id;

            control::v1::StartRequest request;
            control::v1::NodeReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));
            session_id_to_proto(current_session_id, request.mutable_session_id());
            start_config_to_proto(start_config, request.mutable_start_config());

            grpc::ClientContext context;
            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            const grpc::Status rpc_status = agent.stub->Start(&context, request, &reply);
            apply_rpc_status(result, rpc_status);

            if (rpc_status.ok()) {
                result.reply = std::move(reply);

                validate_reply(result, control::v1::NODE_STATE_RUNNING, control::v1::DATAPLANE_STATE_RUNNING);
            }

            return result;
        }
    );

    const bool failed = !all_succeeded(results) || fault_observed_since(fault_generation);

    ClusterOperationResult operation_result{};
    operation_result.node_results = std::move(results);

    if (failed) {
        operation_result.rollback_results = reset_all_unlocked();
        state_.store(CoordinatorState::Failed, std::memory_order_release);
        operation_result.final_state = CoordinatorState::Failed;

        return operation_result;
    }

    state_.store(CoordinatorState::Running, std::memory_order_release);
    operation_result.final_state = CoordinatorState::Running;

    return operation_result;
}

ClusterOperationResult ClusterCoordinator::stop()
{
    std::scoped_lock lock(operation_mutex_);

    require_state(CoordinatorState::Running, "stop");

    if (!session_id_.has_value()) {
        throw ClusterControlError("Operation requires a valid session ID, but none is set");
    }

    const SessionId current_session_id = session_id_.value();

    state_.store(CoordinatorState::Stopping, std::memory_order_release);

    const std::uint64_t fault_generation = fault_generation_.load(std::memory_order_acquire);

    auto results = run_parallel(
        agents_,
        [this, &current_session_id](AgentClient& agent) {
            NodeRpcResult result{};
            result.node_id = agent.node_id;

            control::v1::StopRequest request;
            control::v1::NodeReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));
            session_id_to_proto(current_session_id, request.mutable_session_id());

            grpc::ClientContext context;
            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            const grpc::Status rpc_status = agent.stub->Stop(&context, request, &reply);
            apply_rpc_status(result, rpc_status);

            if (rpc_status.ok()) {
                result.reply = std::move(reply);

                validate_reply(result, control::v1::NODE_STATE_STOPPED, control::v1::DATAPLANE_STATE_STOPPED);
            }

            return result;
        }
    );

    const bool failed = !all_succeeded(results) || fault_observed_since(fault_generation);

    ClusterOperationResult operation_result{};
    operation_result.node_results = std::move(results);

    if (failed) {
        operation_result.rollback_results = reset_all_unlocked();
        state_.store(CoordinatorState::Failed, std::memory_order_release);
        operation_result.final_state = CoordinatorState::Failed;

        return operation_result;
    }

    state_.store(CoordinatorState::Stopped, std::memory_order_release);
    operation_result.final_state = CoordinatorState::Stopped;

    return operation_result;
}

std::vector<NodeRpcResult> ClusterCoordinator::reset_all_unlocked()
{
    const std::uint64_t fault_generation = fault_generation_.fetch_add(1, std::memory_order_acq_rel) + 1;

    auto results = run_parallel(
        agents_,
        [this, &fault_generation](AgentClient& agent) {
            NodeRpcResult result{};
            result.node_id = agent.node_id;

            control::v1::ResetRequest request;
            control::v1::NodeReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));

            grpc::ClientContext context;
            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            const grpc::Status rpc_status = agent.stub->Reset(&context, request, &reply);
            apply_rpc_status(result, rpc_status);

            if (rpc_status.ok()) {
                result.reply = std::move(reply);

                validate_reply(result, control::v1::NODE_STATE_IDLE, control::v1::DATAPLANE_STATE_RESET);
            }

            return result;
        }
    );

    return results;
}

ClusterOperationResult ClusterCoordinator::reset()
{
    std::scoped_lock lock(operation_mutex_);

    state_.store(CoordinatorState::Resetting, std::memory_order_release);

    auto results = reset_all_unlocked();

    ClusterOperationResult operation_result{};
    operation_result.node_results = std::move(results);

    if (!all_succeeded(operation_result.node_results)) {
        state_.store(CoordinatorState::Failed, std::memory_order_release);
        operation_result.final_state = CoordinatorState::Failed;

        return operation_result;
    }

    session_id_.reset();
    state_.store(CoordinatorState::Idle, std::memory_order_release);
    operation_result.final_state = CoordinatorState::Idle;

    return operation_result;
}

std::vector<NodeRpcResult> ClusterCoordinator::get_status()
{
    std::scoped_lock lock(operation_mutex_);

    auto results = run_parallel(
        agents_,
        [this](AgentClient& agent) {
            NodeRpcResult result{};
            result.node_id = agent.node_id;

            control::v1::GetStatusRequest request;
            control::v1::NodeReply reply;

            request.set_target_node_id(static_cast<std::uint32_t>(agent.node_id));

            grpc::ClientContext context;
            context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);

            const grpc::Status rpc_status = agent.stub->GetStatus(&context, request, &reply);
            apply_rpc_status(result, rpc_status);

            if (rpc_status.ok()) {
                result.reply = std::move(reply);
            }

            return result;
        }
    );

    return results;
}

void ClusterCoordinator::handle_node_event(const control::v1::NodeEventReport& event_report) noexcept
{
    if (event_report.event() != control::v1::NODE_EVENT_DATAPLANE_ERROR &&
        event_report.event() != control::v1::NODE_EVENT_DATAPLANE_HALTED) {
        return;
    }

    fault_generation_.fetch_add(1, std::memory_order_acq_rel);

    state_.store(CoordinatorState::Failed, std::memory_order_release);
}

} // namespace ssr
