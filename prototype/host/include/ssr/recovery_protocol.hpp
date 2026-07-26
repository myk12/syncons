#pragma once

#include "ssr/cluster.hpp"
#include "ssr/coordination.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>

namespace ssr {

using RecoveryTerm = std::uint64_t;
using EpochId = std::uint64_t;
using ProposalId = std::uint64_t;

class RecoveryProtocolError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

// SSR currently supports at most seven replicas, so a one-byte bitmask
// is sufficient to represent the live membership.
//
// Bit N corresponds to replica N.

struct ReplicaSet {
    std::uint32_t replica_count = 0;
    std::uint8_t live_mask = 0;

    void validate() const;

    [[nodiscard]]
    bool contains(NodeId node_id) const noexcept;

    [[nodiscard]]
    std::size_t live_count() const noexcept;

    [[nodiscard]]
    NodeId lowest_live_node() const;

    [[nodiscard]]
    ReplicaSet remove(NodeId node_id) const;

    [[nodiscard]]
    static ReplicaSet all(std::uint32_t replica_count);
    
    bool operator==(const ReplicaSet&) const = default;
};


enum class FailureReason : std::uint8_t {
    HeartbeatTimeout = 1,
    LinkDown = 2,
    ProtocolTimeout = 3,
    DataplaneError = 4,
    OperatorInjected = 5,
};

// The recovery state that every replica must agree on.
// 
// - session_id:
//      identifies one experiment run.
//
// - term:
//      identifies the current coordinator leadership term.
//
// - epoch:
//      identifies the current dataplane membership/configuration epoch.
//
// - coordinator_id:
//      coordinate for the current term.
//

struct RecoveryView {
    SessionId session_id{};

    RecoveryTerm term = 0;
    EpochId epoch = 0;

    NodeId coordinator_id = 0;

    ReplicaSet members{};

    void validate() const;

    [[nodiscard]]
    bool is_coordinator(NodeId node_id) const noexcept
    {
        return coordinator_id == node_id;
    }
};

// Any live replica must submit a failure proposal.
// submitting a proposal does not make the proposer the coordinator.
struct FailureProposal {
    SessionId session_id{};

    RecoveryTerm observed_term = 0;
    EpochId observed_epoch = 0;

    ProposalId proposal_id = 0;

    NodeId proposer_id = 0;
    NodeId suspected_node_id = 0;

    FailureReason reason = FailureReason::HeartbeatTimeout;

    void validate_against(const RecoveryView& view) const;
};

// A recovery plan is produced by the current coordinator after it accepts
// a failure proposal.
struct RecoveryPlan {
    SessionId session_id{};

    RecoveryTerm term = 0;
    EpochId epoch = 0;

    NodeId coordinator_id = 0;
    NodeId failed_node_id = 0;

    ProposalId source_proposal_id = 0;

    ReplicaSet next_members{};

    void validate_against(const RecoveryView& view) const;
};

// Validate and apply a coordinator-generated recovery plan.
// The returned view keeps the same term and coordinator, but 
// advances the run and installs the new membership.
[[nodiscard]]
RecoveryView apply_recovery_plan(const RecoveryView& view, const RecoveryPlan& plan);

} // namespace ssr