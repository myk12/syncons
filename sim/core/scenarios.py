from __future__ import annotations

from .faults import (
    all_nodes_active,
    control_plane_all_active,
    control_plane_node2_rejoin,
    control_plane_node2_removed,
    control_plane_quorum_loss,
    node2_crashes_after_epoch0,
    node2_reboots_under_control_plane,
    nodes1and2_crash_after_epoch0,
    scenario_asymmetric_loss,
    scenario_ack_bitmap_corruption,
    scenario_duplicate_same_epoch,
    scenario_future_epoch_skew,
    scenario_node2_crash_after_epoch0,
    scenario_one_epoch_delay,
    scenario_perfect,
    scenario_quorum_loss,
    scenario_stale_replay,
)
from .types import ScenarioExpectation, ScenarioSpec


SCENARIOS: dict[str, ScenarioSpec] = {
    "perfect": ScenarioSpec(
        fault_model=scenario_perfect,
        activity_model=all_nodes_active,
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
        fault_model=scenario_node2_crash_after_epoch0,
        activity_model=node2_crashes_after_epoch0,
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
        fault_model=scenario_asymmetric_loss,
        activity_model=all_nodes_active,
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
        fault_model=scenario_one_epoch_delay,
        activity_model=all_nodes_active,
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
        fault_model=scenario_quorum_loss,
        activity_model=nodes1and2_crash_after_epoch0,
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
        fault_model=scenario_stale_replay,
        activity_model=all_nodes_active,
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
        fault_model=scenario_duplicate_same_epoch,
        activity_model=all_nodes_active,
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
        fault_model=scenario_future_epoch_skew,
        activity_model=all_nodes_active,
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
        fault_model=scenario_ack_bitmap_corruption,
        activity_model=all_nodes_active,
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
        fault_model=scenario_perfect,
        activity_model=node2_reboots_under_control_plane,
        control_plane_model=control_plane_node2_rejoin,
        epochs=7,
        description="Node 2 crashes, recovers under control-plane supervision, and only re-enters the fast path at an explicit epoch boundary.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_epochs=((0, 1, 2, 3, 4), (0, 1, 2, 3, 4), (4,)),
            halted_epochs=(None, None, 1),
        ),
    ),
}
