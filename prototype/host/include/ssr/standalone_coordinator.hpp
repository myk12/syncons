#pragma once

#include "ssr/cluster.hpp"
#include "ssr/node_agent.hpp"

#include <cstddef>
#include <optional>
#include <vector>

namespace ssr {

class StandaloneCoordinator {
public:
    explicit StandaloneCoordinator(
        std::size_t expected_node_count
    );

    void register_node(NodeAgent& node);

    [[nodiscard]]
    std::size_t expected_node_count() const noexcept
    {
        return nodes_.size();
    }

    [[nodiscard]]
    std::size_t registered_node_count() const noexcept;

    [[nodiscard]]
    bool all_nodes_registered() const noexcept;

    [[nodiscard]]
    CoordinatorState state() const noexcept
    {
        return state_;
    }

    [[nodiscard]]
    const std::optional<SessionId> &
    current_session() const noexcept
    {
        return current_session_;
    }

    void prepare_session(
        const SessionId& session_id,
        const ClusterConfig& cluster_config,
        const SyncResult& sync_result
    );

    void start_session(
        const StartConfig& start_config
    );

    void stop_session();

    // Reset all registered nodes and clear the current session.
    void reset();

private:
    void fail_and_abort() noexcept;

    std::vector<NodeAgent*> nodes_;

    CoordinatorState state_ = CoordinatorState::CollectingNodes;

    std::optional<SessionId> current_session_;
};

} // namespace ssr
