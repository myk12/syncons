from __future__ import annotations

from scenario_assertions import run_named_scenario


def test_round_trace_contains_stage_snapshots() -> None:
    result = run_named_scenario("node2_crash")
    round0 = result["round_trace"][0]

    assert round0["round"] == 0
    assert "control" in round0
    assert "transitions" in round0
    assert "network" in round0
    assert "node_end_state" in round0

    node0 = round0["node_end_state"][0]
    assert node0["node_id"] == 0
    assert "current_stage" in node0
    assert "evidence_stage" in node0
    assert "commit_stage" in node0
    assert "sound_matrix" in node0["current_stage"]
