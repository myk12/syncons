from __future__ import annotations

from .faults import (
    all_nodes_active,
    control_plane_all_active,
    control_plane_node2_rejoin,
    control_plane_node2_removed,
    control_plane_quorum_loss,
    network_ack_bitmap_corruption,
    network_asymmetric_loss,
    network_duplicate_same_epoch,
    network_future_epoch_skew,
    network_one_epoch_delay,
    network_perfect,
    network_quorum_loss,
    network_stale_incarnation_replay,
    network_stale_replay,
    node2_crashes_after_epoch0,
    node2_reboots_under_control_plane,
    nodes1and2_crash_after_epoch0,
)
from .types import ScenarioExpectation, ScenarioSpec


SCENARIOS: dict[str, ScenarioSpec] = {
    "perfect": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="No faults. All nodes should fast-commit and remain running.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_epochs=((0, 1, 2), (0, 1, 2), (0, 1, 2)),
            halted_epochs=(None, None, None),
        ),
    ),
    "node2_crash": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=node2_crashes_after_epoch0,
        control_plane_model=control_plane_node2_removed,
        epochs=5,
        description="Node 2 crashes after epoch 0. Nodes 0 and 1 should continue with quorum.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "CRASHED"),
            committed_epochs=((0, 1, 2), (0, 1, 2), ()),
            halted_epochs=(None, None, 1),
        ),
    ),
    "asymmetric_loss": ScenarioSpec(
        network_fault_model=network_asymmetric_loss,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="One asymmetric drop in epoch 0 should surface as an ACK-view mismatch and halt nodes.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "HALTED", "HALTED"),
            committed_epochs=((), (), ()),
            halted_epochs=(2, 2, 2),
        ),
    ),
    "one_epoch_delay": ScenarioSpec(
        network_fault_model=network_one_epoch_delay,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="A delayed packet arrives too late for the collecting epoch and should be ignored.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "HALTED", "HALTED"),
            committed_epochs=((0,), (0,), (0,)),
            halted_epochs=(3, 3, 3),
        ),
    ),
    "quorum_loss": ScenarioSpec(
        network_fault_model=network_quorum_loss,
        node_fault_model=nodes1and2_crash_after_epoch0,
        control_plane_model=control_plane_quorum_loss,
        epochs=5,
        description="Two nodes crash after epoch 0. The remaining node must halt once quorum is lost.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "CRASHED", "CRASHED"),
            committed_epochs=((), (), ()),
            halted_epochs=(2, 1, 1),
        ),
    ),
    "stale_replay": ScenarioSpec(
        network_fault_model=network_stale_replay,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="A stale replay of an epoch-0 packet arrives at epoch 2 and should be dropped without changing the outcome.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_epochs=((0, 1, 2), (0, 1, 2), (0, 1, 2)),
            halted_epochs=(None, None, None),
        ),
    ),
    "duplicate_same_epoch": ScenarioSpec(
        network_fault_model=network_duplicate_same_epoch,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="A duplicate packet in the same epoch should be harmless because later receives overwrite the same sender slot.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_epochs=((0, 1, 2), (0, 1, 2), (0, 1, 2)),
            halted_epochs=(None, None, None),
        ),
    ),
    "future_epoch_skew": ScenarioSpec(
        network_fault_model=network_future_epoch_skew,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="One node labels an epoch-0 packet as epoch 1, modeling a clock-skew boundary crossing that should trigger fail-stop.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "HALTED", "HALTED"),
            committed_epochs=((), (), ()),
            halted_epochs=(2, 2, 2),
        ),
    ),
    "ack_bitmap_corruption": ScenarioSpec(
        network_fault_model=network_ack_bitmap_corruption,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="A corrupted ACK bitmap seen by one receiver at the validation boundary should halt that node, while others may continue.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "HALTED"),
            committed_epochs=((0, 1, 2), (0, 1, 2), ()),
            halted_epochs=(None, None, 2),
        ),
    ),
    "controlled_rejoin": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=node2_reboots_under_control_plane,
        control_plane_model=control_plane_node2_rejoin,
        epochs=7,
        description="Node 2 crashes, recovers under control-plane supervision, and only re-enters the fast path at an explicit epoch boundary.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_epochs=((0, 1, 2, 3, 4), (0, 1, 2, 3, 4), (4,)),
            halted_epochs=(None, None, 1),
        ),
    ),
    "stale_incarnation_replay": ScenarioSpec(
        network_fault_model=network_stale_incarnation_replay,
        node_fault_model=node2_reboots_under_control_plane,
        control_plane_model=control_plane_node2_rejoin,
        epochs=7,
        description="A replayed packet from node 2's old incarnation arrives after rejoin and must be rejected by the approved-incarnation check.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_epochs=((0, 1, 2, 3, 4), (0, 1, 2, 3, 4), (4,)),
            halted_epochs=(None, None, 1),
        ),
    ),
}
