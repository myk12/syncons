#include "ssr/node_agent_service.hpp"

#include "ssr/cluster.hpp"
#include "ssr/dataplane_backend.hpp"
#include "ssr/proto_conversion.hpp"
#include "ssr/coordinator_event_client.hpp"

#include <cstdint>
#include <exception>
#include <stdexcept>
#include <string>

namespace ssr {
namespace {

[[nodiscard]]
grpc::Status exception_to_grpc_status(
    const std::exception& e
)
{
    if (dynamic_cast<const std::invalid_argument*>(&e) != nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, e.what());
    }

    if (dynamic_cast<const ClusterControlError*>(&e) != nullptr) {
        return grpc::Status(grpc::StatusCode::FAILED_PRECONDITION, e.what());
    }

    if (dynamic_cast<const DataplaneError*>(&e) != nullptr) {
        return grpc::Status(grpc::StatusCode::INTERNAL, e.what());
    }

    return grpc::Status(grpc::StatusCode::INTERNAL, e.what());
}

} // namespace

NodeAgentServiceImpl::NodeAgentServiceImpl(
    NodeAgent& node_agent
) noexcept
    : node_agent_(node_agent)
{
}

NodeAgentServiceImpl::NodeAgentServiceImpl(
    NodeAgent& node_agent,
    CoordinatorEventClient& event_client
) noexcept
    : node_agent_(node_agent),
      event_client_(&event_client)
{
}

void NodeAgentServiceImpl::report_event(
    control::v1::NodeEventKind event_kind,
    std::string_view detail
) noexcept
{
    if (event_client_ == nullptr) {
        return;
    }

    static_cast<void>(event_client_->report(
        event_kind,
        node_agent_.state(),
        node_agent_.dataplane_status(),
        node_agent_.session_id(),
        detail
    ));
}

void NodeAgentServiceImpl::report_exception(
    const std::exception& e
)
{
    if (dynamic_cast<const DataplaneError*>(&e) != nullptr) {
        report_event(control::v1::NODE_EVENT_DATAPLANE_ERROR, e.what());
    }
}

grpc::Status NodeAgentServiceImpl::validate_target_node(
    std::uint32_t target_node_id
) const
{
    if (target_node_id != static_cast<std::uint32_t>(node_agent_.node_id())) {
        return grpc::Status(
            grpc::StatusCode::FAILED_PRECONDITION,
            "Target node ID does not match this node's ID"
        );
    }

    return grpc::Status::OK;
}

void NodeAgentServiceImpl::fill_reply(
    control::v1::NodeReply* reply
) const
{
    if (reply == nullptr) {
        throw std::invalid_argument("reply pointer is null");
    }

    reply->set_node_id(static_cast<std::uint32_t>(node_agent_.node_id()));
    reply->set_state(node_state_to_proto(node_agent_.state()));

    dataplane_status_to_proto(node_agent_.dataplane_status(), reply->mutable_dataplane_status());

    if (const auto& session_id_opt = node_agent_.session_id(); session_id_opt.has_value()) {
        session_id_to_proto(session_id_opt.value(), reply->mutable_session_id());
    }

    if (const auto& session_id = node_agent_.session_id(); session_id.has_value()) {
        session_id_to_proto(session_id.value(), reply->mutable_session_id());
    } else {
        reply->clear_session_id();
    }
}

grpc::Status NodeAgentServiceImpl::Prepare(
    grpc::ServerContext* context,
    const control::v1::PrepareRequest* request,
    control::v1::NodeReply* reply
)
{
    static_cast<void>(context); // Unused parameter

    if (request == nullptr || reply == nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Request or reply pointer is null");
    }

    if (const auto target_status = validate_target_node(request->target_node_id()); !target_status.ok()) {
        return target_status;
    }

    if (!request->has_session_id() || !request->has_cluster_config() || !request->has_sync_result()) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Missing required fields in request");
    }

    std::scoped_lock lock(mutex_);

    try {
        const auto session_id = session_id_from_proto(request->session_id());
        const auto cluster_config = cluster_config_from_proto(request->cluster_config());
        const auto sync_result = sync_result_from_proto(request->sync_result());

        node_agent_.prepare(session_id, cluster_config, sync_result);

        fill_reply(reply);

        report_event(control::v1::NODE_EVENT_STATE_CHANGED, "Prepare completed successfully");
        
        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

grpc::Status NodeAgentServiceImpl::Start(
    grpc::ServerContext* context,
    const control::v1::StartRequest* request,
    control::v1::NodeReply* reply
)
{
    static_cast<void>(context); // Unused parameter

    if (request == nullptr || reply == nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Request or reply pointer is null");
    }

    if (const auto target_status = validate_target_node(request->target_node_id()); !target_status.ok()) {
        return target_status;
    }

    if (!request->has_session_id() || !request->has_start_config()) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Missing required fields in request");
    }

    std::scoped_lock lock(mutex_);

    try {
        const auto session_id = session_id_from_proto(request->session_id());
        const auto start_config = start_config_from_proto(request->start_config());

        node_agent_.start(session_id, start_config);

        fill_reply(reply);
        report_event(control::v1::NODE_EVENT_STATE_CHANGED, "Start completed successfully");
        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

grpc::Status NodeAgentServiceImpl::Stop(
    grpc::ServerContext* context,
    const control::v1::StopRequest* request,
    control::v1::NodeReply* reply
)
{
    static_cast<void>(context); // Unused parameter

    if (request == nullptr || reply == nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Request or reply pointer is null");
    }

    if (const auto target_status = validate_target_node(request->target_node_id()); !target_status.ok()) {
        return target_status;
    }

    if (!request->has_session_id()) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Missing required fields in request");
    }

    std::scoped_lock lock(mutex_);

    try {
        const auto session_id = session_id_from_proto(request->session_id());

        node_agent_.stop(session_id);

        fill_reply(reply);
        report_event(control::v1::NODE_EVENT_STATE_CHANGED, "Stop completed successfully");
        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

grpc::Status NodeAgentServiceImpl::Reset(
    grpc::ServerContext* const context,
    const control::v1::ResetRequest* const request,
    control::v1::NodeReply* const reply
)
{
    static_cast<void>(context); // Unused parameter

    if (request == nullptr || reply == nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Request or reply pointer is null");
    }

    if (const auto target_status = validate_target_node(request->target_node_id()); !target_status.ok()) {
        return target_status;
    }

    // abort session is the existing unconditional local reset operation
    std::scoped_lock lock(mutex_);
    node_agent_.abort_session();

    if (node_agent_.state() != NodeAgentState::Idle) {
        return grpc::Status(grpc::StatusCode::INTERNAL, "Failed to reset node agent state to Idle");
    }

    try {
        fill_reply(reply);
        report_event(control::v1::NODE_EVENT_STATE_CHANGED, "Reset completed successfully");

        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

grpc::Status NodeAgentServiceImpl::GetStatus(
    grpc::ServerContext* context,
    const control::v1::GetStatusRequest* request,
    control::v1::NodeReply* reply
)
{
    static_cast<void>(context); // Unused parameter

    if (request == nullptr || reply == nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Request or reply pointer is null");
    }

    if (const auto target_status = validate_target_node(request->target_node_id()); !target_status.ok()) {
        return target_status;
    }

    std::scoped_lock lock(mutex_);

    try {
        fill_reply(reply);
        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

} // namespace ssr
