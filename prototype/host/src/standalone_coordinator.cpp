#include "ssr/standalone_coordinator.hpp"

#include <algorithm>
#include <stdexcept>

namespace ssr {

StandaloneCoordinator::StandaloneCoordinator(
    std::size_t expected_node_count
)
    : nodes_(expected_node_count, nullptr)
{
    constexpr std::size_t max_replicas = 7;

    if (expected_node_count == 0 ||
        expected_node_count > max_replicas) {
        throw std::invalid_argument("StandaloneCoordinator must expect between 1 and 7 nodes");
    }
}

std::size_t
StandaloneCoordinator::registered_node_count() const noexcept
{
    return static_cast<std::size_t>(
        std::count_if(
            nodes_.begin(),
            nodes_.end(),
            [](const NodeAgent* node) { return node != nullptr; }
        )
    );
}

bool StandaloneCoordinator::all_nodes_registered() const noexcept
{
    return std::all_of(
        nodes_.begin(),
        nodes_.end(),
        [](const NodeAgent* node) { return node != nullptr; }
    );
}

void StandaloneCoordinator::register_node(NodeAgent& node)
{
    if (state_ != CoordinatorState::CollectingNodes &&
        state_ != CoordinatorState::Idle)
    {
        throw ClusterControlError(
            "Cannot register a new node while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    const auto node_index = static_cast<std::size_t>(node.node_id());

    if (node_index >= nodes_.size()) {
        throw ClusterControlError(
            "Node ID " + std::to_string(node.node_id()) +
            " is out of range for this coordinator"
        );
    }

    if (nodes_[node_index] != nullptr) {
        throw ClusterControlError(
            "Node ID " + std::to_string(node.node_id()) +
            " is already registered"
        );
    }

    nodes_[node_index] = &node;

    if (all_nodes_registered()) {
        state_ = CoordinatorState::Idle;
    }
}

void StandaloneCoordinator::prepare_session(
    const SessionId& session_id,
    const ClusterConfig& cluster_config,
    const SyncResult& sync_result
)
{
    if (!all_nodes_registered()) {
        throw ClusterControlError(
            "Cannot prepare a session until all nodes are registered"
        );
    }

    if (state_ != CoordinatorState::Idle &&
        state_ != CoordinatorState::Stopped)
    {
        throw ClusterControlError(
            "Cannot prepare a session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    if (session_id.is_zero()) {
        throw ClusterControlError(
            "Cannot prepare a session with a zero session ID"
        );
    }

    cluster_config.validate();

    if (cluster_config.replica_count() != nodes_.size()) {
        throw ClusterControlError(
            "Cluster configuration replica count does not match the number of registered nodes"
        );
    }

    if (!sync_result.synchronized) {
        throw ClusterControlError(
            "Cannot prepare a session with an unsynchronized SyncResult"
        );
    }

    state_ = CoordinatorState::Preparing;

    try {
        for (NodeAgent* node : nodes_) {
            node->prepare(session_id, cluster_config, sync_result);
        }

        current_session_ = session_id;
        state_ = CoordinatorState::Ready;
    }
    catch (...) {
        fail_and_abort();
        throw;
    }
}

void StandaloneCoordinator::start_session(
    const StartConfig& start_config
)
{
    if (state_ != CoordinatorState::Ready &&
        state_ != CoordinatorState::Stopped)
    {
        throw ClusterControlError(
            "Cannot start a session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    if (!current_session_.has_value()) {
        throw ClusterControlError(
            "Cannot start a session without a current session"
        );
    }

    try {
        for (NodeAgent* node : nodes_) {
            node->start(*current_session_, start_config);
        }

        state_ = CoordinatorState::Running;
    }
    catch (...) {
        fail_and_abort();
        throw;
    }
}

void StandaloneCoordinator::stop_session()
{
    if (state_ != CoordinatorState::Running) {
        throw ClusterControlError(
            "Cannot stop a session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    if (!current_session_.has_value()) {
        throw ClusterControlError(
            "Cannot stop a session without a current session"
        );
    }

    try {
        for (NodeAgent* node : nodes_) {
            node->stop(*current_session_);
        }

        state_ = CoordinatorState::Stopped;
    }
    catch (...) {
        fail_and_abort();
        throw;
    }
}

void StandaloneCoordinator::fail_and_abort() noexcept
{
    for (NodeAgent* node : nodes_) {
        if (node != nullptr) {
            node->abort_session();
        }
    }

    current_session_.reset();
    state_ = CoordinatorState::Failed;
}

void StandaloneCoordinator::reset()
{
    bool reset_succeeded = true;

    for (NodeAgent* node : nodes_) {
        if (node == nullptr) {
            continue;
        }

        node->abort_session();

        if (node->state() == NodeAgentState::Failed) {
            reset_succeeded = false;
        }
    }

    current_session_.reset();

    if (!reset_succeeded) {
        state_ = CoordinatorState::Failed;

        throw ClusterControlError(
            "Failed to reset all nodes; at least one node is in a failed state"
        );
    }

    state_ = all_nodes_registered() ? CoordinatorState::Idle : CoordinatorState::CollectingNodes;
}

} // namespace ssr
