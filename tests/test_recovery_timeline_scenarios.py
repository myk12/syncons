from __future__ import annotations

from sim.protocol.types import SimulationTiming
from sim.runtime.cluster import ClusterRun
from sim.runtime.metrics import InMemoryMetricsCollector
from sim.scenarios.faults import (
    all_nodes_active,
    network_asymmetric_loss_at,
    network_bridge_partition_at,
    network_perfect,
    staggered_recoverable_crashes,
)


FIGURE_Z_TIMING = SimulationTiming(
    round_length_ns=4_000,
    halt_report_delay_ns=8_000,
    cp_collection_delay_ns=24_000,
    cp_decision_delay_ns=12_000,
    repair_delay_ns=64_000,
    install_delay_ns=24_000,
    reentry_delay_ns=16_000,
    app_delivery_delay_ns=5_000,
)


def committed_counts_for(
    *,
    rounds: int,
    network_fault_model,
    node_fault_model,
) -> list[int]:
    collector = InMemoryMetricsCollector()
    run = ClusterRun(
        node_count=5,
        rounds=rounds,
        network_fault_model=network_fault_model,
        node_fault_model=node_fault_model,
        timing=FIGURE_Z_TIMING,
        metrics_sink=collector,
    )
    run.run()
    return [summary.committed_txns for summary in collector.rounds]


def test_recovery_timeline_node_crash_story_has_5_to_4_to_3_to_5_shape() -> None:
    counts = committed_counts_for(
        rounds=120,
        network_fault_model=network_perfect,
        node_fault_model=staggered_recoverable_crashes(((4, 36), (3, 40))),
    )
    assert 5 in counts
    assert 4 in counts
    assert 3 in counts
    assert 5 in counts[70:]


def test_recovery_timeline_asymmetric_loss_story_has_5_to_4_to_5_shape() -> None:
    counts = committed_counts_for(
        rounds=120,
        network_fault_model=network_asymmetric_loss_at(36),
        node_fault_model=all_nodes_active,
    )
    assert 5 in counts[:30]
    assert 4 in counts[38:80]
    assert 5 in counts[70:]


def test_recovery_timeline_bridge_partition_story_has_5_to_0_to_5_shape() -> None:
    counts = committed_counts_for(
        rounds=120,
        network_fault_model=network_bridge_partition_at(36),
        node_fault_model=all_nodes_active,
    )
    assert 5 in counts[:30]
    assert 0 in counts[38:80]
    assert 5 in counts[80:]
