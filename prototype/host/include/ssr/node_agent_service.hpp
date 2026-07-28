#pragma once

#include "ssr/node_agent.hpp"
#include "ssr_control.grpc.pb.h"

#include <cstdint>
#include <mutex>
#include <string_view>
#include <exception>

namespace ssr {

class CoordinatorEventClient;

class NodeAgentServiceImpl final : public control::v1::NodeAgentService::Service {
public:
    explicit NodeAgentServiceImpl(NodeAgent& node_agent) noexcept;
    NodeAgentServiceImpl(NodeAgent& node_agent, CoordinatorEventClient& event_client) noexcept;

    grpc::Status Prepare(
        grpc::ServerContext* context,
        const control::v1::PrepareRequest* request,
        control::v1::NodeReply* reply
    ) override;

    grpc::Status Start(
        grpc::ServerContext* context,
        const control::v1::StartRequest* request,
        control::v1::NodeReply* reply
    ) override;

    grpc::Status Stop(
        grpc::ServerContext* context,
        const control::v1::StopRequest* request,
        control::v1::NodeReply* reply
    ) override;

    grpc::Status Reset(
        grpc::ServerContext* context,
        const control::v1::ResetRequest* request,
        control::v1::NodeReply* reply
    ) override;

    grpc::Status GetStatus(
        grpc::ServerContext* context,
        const control::v1::GetStatusRequest* request,
        control::v1::NodeReply* reply
    ) override;

private:
    [[nodiscard]]
    grpc::Status validate_target_node(std::uint32_t target_node_id) const;

    void fill_reply(control::v1::NodeReply* reply) const;

    void report_event(
        control::v1::NodeEventKind event_kind,
        std::string_view detail
    ) noexcept;

    void report_exception(const std::exception& e);

    NodeAgent& node_agent_;
    CoordinatorEventClient* event_client_ = nullptr;

    mutable std::mutex mutex_;
};

} // namespace ssr
