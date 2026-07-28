#include "ssr/mock_dataplane.hpp"
#include "ssr/node_agent.hpp"
#include "ssr/node_agent_service.hpp"

#include "ssr_control.grpc.pb.h"

#include <array>
#include <chrono>
#include <cstdint>
#include <exception>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>

#include <grpcpp/grpcpp.h>

namespace
{

using NodeAgentStub = ssr::control::v1::NodeAgentService::Stub;

void require(
    const bool condition,
    const std::string_view message)
{
    if (!condition)
    {
        throw std::runtime_error(std::string(message));
    }
}

void require_rpc_ok(
    const grpc::Status &status,
    const std::string_view operation
)
{
    if (status.ok())
    {
        return;
    }

    throw std::runtime_error(
        std::string("gRPC operation '") + std::string(operation) + "' failed: " + status.error_message());
}

void set_rpc_deadline(grpc::ClientContext &context)
{
    context.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(5));
}

void fill_session_id(
    ssr::control::v1::SessionId *const output,
    const std::uint64_t high,
    const std::uint64_t low)
{
    require(output != nullptr, "output pointer is null");

    output->set_high(high);
    output->set_low(low);
}

void add_mac_address(
    ssr::control::v1::ClusterConfig *const output,
    const std::array<std::uint8_t, 6> &bytes)
{
    require(output != nullptr, "output pointer is null");

    std::array<char, 6> encoded{};

    for (std::size_t i = 0; i < bytes.size(); ++i)
    {
        encoded[i] = static_cast<char>(bytes[i]);
    }

    output->add_replica_macs()->set_value(std::string(encoded.data(), encoded.size()));
}

ssr::control::v1::PrepareRequest make_prepare_request(
    const std::uint32_t target_node_id,
    const std::uint64_t session_id_high,
    const std::uint64_t session_id_low)
{
    ssr::control::v1::PrepareRequest request{};

    request.set_target_node_id(target_node_id);
    fill_session_id(request.mutable_session_id(), session_id_high, session_id_low);

    auto *cluster_config = request.mutable_cluster_config();
    add_mac_address(cluster_config, {0x00, 0x11, 0x22, 0x33, 0x44, 0x55});
    add_mac_address(cluster_config, {0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb});
    add_mac_address(cluster_config, {0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11});

    cluster_config->set_ethernet_type(0x88B5);
    cluster_config->set_round_length_ns(2000);

    auto *sync_result = request.mutable_sync_result();

    sync_result->set_synchronized(true);
    sync_result->set_estimated_offset_ns(10);
    sync_result->set_uncertainty_ns(100);

    return request;
}

ssr::control::v1::StartRequest make_start_request(
    const std::uint32_t target_node_id,
    const std::uint64_t session_id_high,
    const std::uint64_t session_id_low)
{
    ssr::control::v1::StartRequest request{};

    request.set_target_node_id(target_node_id);
    fill_session_id(request.mutable_session_id(), session_id_high, session_id_low);

    auto *start_config = request.mutable_start_config();
    start_config->set_first_round_id(1);
    start_config->set_first_round_timestamp_ns(1000);
    start_config->set_first_run_id(1);

    return request;
}

ssr::control::v1::StopRequest make_stop_request(
    const std::uint32_t target_node_id,
    const std::uint64_t session_id_high,
    const std::uint64_t session_id_low)
{
    ssr::control::v1::StopRequest request{};

    request.set_target_node_id(target_node_id);
    fill_session_id(request.mutable_session_id(), session_id_high, session_id_low);

    return request;
}

void require_node_status(
    const ssr::control::v1::NodeReply &reply,
    const std::uint32_t expected_node_id,
    const ssr::control::v1::NodeState expected_node_state,
    const ssr::control::v1::DataplaneState expected_dataplane_state)
{
    require(
        reply.node_id() == expected_node_id,
        "Node ID in reply does not match expected value");
    
    if (reply.state() != expected_node_state)
    {
        throw std::runtime_error(
            "Node state in reply does not match expected value: got " +
            std::to_string(static_cast<std::uint32_t>(reply.state())) +
            ", expected " +
            std::to_string(static_cast<std::uint32_t>(expected_node_state)));
    }

    require(
        reply.state() == expected_node_state,
        "Node state in reply does not match expected value");

    require(
        reply.has_dataplane_status(),
        "Reply must contain dataplane status");

    require(
        reply.dataplane_status().state() == expected_dataplane_state,
        "Dataplane state in reply does not match expected value");
}

// Runs one real synchronous gRPC server on IPv4 loopback.
class AgentGrpcFixture
{
public:
    explicit AgentGrpcFixture(const ssr::NodeId node_id)
        : agent_(node_id, backend_),
          service_(agent_)
    {
        grpc::ServerBuilder builder;

        builder.AddListeningPort(
            "127.0.0.1:0",
            grpc::InsecureServerCredentials(),
            &selected_port_);

        builder.RegisterService(&service_);

        server_ = builder.BuildAndStart();

        require(server_ != nullptr, "Failed to start gRPC server");
        require(selected_port_ > 0, "Failed to select a valid port for gRPC server");

        const std::string address = "127.0.0.1:" + std::to_string(selected_port_);

        channel_ = grpc::CreateChannel(address, grpc::InsecureChannelCredentials());
        require(channel_->WaitForConnected(std::chrono::system_clock::now() + std::chrono::seconds(5)),
            "Failed to connect gRPC stub to server");

        stub_ = ssr::control::v1::NodeAgentService::NewStub(channel_);
        require(stub_ != nullptr, "Failed to create gRPC stub");
    }

    ~AgentGrpcFixture()
    {
        if (server_)
        {
            server_->Shutdown();
            server_->Wait();
        }
    }

    AgentGrpcFixture(const AgentGrpcFixture &) = delete;

    AgentGrpcFixture &operator=(const AgentGrpcFixture &) = delete;

    [[nodiscard]] NodeAgentStub &stub() const
    {
        return *stub_;
    }

    [[nodiscard]] ssr::MockDataplaneBackend &backend()
    {
        return backend_;
    }

private:
    ssr::MockDataplaneBackend backend_;
    ssr::NodeAgent agent_;
    ssr::NodeAgentServiceImpl service_;

    std::unique_ptr<grpc::Server> server_;
    std::unique_ptr<NodeAgentStub> stub_;
    std::shared_ptr<grpc::Channel> channel_;

    int selected_port_ = 0;
};

// ================================================
//              Test Cases
// ================================================
void test_full_agent_lifecycle()
{
    constexpr std::uint32_t kNodeId = 1;
    constexpr std::uint64_t kSessionIdHigh = 0x1234567890abcdefULL;
    constexpr std::uint64_t kSessionIdLow = 0xfedcba0987654321ULL;

    AgentGrpcFixture fixture(kNodeId);

    // Initial status:
    // NodeAgent = Idle
    // Dataplane = Closed
    {
        grpc::ClientContext context;
        set_rpc_deadline(context);

        ssr::control::v1::GetStatusRequest request{};
        ssr::control::v1::NodeReply reply{};

        request.set_target_node_id(kNodeId);

        const auto status = fixture.stub().GetStatus(&context, request, &reply);
        require_rpc_ok(status, "GetStatus");

        require_node_status(
            reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_IDLE,
            ssr::control::v1::DATAPLANE_STATE_CLOSED);

        require(!reply.has_session_id(), "Session ID should not be present in initial status");
    }

    // Prepare:
    // backend.open()
    // backend.reset()
    // backend.configure()
    // backend.synchronize()
    {
        grpc::ClientContext context;
        set_rpc_deadline(context);

        auto request = make_prepare_request(kNodeId, kSessionIdHigh, kSessionIdLow);
        ssr::control::v1::NodeReply reply{};

        const grpc::Status status = fixture.stub().Prepare(&context, request, &reply);
        require_rpc_ok(status, "Prepare");

        require_node_status(
            reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_READY,
            ssr::control::v1::DATAPLANE_STATE_SYNCHRONIZED);

        require(reply.has_session_id(), "Session ID should be present after Prepare");
        require(reply.session_id().high() == kSessionIdHigh, "Session ID high part mismatch");
        require(reply.session_id().low() == kSessionIdLow, "Session ID low part mismatch");
        require(reply.dataplane_status().config_valid(), "Dataplane config_valid should be true after Prepare");
        require(reply.dataplane_status().sync_valid(), "Dataplane sync_valid should be true after Prepare");
    }

    // Start
    {
        grpc::ClientContext start_context;
        set_rpc_deadline(start_context);

        auto start_request = make_start_request(kNodeId, kSessionIdHigh, kSessionIdLow);
        ssr::control::v1::NodeReply start_reply{};

        const grpc::Status start_status = fixture.stub().Start(&start_context, start_request, &start_reply);
        require_rpc_ok(start_status, "Start");

        require_node_status(
            start_reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_RUNNING,
            ssr::control::v1::DATAPLANE_STATE_RUNNING);

        require(start_reply.dataplane_status().running(), "Dataplane running should be true after Start");
    }

    // Stop
    {
        grpc::ClientContext stop_context;
        set_rpc_deadline(stop_context);

        auto stop_request = make_stop_request(kNodeId, kSessionIdHigh, kSessionIdLow);
        ssr::control::v1::NodeReply stop_reply{};

        const grpc::Status stop_status = fixture.stub().Stop(&stop_context, stop_request, &stop_reply);
        require_rpc_ok(stop_status, "Stop");

        require_node_status(
            stop_reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_STOPPED,
            ssr::control::v1::DATAPLANE_STATE_STOPPED);

        require(!stop_reply.dataplane_status().running(), "Dataplane running should be false after Stop");
    }

    // Same-session restart
    {
        grpc::ClientContext restart_context;
        set_rpc_deadline(restart_context);

        auto restart_request = make_start_request(kNodeId, kSessionIdHigh, kSessionIdLow);
        ssr::control::v1::NodeReply restart_reply{};

        const grpc::Status restart_status = fixture.stub().Start(&restart_context, restart_request, &restart_reply);
        require_rpc_ok(restart_status, "Restart");

        require_node_status(
            restart_reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_RUNNING,
            ssr::control::v1::DATAPLANE_STATE_RUNNING);

        require(restart_reply.dataplane_status().running(), "Dataplane running should be true after Restart");
    }

    // Unconditional reset
    {
        grpc::ClientContext reset_context;
        set_rpc_deadline(reset_context);

        ssr::control::v1::ResetRequest reset_request{};
        reset_request.set_target_node_id(kNodeId);

        ssr::control::v1::NodeReply reset_reply{};

        const grpc::Status reset_status = fixture.stub().Reset(&reset_context, reset_request, &reset_reply);
        require_rpc_ok(reset_status, "Reset");

        require_node_status(
            reset_reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_IDLE,
            ssr::control::v1::DATAPLANE_STATE_RESET);

        require(!reset_reply.dataplane_status().running(), "Dataplane running should be false after Reset");
    }
}

void test_injected_dataplane_failure()
{
    constexpr std::uint32_t kNodeId = 1;
    constexpr std::uint64_t kSessionIdHigh = 0x1234567890abcdefULL;
    constexpr std::uint64_t kSessionIdLow = 0xfedcba0987654321ULL;

    AgentGrpcFixture fixture(kNodeId);

    // Prepare a valid session
    {
        grpc::ClientContext context;
        set_rpc_deadline(context);
        
        auto request = make_prepare_request(kNodeId, kSessionIdHigh, kSessionIdLow);
        ssr::control::v1::NodeReply reply{};

        const grpc::Status rpc_status = fixture.stub().Prepare(&context, request, &reply);
        require_rpc_ok(rpc_status, "Prepare");
    }

    // The next real Start RPC reaches NodeAgent and then fails inside
    // MockDataplaneBackend
    fixture.backend().fail_next(ssr::MockFailurePoint::Start);

    {
        grpc::ClientContext start_context;
        set_rpc_deadline(start_context);

        auto start_request = make_start_request(kNodeId, kSessionIdHigh, kSessionIdLow);
        ssr::control::v1::NodeReply start_reply{};

        const grpc::Status start_status = fixture.stub().Start(&start_context, start_request, &start_reply);
        require(!start_status.ok(), "Expected Start RPC to fail due to injected failure");

        require(
            start_status.error_code() == grpc::StatusCode::INTERNAL,
            "Expected INTERNAL error code for injected failure");
    }

    // GetStatus remains available even after a failed command
    {
        grpc::ClientContext context;
        set_rpc_deadline(context);

        ssr::control::v1::GetStatusRequest request{};
        ssr::control::v1::NodeReply reply{};

        request.set_target_node_id(kNodeId);
        const grpc::Status status = fixture.stub().GetStatus(&context, request, &reply);
        require_rpc_ok(status, "GetStatus");

        require_node_status(
            reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_FAILED,
            ssr::control::v1::DATAPLANE_STATE_SYNCHRONIZED);
    }

    // Explicit reset recovers the NodeAgent
    {
        grpc::ClientContext reset_context;
        set_rpc_deadline(reset_context);

        ssr::control::v1::ResetRequest reset_request{};
        reset_request.set_target_node_id(kNodeId);

        ssr::control::v1::NodeReply reset_reply{};

        const grpc::Status reset_status = fixture.stub().Reset(&reset_context, reset_request, &reset_reply);
        require_rpc_ok(reset_status, "Reset");

        require_node_status(
            reset_reply,
            kNodeId,
            ssr::control::v1::NODE_STATE_IDLE,
            ssr::control::v1::DATAPLANE_STATE_RESET);
    }
}

} // namespace

int main()
{
    try {
        std::cout<< "Running NodeAgent gRPC service tests..." << std::endl;
        std::cout<< "[Test] full agent lifecycle" << std::endl;
        test_full_agent_lifecycle();
        std::cout<< "[Test] injected dataplane failure" << std::endl;
        test_injected_dataplane_failure();
        std::cout<< "All tests passed successfully." << std::endl;

        return 0;
    } catch (const std::exception& e) {
        std::cerr << "Test failed: " << e.what() << std::endl;

        return 1;
    }
}
