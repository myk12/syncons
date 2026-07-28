#pragma once

#include "ssr/cluster.hpp"
#include "ssr/dataplane_backend.hpp"

#include "ssr_control.grpc.pb.h"

#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>

namespace ssr {

class CoordinatorEventClient {
public:
    CoordinatorEventClient(
        NodeId node_id,
        std::string coordinator_address,
        std::chrono::milliseconds timeout = std::chrono::milliseconds(5000));

    [[nodiscard]]
    bool report(
        const control::v1::NodeEventKind event_kind,
        const NodeAgentState node_state,
        const DataplaneStatus& dataplane_status,
        const std::optional<SessionId>& session_id,
        std::string_view detail
    ) noexcept;

private:
    NodeId node_id_;
    std::chrono::milliseconds rpc_timeout_;
    std::shared_ptr<grpc::Channel> channel_;
    std::unique_ptr<control::v1::CoordinatorService::Stub> stub_;
    std::mutex mutex_;
    std::uint64_t next_sequence_number_ = 1;
};

} // namespace ssr
