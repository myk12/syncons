from __future__ import annotations

from sim.core.node import Node
from sim.core.types import EpochStage, MembershipState, NodeStatus, Packet


def stage(
    rows: dict[int, int],
    *,
    proposals: dict[int, str] | None = None,
    node_count: int = 3,
    membership_bitmap: int | None = None,
    epoch_id: int = 0,
) -> EpochStage:
    if membership_bitmap is None:
        membership_bitmap = (1 << node_count) - 1
    return EpochStage(
        epoch_id=epoch_id,
        membership_epoch=0,
        membership_bitmap=membership_bitmap,
        my_bitmap=1,
        proposals={} if proposals is None else proposals,
        ack_matrix=rows,
    )


def proposals_for(*members: int) -> dict[int, str]:
    return {member: f"node{member}" for member in members}


def test_certified_row_commit_set_and_witness_core_split_cleanly() -> None:
    node = Node(node_id=0, node_count=3)
    s = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )

    assert node._certified_row(s) == 0b111
    assert node._witness_core(s) == 0b101
    assert node._commit_set(s) == 0b111


def test_local_node_only_acts_on_its_own_quorum_certified_row() -> None:
    node = Node(node_id=2, node_count=3)
    s = stage(
        {0: 0b111, 1: 0b111, 2: 0b101},
        proposals=proposals_for(0, 1, 2),
    )

    assert node._certified_row(s) is None
    assert node._witness_core(s) is None
    assert node._commit_set(s) is None


def test_commit_set_requires_locally_available_proposals() -> None:
    node = Node(node_id=0, node_count=3)
    s = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 2),
    )

    assert node._certified_row(s) == 0b111
    assert node._witness_core(s) == 0b101
    assert node._commit_set(s) is None


def test_epoch_boundary_commits_old_row_and_shrinks_to_witness_core() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.fast_path_bitmap = 0b111
    node.current_epoch = 2
    node.commit_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )

    decision, continuation_group = node._evaluate_epoch_boundary()

    assert decision == "CONTINUE"
    assert continuation_group == 0b101
    assert node.status == NodeStatus.RUNNING
    assert len(node.committed_epochs) == 1
    committed = node.committed_epochs[0]
    assert committed["bitmap"] == 0b111
    assert committed["certified_row"] == 0b111
    assert committed["witness_core"] == 0b101


def test_epoch_boundary_halts_when_local_node_is_excluded_from_witness_core() -> None:
    node = Node(node_id=1, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.fast_path_bitmap = 0b111
    node.current_epoch = 2
    node.commit_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )

    decision, continuation_group = node._evaluate_epoch_boundary()

    assert decision == "HALT"
    assert continuation_group is None
    assert node.status == NodeStatus.HALTED
    assert node.status_reason == "no_certified_row"


def test_epoch_boundary_halts_on_witness_core_regrowth() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.fast_path_bitmap = 0b101
    node.current_epoch = 3
    node.commit_stage = stage(
        {0: 0b111, 1: 0b111, 2: 0b000},
        proposals=proposals_for(0, 1, 2),
    )

    decision, continuation_group = node._evaluate_epoch_boundary()

    assert decision == "HALT"
    assert continuation_group is None
    assert node.status == NodeStatus.HALTED
    assert node.status_reason == "witness_core_not_subset_of_previous_core"


def test_advance_epoch_uses_new_witness_core_for_outbound_destinations() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.fast_path_bitmap = 0b111
    node.current_epoch = 2
    node.commit_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
    )
    node.ack_stage = stage(
        {0: 0b111, 1: 0b000, 2: 0b111},
        proposals=proposals_for(0, 1, 2),
        epoch_id=1,
    )
    node.current_stage = stage({}, proposals=proposals_for(0), epoch_id=2)

    outbound = node.advance_epoch(3)

    assert outbound is not None
    assert outbound.destinations == (2,)
    assert node.fast_path_bitmap == 0b101


def test_receive_drops_stale_packet_without_mutating_local_state() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.fast_path_bitmap = 0b111
    node.run_id = 0
    node.current_epoch = 2

    before_current_bitmap = node.current_stage.my_bitmap
    before_ack_matrix = dict(node.ack_stage.ack_matrix)

    node.receive(
        Packet(
            epoch_id=0,
            src_id=1,
            run_id=0,
            ack_bitmap=0b111,
            payload="node1:epoch0",
        )
    )

    assert node.current_stage.my_bitmap == before_current_bitmap
    assert node.ack_stage.ack_matrix == before_ack_matrix
    assert node.trace[-1] == "epoch 2: drop stale packet from node 1 for epoch 0"


def test_receive_drops_old_run_packet_without_mutating_local_state() -> None:
    node = Node(node_id=0, node_count=3)
    node.membership_state = MembershipState.ACTIVE
    node.fast_path_bitmap = 0b111
    node.run_id = 2
    node.current_epoch = 5

    before_current_bitmap = node.current_stage.my_bitmap
    before_ack_matrix = dict(node.ack_stage.ack_matrix)

    node.receive(
        Packet(
            epoch_id=5,
            src_id=2,
            run_id=1,
            ack_bitmap=0b100,
            payload="node2:old-run",
        )
    )

    assert node.current_stage.my_bitmap == before_current_bitmap
    assert node.ack_stage.ack_matrix == before_ack_matrix
    assert node.trace[-1] == "epoch 5: drop packet from node 2, run_id 1 != local 2"
