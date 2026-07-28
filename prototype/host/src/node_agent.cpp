#include "ssr/node_agent.hpp"

namespace ssr {

NodeAgent::NodeAgent(
    NodeId node_id,
    DataplaneBackend& dataplane
)
    : node_id_(node_id),
    dataplane_(dataplane)
{
}


void NodeAgent::require_matching_session(
    const SessionId& session_id
) const
{
    if (!session_id_ || *session_id_ != session_id) {
        throw ClusterControlError(
            "Session ID mismatch: expected " +
            (session_id_ ? std::to_string(session_id_->high) + ":" + std::to_string(session_id_->low) : "<none>") +
            ", got " +
            std::to_string(session_id.high) + ":" + std::to_string(session_id.low)
        );
    }
}

void NodeAgent::prepare(
    const SessionId& session_id,
    const ClusterConfig& cluster_config,
    const SyncResult& sync_result
)
{
    if (session_id.is_zero()) {
        throw ClusterControlError(
            "Cannot prepare a new session while another session is active"
        );
    }

    if (state_ != NodeAgentState::Idle &&
        state_ != NodeAgentState::Stopped)
    {
        throw ClusterControlError(
            "Cannot prepare a new session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    try {
        if (dataplane_.status().state == DataplaneState::Closed) {
            dataplane_.open();
        }

        dataplane_.reset();

        const auto local_config = cluster_config.for_node(node_id_);

        dataplane_.configure(local_config);
        dataplane_.synchronize(sync_result);

        // Publish the session only after every dataplane operation has succeeded.
        session_id_ = session_id;
        state_ = NodeAgentState::Ready;
    }
    catch (const std::exception& e) {
        state_ = NodeAgentState::Failed;
        throw;
    }
}

void NodeAgent::start(
    const SessionId& session_id,
    const StartConfig& start_config
)
{
    require_matching_session(session_id);

    if (state_ != NodeAgentState::Ready &&
        state_ != NodeAgentState::Stopped)
    {
        throw ClusterControlError(
            "Cannot start a session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    try {
        dataplane_.start(start_config);
        state_ = NodeAgentState::Running;
    }
    catch (const std::exception& e) {
        state_ = NodeAgentState::Failed;
        throw;
    }
}

void NodeAgent::stop(
    const SessionId& session_id
)
{
    require_matching_session(session_id);

    if (state_ != NodeAgentState::Running) {
        throw ClusterControlError(
            "Cannot stop a session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    try {
        dataplane_.stop();
        state_ = NodeAgentState::Stopped;
    }
    catch (const std::exception& e) {
        state_ = NodeAgentState::Failed;
        throw;
    }
}

void NodeAgent::abort_session() noexcept
{
    session_id_.reset();
    state_ = NodeAgentState::Idle;

    try {
        if (dataplane_.status().state != DataplaneState::Closed) {
            dataplane_.reset();
        }

        state_ = NodeAgentState::Idle;
    } catch (...) {
        state_ = NodeAgentState::Failed;
    }
}

void NodeAgent::close() noexcept
{
    dataplane_.close();

    session_id_.reset();
    state_ = NodeAgentState::Idle;
}

} // namespace ssr
