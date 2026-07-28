#pragma once

#include "ssr/cluster.hpp"
#include "ssr/dataplane_backend.hpp"

#include <optional>

namespace ssr {

// NodeAgent controls the dataplane of one host.
class NodeAgent {
public:
    NodeAgent(
        NodeId node_id,
        DataplaneBackend& dataplane
    );

    [[nodiscard]]
    NodeId node_id() const noexcept
    {
        return node_id_;
    }

    [[nodiscard]]
    DataplaneStatus dataplane_status() const noexcept
    {
        return dataplane_.status();
    }

    [[nodiscard]]
    NodeAgentState state() const noexcept
    {
        return state_;
    }

    [[nodiscard]]
    const std::optional<SessionId>& session_id() const noexcept
    {
        return session_id_;
    }

    void prepare(
        const SessionId& session_id,
        const ClusterConfig& cluster_config,
        const SyncResult& sync_result
    );

    void start(
        const SessionId& session_id,
        const StartConfig& start_config
    );

    void stop(
        const SessionId& session_id
    );

    // Clear the active session and reset the dataplane.
    void abort_session() noexcept;

    void close() noexcept;

private:
    void require_matching_session(
        const SessionId& session_id
    ) const;

    NodeId node_id_;
    DataplaneBackend& dataplane_;

    NodeAgentState state_ = NodeAgentState::Idle;
    std::optional<SessionId> session_id_;
};

} // namespace ssr
