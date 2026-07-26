#include "ssr/coordinator_event_client.hpp"
#include "ssr/proto_conversion.hpp"

#include <grpcpp/create_channel.h>
#include <grpcpp/security/credentials.h>

#include <chrono>
#include <exception>
#include <utility>
#include <string>

namespace ssr {

CoordinatorEventClient::CoordinatorEventClient(
    NodeId node_id,
    std::string coordinator_address,
    std::chrono::milliseconds rpc_timeout
) : node_id_(node_id),
    rpc_timeout_(rpc_timeout),
    channel_(grpc::CreateChannel(std::move(coordinator_address), grpc::InsecureChannelCredentials())),
    stub_(control::v1::CoordinatorService::NewStub(channel_))
{
    if (!channel_) {
        throw std::runtime_error("Failed to create gRPC channel to coordinator");
    }

    if (!stub_) {
        throw std::runtime_error("Failed to create gRPC stub for coordinator service");
    }
}

bool CoordinatorEventClient::report(
    const control::v1::NodeEventKind event_kind,
    const NodeAgentState node_state,
    const DataplaneStatus& dataplane_status,
    const std::optional<SessionId>& session_id,
    std::string_view detail
) noexcept
{
    try {
       std::scoped_lock lock(mutex_);

        const std::uint64_t sequence_number = next_sequence_number_++;
        control::v1::NodeEventReport request;
        request.set_node_id(static_cast<std::uint32_t>(node_id_));
        request.set_sequence_number(sequence_number);
        request.set_event(event_kind);
        request.set_node_state(node_state_to_proto(node_state));
        request.set_dataplane_state(dataplane_state_to_proto(dataplane_status.state));
        request.set_detail(detail.data(), detail.size());

        if (session_id.has_value()) {
            session_id_to_proto(session_id.value(), request.mutable_session_id());
        }

        control::v1::ReportNodeEventReply reply;
        grpc::ClientContext context;
        context.set_deadline(std::chrono::system_clock::now() + rpc_timeout_);
        const grpc::Status status = stub_->ReportNodeEvent(&context, request, &reply);
        
        return status.ok() && reply.ack_sequence_number() == sequence_number;
    } catch (...) {
        return false;
    }
}

} // namespace ssr
