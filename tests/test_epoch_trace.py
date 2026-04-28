from __future__ import annotations

from scenario_assertions import run_named_scenario


def test_epoch_trace_contains_stage_snapshots() -> None:
    result = run_named_scenario("node2_crash")
    epoch0 = result["epoch_trace"][0]

    assert epoch0["epoch"] == 0
    assert "control" in epoch0
    assert "transitions" in epoch0
    assert "network" in epoch0
    assert "node_end_state" in epoch0

    node0 = epoch0["node_end_state"][0]
    assert node0["node_id"] == 0
    assert "current_stage" in node0
    assert "ack_stage" in node0
    assert "commit_stage" in node0
    assert "ack_rows" in node0["current_stage"]
