from __future__ import annotations

from .faults import (
    all_nodes_active,
    control_plane_all_active,
    control_plane_node2_rejoin,
    control_plane_node2_removed,
    control_plane_quorum_loss,
    network_ack_bitmap_corruption,
    network_asymmetric_loss,
    network_bridge_partition,
    network_future_epoch_skew,
    network_one_epoch_delay,
    network_perfect,
    network_quorum_loss,
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
        description="Node 2 crashes after epoch 0. Nodes 0 and 1 keep certifying the same old commit row, then shrink their witness core to the surviving pair.",
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
        description="One asymmetric drop in epoch 0 still lets nodes 0 and 1 certify row 111 and then shrink to witness core {0,1}, while node 2 cannot certify its own row and halts.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "HALTED"),
            committed_epochs=((0, 1, 2), (0, 1, 2), ()),
            halted_epochs=(None, None, 2),
        ),
    ),
    "bridge_partition": ScenarioSpec(
        network_fault_model=network_bridge_partition,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="Nodes 1 and 2 both miss each other in epoch 0, so the system forms a bridge topology rather than a clean asymmetric loss. No node can certify its own self row at the first real boundary, so all nodes halt.",
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
        description="A delayed packet perturbs the local witness cores but still preserves old commit safety for a while. The mismatch is exposed a round later and all nodes eventually halt.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "HALTED", "HALTED"),
            committed_epochs=((0,), (0, 1), (0, 1)),
            halted_epochs=(3, 4, 4),
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
    "future_epoch_skew": ScenarioSpec(
        network_fault_model=network_future_epoch_skew,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="One node labels an epoch-0 packet as epoch 1. Nodes 0 and 1 still certify row 111 and shrink away from node 2, while node 2 cannot certify its own row and halts.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "HALTED"),
            committed_epochs=((0, 1, 2), (0, 1, 2), ()),
            halted_epochs=(None, None, 2),
        ),
    ),
    "ack_bitmap_corruption": ScenarioSpec(
        network_fault_model=network_ack_bitmap_corruption,
        node_fault_model=all_nodes_active,
        control_plane_model=control_plane_all_active,
        epochs=5,
        description="A corrupted ACK bitmap causes the nodes to derive incompatible local witness cores while still sharing the same old commit row. The mismatch is exposed later and all three nodes eventually halt.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "HALTED", "HALTED"),
            committed_epochs=((0, 1), (0, 1), (0, 1)),
            halted_epochs=(4, 4, 4),
        ),
    ),
    "controlled_rejoin": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=node2_reboots_under_control_plane,
        control_plane_model=control_plane_node2_rejoin,
        epochs=7,
        description="Node 2 crashes and later rejoins under control-plane coordination. Nodes 0 and 1 keep certifying old rows and continue on the surviving witness core, while node 2 still halts before re-establishing a local certificate.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "HALTED"),
            committed_epochs=((0, 1, 2, 3, 4), (0, 1, 2, 3, 4), ()),
            halted_epochs=(None, None, 6),
        ),
    ),
}

# Primary scenarios are the compact protocol-validation suite we use for
# everyday reasoning, trace inspection, and paper-facing evaluation.
PRIMARY_SCENARIOS: tuple[str, ...] = (
    "perfect",
    "node2_crash",
    "asymmetric_loss",
    "bridge_partition",
    "one_epoch_delay",
    "quorum_loss",
    "controlled_rejoin",
)

# Auxiliary scenarios cover packet-hygiene and control-plane edge defenses that
# remain useful in regression testing, but are less central to the protocol's
# main story than the primary suite above.
AUXILIARY_SCENARIOS: tuple[str, ...] = ()

# These scenarios are useful as robustness probes, but they are outside the
# protocol's nominal omission/timing fault model and should not be treated as
# part of the main protocol-validation suite.
OUT_OF_MODEL_SCENARIOS: tuple[str, ...] = (
    "ack_bitmap_corruption",
    "future_epoch_skew",
)

_scenario_partition = (
    set(PRIMARY_SCENARIOS)
    | set(AUXILIARY_SCENARIOS)
    | set(OUT_OF_MODEL_SCENARIOS)
)
assert _scenario_partition == set(SCENARIOS), (
    "PRIMARY/AUXILIARY/OUT_OF_MODEL scenario groups must partition SCENARIOS: "
    f"missing={sorted(set(SCENARIOS) - _scenario_partition)} "
    f"extra={sorted(_scenario_partition - set(SCENARIOS))}"
)
