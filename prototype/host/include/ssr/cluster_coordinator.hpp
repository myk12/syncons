#pragma once

#include "ssr/cluster.hpp"
#include "ssr_control.grpc.pb.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace ssr {

struct AgentEndpoint {
    NodeId node_id{};
    std::string address;
};

struct NodeRpcResult {
    NodeId node_id{};
    grpc::StatusCode status_code = grpc::StatusCode::UNKNOWN;
    std::string message;
    control::v1::NodeReply reply;

    [[nodiscard]]
    bool ok() const noexcept
    {
        return status_code == grpc::StatusCode::OK;
    }
};

struct ClusterOperationResult {
    CoordinatorState final_state = CoordinatorState::Failed;

    std::vector<NodeRpcResult> node_results;
    std::vector<NodeRpcResult> rollback_results;

    [[nodiscard]]
    bool ok() const noexcept;
};

using NodeSyncResults = std::map<NodeId, SyncResult>;

class ClusterCoordinator {
public:
    explicit ClusterCoordinator(std::vector<AgentEndpoint> endpoints,
                                std::chrono::milliseconds rpc_timeout = std::chrono::milliseconds(1000));

    ClusterCoordinator(const ClusterCoordinator&) = delete;
    ClusterCoordinator& operator=(const ClusterCoordinator&) = delete;

    [[nodiscard]]
    CoordinatorState state() const noexcept
    {
        return state_.load(std::memory_order_acquire);
    }

    [[nodiscard]]
    std::optional<SessionId> session_id() const;

    [[nodiscard]]
    std::size_t node_count() const noexcept
    {
        return agents_.size();
    }

    ClusterOperationResult prepare(const SessionId& session_id,
                                    const ClusterConfig& config_config,
                                    const NodeSyncResults& sync_results);
    ClusterOperationResult start(const StartConfig& start_config);
    ClusterOperationResult stop();
    ClusterOperationResult reset();
    [[nodiscard]]
    std::vector<NodeRpcResult> get_status();

    void handle_node_event(const control::v1::NodeEventReport& event_report) noexcept;

    struct AgentClient {
        AgentClient(NodeId node_id, std::string address);
        NodeId node_id{};
        std::string address;

        std::shared_ptr<grpc::Channel> channel;
        std::unique_ptr<control::v1::NodeAgentService::Stub> stub;
    };

private:
    void require_state(CoordinatorState expected, const char* operation) const;
    void require_startable_state() const;

    [[nodiscard]]
    std::vector<NodeRpcResult> reset_all_unlocked();
    
    [[nodiscard]]
    bool fault_observed_since(std::uint64_t generation) const noexcept;

    std::vector<AgentClient> agents_;

    std::chrono::milliseconds rpc_timeout_;

    mutable std::mutex operation_mutex_;

    std::atomic<CoordinatorState> state_{CoordinatorState::Idle};

    std::atomic<std::uint64_t> fault_generation_{0};

    std::optional<SessionId> session_id_;
};

} // namespace ssr
