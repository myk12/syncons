#pragma once

#include "ssr/ssr.h"
#include "ssr/agent_dataplane_backend.hpp"

namespace ssr {


class SSRAgent {
public:
    SSRAgent(NodeId node_id, DataplaneBackend& backend) noexcept
        : node_id_(node_id), backend_(backend)
    {
    };
    virtual ~SSRAgent() = default;

    SSRAgent(const SSRAgent&) = delete;
    SSRAgent& operator=(const SSRAgent&) = delete;

    void prepare(const SessionId& session_id, const RunConfig& run_config);
    void start(const SessionId& session_id);
    void stop(const SessionId& session_id);

    [[nodiscard]]
    AgentState state() const noexcept
    {
        return state_;
    }

    [[nodiscard]]
    NodeId node_id() const noexcept
    {
        return node_id_;
    }

    SessionId session_id() const noexcept
    {
        return session_id_;
    }

    DataplaneBackend& backend() noexcept
    {
        return backend_;
    }

private:
    NodeId node_id_;
    DataplaneBackend& backend_;
    AgentState state_ = AgentState::Idle;
    SessionId session_id_{};
};

} // namespace ssr
