#include "ssr/recovery_protocol.hpp"

#include <limits>

namespace ssr {

namespace {

constexpr std::uint32_t kMaximumReplicaCount = 7;

[[nodiscard]]
bool session_id_is_zero(const SessionId& session_id) noexcept
{
    return session_id.high == 0 && session_id.low == 0;
}

[[nodiscard]]
bool failure_reason_is_valid(FailureReason reason) noexcept
{
    switch (reason) {
        case FailureReason::HeartbeatTimeout:
        case FailureReason::LinkDown:
        case FailureReason::ProtocolTimeout:
        case FailureReason::DataplaneError:
        case FailureReason::OperatorInjected:
            return true;
        default:
            return false;
    }
    
    return false;
}

} // namespace

void ReplicaSet::validate() const
{
    if (replica_count == 0 || replica_count > kMaximumReplicaCount) {
        throw RecoveryProtocolError("Invalid replica count");
    }

    const std::uint16_t allowed_mask = static_cast<std::uint16_t>((1 << replica_count) - 1);

    const std::uint16_t actual_mask = static_cast<std::uint16_t>(live_mask);

    if ((actual_mask & ~allowed_mask) != 0) {
        throw RecoveryProtocolError("Invalid live mask");
    }

    if (live_mask == 0) {
        throw RecoveryProtocolError("No live replicas");
    }
}

bool ReplicaSet::contains(NodeId node_id) const noexcept
{
    const auto numeric_node_id = static_cast<std::uint32_t>(node_id);

    if (numeric_node_id >= replica_count || numeric_node_id >= 8) {
        return false;
    }

    const auto bit = static_cast<std::uint8_t>(1 << numeric_node_id);

    return (live_mask & bit) != 0;
}

std::size_t ReplicaSet::live_count() const noexcept
{
    std::size_t count = 0;

    for (std::uint32_t i = 0; i < replica_count; ++i) {
        if (contains(i)) {
            ++count;
        }
    }

    return count;
}

NodeId ReplicaSet::lowest_live_node() const
{
    validate();

    for (std::uint32_t i = 0; i < replica_count; ++i) {
        const auto candidate = static_cast<NodeId>(i);

        if (contains(candidate)) {
            return candidate;
        }
    }

    throw RecoveryProtocolError("No live replicas");
}

ReplicaSet ReplicaSet::remove(NodeId node_id) const
{
    validate();

    if (!contains(node_id)) {
        throw RecoveryProtocolError("Node is not live");
    }

    const auto numeric_node_id = static_cast<std::uint32_t>(node_id);

    const auto bit = static_cast<std::uint8_t>(1 << numeric_node_id);

    ReplicaSet result = *this;

    result.live_mask &= ~bit;

    // This version does not allow removing the final remaining replica.
    result.validate();

    return result;
}

ReplicaSet ReplicaSet::all(std::uint32_t replica_count)
{
    if (replica_count == 0 || replica_count > kMaximumReplicaCount) {
        throw RecoveryProtocolError("Invalid replica count");
    }

    const auto mask = static_cast<std::uint8_t>((1 << replica_count) - 1);

    ReplicaSet result {
        .replica_count = replica_count,
        .live_mask = mask,
    };

    result.validate();

    return result;
}

void RecoveryView::validate() const
{
    if (session_id_is_zero(session_id)) {
        throw RecoveryProtocolError("Session ID is zero");
    }

    if (term == 0) {
        throw RecoveryProtocolError("Term is zero");
    }

    if (!members.contains(coordinator_id)) {
        throw RecoveryProtocolError("Coordinator is not a member");
    }

    members.validate();
}

void FailureProposal::validate_against(const RecoveryView& current_view) const
{
    current_view.validate();

    if (session_id != current_view.session_id) {
        throw RecoveryProtocolError("Session ID mismatch");
    }

    if (observed_term != current_view.term) {
        throw RecoveryProtocolError("Observed term mismatch");
    }

    if (observed_epoch != current_view.epoch) {
        throw RecoveryProtocolError("Observed epoch mismatch");
    }

    if (proposal_id == 0) {
        throw RecoveryProtocolError("Proposal ID is zero");
    }

    if (!failure_reason_is_valid(reason)) {
        throw RecoveryProtocolError("Invalid failure reason");
    }

    if (proposer_id == suspected_node_id) {
        throw RecoveryProtocolError("Proposer cannot suspect itself");
    }

    if (!current_view.members.contains(proposer_id)) {
        throw RecoveryProtocolError("Proposer is not a member");
    }

    if (!current_view.members.contains(suspected_node_id)) {
        throw RecoveryProtocolError("Suspected node is not a member");
    }
}

void RecoveryPlan::validate_against(const RecoveryView& current_view) const
{
    current_view.validate();

    if (session_id != current_view.session_id) {
        throw RecoveryProtocolError("Session ID mismatch");
    }

    if (term != current_view.term) {
        throw RecoveryProtocolError("Term mismatch");
    }

    if (epoch != current_view.epoch) {
        throw RecoveryProtocolError("Epoch mismatch");
    }

    if (!current_view.members.contains(coordinator_id)) {
        throw RecoveryProtocolError("Coordinator is not a member");
    }

    if (!current_view.members.contains(failed_node_id)) {
        throw RecoveryProtocolError("Failed node is not a member");
    }

    if (!current_view.members.contains(coordinator_id)) {
        throw RecoveryProtocolError("Coordinator is not a member");
    }

    if (!current_view.members.contains(failed_node_id)) {
        throw RecoveryProtocolError("Failed node is not a member");
    }

    if (!current_view.members.contains(coordinator_id)) {
        throw RecoveryProtocolError("Coordinator is not a member");
    }

    if (!current_view.members.contains(failed_node_id)) {
        throw RecoveryProtocolError("Failed node is not a member");
    }

    if (!current_view.members.contains(coordinator_id)) {
        throw RecoveryProtocolError("Coordinator is not a member");
    }
}

RecoveryView apply_recovery_plan(const RecoveryView& current_view, const RecoveryPlan& plan)
{
    plan.validate_against(current_view);

    RecoveryView new_view {
        .session_id = current_view.session_id,
        .term = current_view.term,
        .epoch = current_view.epoch + 1,
        .coordinator_id = plan.coordinator_id,
        .members = plan.next_members,
    };

    new_view.validate();

    return new_view;




} // namespace ssr