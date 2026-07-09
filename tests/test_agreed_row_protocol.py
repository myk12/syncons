from __future__ import annotations

from sim.protocol.node import Node
from sim.protocol.types import MembershipState, NodeStatus, Packet, PendingConfig, PendingConfigStatus, RoundStage


def stage(
    rows: dict[int, int],
    *,
    proposals: dict[int, str] | None = None,
    node_count: int = 3,
    installed_membership: int | None = None,
    round_id: int = 0,
) -> RoundStage:
    if installed_membership is None:
        installed_membership = (1 << node_count) - 1
    return RoundStage(
        round_id=round_id,
        membership_epoch=0,
        installed_membership=installed_membership,
        sound_bitmap=1,
        proposals={} if proposals is None else proposals,
        sound_matrix=rows,
    )


def proposals_for(*members: int) -> dict[int, str]:
    return {member: f"node{member}" for member in members}


def test_agreed_row_commit_set_and_sound_set_split_cleanly() -> None:
    node = Node(node_id=0, node_count=3)
    s = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )

    assert node._agreed_row(s) == 0b111
    assert node._sound_set(s) == 0b101
    assert node._commit_set(s) == 0b111


def test_local_node_only_acts_on_its_own_quorum_agreed_row() -> None:
    node = Node(node_id=2, node_count=3)
    s = stage(
        {0: 0b111, 1: 0b111, 2: 0b101},
        proposals=proposals_for(0, 1, 2),
    )

    assert node._agreed_row(s) is None
    assert node._sound_set(s) is None
    assert node._commit_set(s) is None


def test_commit_set_requires_locally_available_proposals() -> None:
    node = Node(node_id=0, node_count=3)
    s = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 2),
    )

    assert node._agreed_row(s) == 0b111
    assert node._sound_set(s) == 0b101
    assert node._commit_set(s) is None


def test_round_boundary_commits_old_row_and_shrinks_to_sound_set() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.current_sound_set = 0b111
    node.current_round = 2
    node.commit_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )

    decision, continuation_group, new_commits = node._evaluate_round_boundary()

    assert decision == "CONTINUE"
    assert continuation_group == 0b101
    assert len(new_commits) == 1
    assert node.status == NodeStatus.RUNNING
    committed = new_commits[0]
    assert committed.commit_set == 0b111
    assert committed.proposals == proposals_for(0, 1, 2)
    assert node.committed_frontier == 0
    assert node.last_committed_sound_set == 0b101


def test_round_boundary_halts_when_local_node_is_excluded_from_sound_set() -> None:
    node = Node(node_id=1, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.current_sound_set = 0b111
    node.current_round = 2
    node.commit_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )

    decision, continuation_group, new_commits = node._evaluate_round_boundary()

    assert decision == "HALT"
    assert continuation_group is None
    assert new_commits == ()
    assert node.status == NodeStatus.HALTED
    assert node.status_reason == "no_agreed_row"


def test_round_boundary_halts_on_sound_set_regrowth() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.current_sound_set = 0b101
    node.current_round = 3
    node.commit_stage = stage(
        {0: 0b111, 1: 0b111, 2: 0b000},
        proposals=proposals_for(0, 1, 2),
    )

    decision, continuation_group, new_commits = node._evaluate_round_boundary()

    assert decision == "HALT"
    assert continuation_group is None
    assert new_commits == ()
    assert node.status == NodeStatus.HALTED
    assert node.status_reason == "sound_set_not_subset_of_previous_set"


def test_advance_round_uses_new_sound_set_for_outbound_destinations() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.current_sound_set = 0b111
    node.current_round = 2
    node.commit_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )
    node.evidence_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
        round_id=1,
    )
    node.current_stage = stage({}, proposals=proposals_for(0), round_id=2)

    round_result = node.advance_round(3)

    assert round_result.outbound is not None
    assert round_result.outbound.destinations == (2,)
    assert len(round_result.new_commits) == 1
    assert node.current_sound_set == 0b101


def test_receive_drops_stale_packet_without_mutating_local_state() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.current_sound_set = 0b111
    node.run_id = 0
    node.current_round = 2

    before_current_bitmap = node.current_stage.sound_bitmap
    before_sound_matrix = dict(node.evidence_stage.sound_matrix)

    node.receive(
        Packet(
            round_id=0,
            src_id=1,
            run_id=0,
            sound_bitmap=0b111,
            payload="node1:round0",
        )
    )

    assert node.current_stage.sound_bitmap == before_current_bitmap
    assert node.evidence_stage.sound_matrix == before_sound_matrix
    assert node.current_round == 2
    assert node.run_id == 0


def test_receive_drops_old_run_packet_without_mutating_local_state() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.current_sound_set = 0b111
    node.run_id = 2
    node.current_round = 5

    before_current_bitmap = node.current_stage.sound_bitmap
    before_sound_matrix = dict(node.evidence_stage.sound_matrix)

    node.receive(
        Packet(
            round_id=5,
            src_id=2,
            run_id=1,
            sound_bitmap=0b100,
            payload="node2:old-run",
        )
    )

    assert node.current_stage.sound_bitmap == before_current_bitmap
    assert node.evidence_stage.sound_matrix == before_sound_matrix
    assert node.current_round == 5
    assert node.run_id == 2


def test_committed_pending_config_activates_locally_at_effective_round() -> None:
    node = Node(node_id=2, node_count=3)
    node.membership_state = MembershipState.REJOIN_PENDING
    node.current_sound_set = 0b111
    node.run_id = 0
    node.installed_membership_epoch = 0
    node.installed_membership = 0b111
    node.pending_config = PendingConfig(
        membership_epoch=1,
        members_bitmap=0b111,
        effective_round=7,
        run_id=1,
        status=PendingConfigStatus.COMMITTED,
    )

    assert node._activate_pending_config_if_due(6) is False
    assert node.pending_config is not None

    assert node._activate_pending_config_if_due(7) is True
    assert node.pending_config is None
    assert node.membership_state == MembershipState.ACTIVE
    assert node.installed_membership_epoch == 1
    assert node.run_id == 1


def test_rejoin_pending_node_skips_fast_path() -> None:
    node = Node(node_id=2, node_count=3)
    node.status = NodeStatus.RUNNING
    node.membership_state = MembershipState.REJOIN_PENDING
    node.current_sound_set = 0b111

    round_result = node.advance_round(10)

    assert round_result.outbound is None
    assert round_result.new_commits == ()
    assert node.membership_state == MembershipState.REJOIN_PENDING
    assert node.current_round == 10
    assert node.committed_frontier == -1
