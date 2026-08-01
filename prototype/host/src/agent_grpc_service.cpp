#include "ssr/agent_grpc_service.hpp"
#include "ssr/proto_conversion.hpp"

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

    if (dynamic_cast<const std::runtime_error*>(&e) != nullptr) {
        return grpc::Status(grpc::StatusCode::FAILED_PRECONDITION, e.what());
    }

    if (dynamic_cast<const DataplaneError*>(&e) != nullptr) {
        return grpc::Status(grpc::StatusCode::INTERNAL, e.what());
    }

    return grpc::Status(grpc::StatusCode::INTERNAL, e.what());
}

} // namespace

AgentRPCServiceImpl::AgentRPCServiceImpl(
    SSRAgent& agent
) noexcept
    : agent_(agent)
{
}

grpc::Status AgentRPCServiceImpl::validate_target_node(
    std::uint32_t target_node_id
) const
{
    if (target_node_id != static_cast<std::uint32_t>(agent_.node_id())) {
        return grpc::Status(
            grpc::StatusCode::FAILED_PRECONDITION,
            "Target node ID does not match this node's ID"
        );
    }

    return grpc::Status::OK;
}

void AgentRPCServiceImpl::fill_reply(
    control::v1::AgentReply* reply
) const
{
    if (reply == nullptr) {
        throw std::invalid_argument("reply pointer is null");
    }

    reply->set_node_id(static_cast<std::uint32_t>(agent_.node_id()));
    reply->set_state(agent_state_to_proto(agent_.state()));

    dataplane_status_to_proto(agent_.backend().status(), reply->mutable_dataplane_status());
    session_id_to_proto(agent_.session_id(), reply->mutable_session_id());
}

grpc::Status AgentRPCServiceImpl::Prepare(
    grpc::ServerContext* context,
    const control::v1::PrepareRequest* request,
    control::v1::AgentReply* reply
)
{
    printf("AgentRPCServiceImpl::Prepare called with target_node_id: %u\n", request ? request->target_node_id() : 0);
    static_cast<void>(context); // Unused parameter

    if (request == nullptr || reply == nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Request or reply pointer is null");
    }

    if (const auto target_status = validate_target_node(request->target_node_id()); !target_status.ok()) {
        return target_status;
    }

    if (!request->has_session_id() || !request->has_run_config()) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Missing required fields in request");
    }

    std::scoped_lock lock(mutex_);

    try {
        const auto session_id = session_id_from_proto(request->session_id());
        const auto run_config = run_config_from_proto(request->run_config());

        agent_.prepare(session_id, run_config);

        fill_reply(reply);
        
        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

grpc::Status AgentRPCServiceImpl::Start(
    grpc::ServerContext* context,
    const control::v1::StartRequest* request,
    control::v1::AgentReply* reply
)
{
    printf("AgentRPCServiceImpl::Start called with target_node_id: %u\n", request ? request->target_node_id() : 0);
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

        agent_.start(session_id);

        fill_reply(reply);
        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

grpc::Status AgentRPCServiceImpl::Stop(
    grpc::ServerContext* context,
    const control::v1::StopRequest* request,
    control::v1::AgentReply* reply
)
{
    printf("AgentRPCServiceImpl::Stop called with target_node_id: %u\n", request ? request->target_node_id() : 0);
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

        agent_.stop(session_id);

        fill_reply(reply);
        return grpc::Status::OK;
    } catch (const std::exception& e) {
        return exception_to_grpc_status(e);
    }
}

grpc::Status AgentRPCServiceImpl::GetStatus(
    grpc::ServerContext* context,
    const control::v1::GetStatusRequest* request,
    control::v1::AgentReply* reply
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
