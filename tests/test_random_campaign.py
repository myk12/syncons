from __future__ import annotations

from sim.runtime.random_campaign import RandomFaultConfig, run_campaign, sweep_campaigns


def test_random_campaign_no_fault_sanity() -> None:
    report = run_campaign(
        RandomFaultConfig(
            rounds=6,
            trials=10,
            seed=1,
        )
    )

    assert report["summary"]["safety_violation_runs"] == 0
    assert report["summary"]["halted_runs"] == 0
    assert report["summary"]["crashed_runs"] == 0
    assert report["summary"]["all_running_runs"] == 10
    assert report["summary"]["avg_committed_rounds_per_node"] == 4.0


def test_random_campaign_faults_preserve_safety_invariant() -> None:
    report = run_campaign(
        RandomFaultConfig(
            rounds=8,
            trials=20,
            seed=2,
            packet_loss=0.02,
            packet_delay=0.02,
            ack_corruption=0.01,
            duplicate=0.01,
            node_crash=0.005,
        )
    )

    assert report["summary"]["safety_violation_runs"] == 0


def test_random_campaign_sweep_outputs_plot_ready_rows() -> None:
    rows = sweep_campaigns(
        RandomFaultConfig(
            rounds=6,
            trials=5,
            seed=3,
        ),
        parameter="packet_loss",
        values=[0.0, 0.02],
    )

    assert [row["value"] for row in rows] == [0.0, 0.02]
    assert all(row["parameter"] == "packet_loss" for row in rows)
    assert all(row["safety_violation_runs"] == 0 for row in rows)
    assert all("halt_rate" in row for row in rows)
    assert rows[0]["all_running_rate"] == 1.0
    assert rows[0]["avg_committed_rounds_per_node"] == 4.0
