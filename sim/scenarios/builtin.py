from __future__ import annotations

from ..control.control_plane import OnlineRejoinControlPlane
from .faults import (
    all_nodes_active,
    network_sound_bitmap_corruption,
    network_asymmetric_loss,
    network_bridge_partition,
    network_future_round_skew,
    network_one_round_delay,
    network_perfect,
    network_quorum_loss,
    node2_crashes_after_round0,
    node2_reboots_under_control_plane,
    nodes1and2_crash_after_round0,
)
from ..protocol.types import ScenarioExpectation, ScenarioSpec


SCENARIOS: dict[str, ScenarioSpec] = {
    "perfect": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=all_nodes_active,
        rounds=5,
        description="No faults. All nodes should fast-commit and remain running.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_rounds=((0, 1, 2), (0, 1, 2), (0, 1, 2)),
            halted_rounds=(None, None, None),
        ),
    ),
    "node2_crash": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=node2_crashes_after_round0,
        rounds=5,
        description="Node 2 crashes after round 0. Nodes 0 and 1 still send to node 2 for one more round, then shrink their sound set to the surviving pair once the missing row is exposed through the sound matrix.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "CRASHED"),
            committed_rounds=((0, 1, 2), (0, 1, 2), ()),
            halted_rounds=(None, None, 1),
        ),
    ),
    "asymmetric_loss": ScenarioSpec(
        network_fault_model=network_asymmetric_loss,
        node_fault_model=all_nodes_active,
        rounds=40,
        description="One asymmetric drop in round 0 lets nodes 0 and 1 continue on a shrunk sound set while node 2 halts. The control plane then observes the halt, repairs node 2 in the background, and coordinates an online rejoin via prepare/ack/commit cutover.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_rounds=(
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 36, 37),
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 36, 37),
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 36, 37),
            ),
            halted_rounds=(None, None, None),
        ),
    ),
    "bridge_partition": ScenarioSpec(
        network_fault_model=network_bridge_partition,
        node_fault_model=all_nodes_active,
        rounds=5,
        description="Nodes 1 and 2 both miss each other in round 0, creating a split-view partition rather than a clean asymmetric loss. Node 0 still commits round 0 from its complete local view, while nodes 1 and 2 halt immediately on missing commit evidence and node 0 halts one round later once the split view reaches its local sound matrix.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "HALTED", "HALTED"),
            committed_rounds=((0,), (), ()),
            halted_rounds=(3, 2, 2),
        ),
    ),
    "one_epoch_delay": ScenarioSpec(
        network_fault_model=network_one_round_delay,
        node_fault_model=all_nodes_active,
        rounds=5,
        description="A delayed packet perturbs the local sound sets. Node 0 shrinks away from the delayed sender and later halts on the resulting disagreement, while nodes 1 and 2 continue together on the surviving sound set.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "RUNNING", "RUNNING"),
            committed_rounds=((0,), (0, 1, 2), (0, 1, 2)),
            halted_rounds=(3, None, None),
        ),
    ),
    "quorum_loss": ScenarioSpec(
        network_fault_model=network_quorum_loss,
        node_fault_model=nodes1and2_crash_after_round0,
        rounds=5,
        description="Nodes 1 and 2 crash after round 0. Node 0 keeps the installed membership unchanged, then halts once quorum loss is exposed through the missing rows in its local sound matrix.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "CRASHED", "CRASHED"),
            committed_rounds=((), (), ()),
            halted_rounds=(2, 1, 1),
        ),
    ),
    "future_epoch_skew": ScenarioSpec(
        network_fault_model=network_future_round_skew,
        node_fault_model=all_nodes_active,
        rounds=5,
        description="One node labels a round-0 packet as round 1. Nodes 0 and 1 therefore miss node 2's round-0 proposal and halt on an invalid commit set, while node 2 commits round 0 locally and halts one round later when no agreed row remains.",
        expectation=ScenarioExpectation(
            statuses=("HALTED", "HALTED", "HALTED"),
            committed_rounds=((), (), (0,)),
            halted_rounds=(2, 2, 3),
        ),
    ),
    "ack_bitmap_corruption": ScenarioSpec(
        network_fault_model=network_sound_bitmap_corruption,
        node_fault_model=all_nodes_active,
        rounds=5,
        description="A corrupted sound bitmap causes node 2 to derive an incompatible local sound set and halt, while nodes 0 and 1 continue after committing the same old rounds.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "HALTED"),
            committed_rounds=((0, 1, 2), (0, 1, 2), (0,)),
            halted_rounds=(None, None, 3),
        ),
    ),
    "controlled_rejoin": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=node2_reboots_under_control_plane,
        rounds=55,
        description="Compatibility alias for the single online rejoin control-plane strategy: node 2 crashes after round 0, is repaired in the background, and rejoins via prepare/ack/commit cutover at a future round boundary.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_rounds=(
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52),
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52),
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52),
            ),
            halted_rounds=(None, None, None),
        ),
    ),
    "online_rejoin": ScenarioSpec(
        network_fault_model=network_perfect,
        node_fault_model=node2_reboots_under_control_plane,
        rounds=40,
        description="Node 2 crashes after round 0, while nodes 0 and 1 continue on a shrunk sound set. The control plane repairs node 2 in the background, runs a prepare/ack/commit cutover, and all nodes switch to a fresh run at a future round boundary.",
        expectation=ScenarioExpectation(
            statuses=("RUNNING", "RUNNING", "RUNNING"),
            committed_rounds=(
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 35, 36, 37),
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 35, 36, 37),
                (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 35, 36, 37),
            ),
            halted_rounds=(None, None, None),
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
    "online_rejoin",
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
