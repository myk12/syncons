#pragma once

#include "ssr/ssr.h"
#include "ssr/agent.hpp"
#include "ssr_control.grpc.pb.h"

#include <cstdint>
#include <mutex>
#include <string_view>
#include <exception>

namespace ssr {

class AgentRPCServiceImpl final : public control::v1::AgentService::Service {
public:
    AgentRPCServiceImpl(SSRAgent& agent) noexcept;

    grpc::Status Prepare(
        grpc::ServerContext* context,
        const control::v1::PrepareRequest* request,
        control::v1::AgentReply* reply
    ) override;

    grpc::Status Start(
        grpc::ServerContext* context,
        const control::v1::StartRequest* request,
        control::v1::AgentReply* reply
    ) override;

    grpc::Status Stop(
        grpc::ServerContext* context,
        const control::v1::StopRequest* request,
        control::v1::AgentReply* reply
    ) override;

    grpc::Status GetStatus(
        grpc::ServerContext* context,
        const control::v1::GetStatusRequest* request,
        control::v1::AgentReply* reply
    ) override;

private:
    [[nodiscard]]
    grpc::Status validate_target_node(std::uint32_t target_node_id) const;

    void fill_reply(control::v1::AgentReply* reply) const;

    SSRAgent& agent_;

    mutable std::mutex mutex_;
};

} // namespace ssr
