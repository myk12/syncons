from __future__ import annotations

from scenario_assertions import run_named_scenario


def test_stable_control_plane_mailbox_is_not_rewritten_every_round() -> None:
    result = run_named_scenario("perfect", rounds=4)
    node0_trace = result["nodes"][0]["trace"]

    control_plane_traces = [entry for entry in node0_trace if "control plane" in entry]

    assert control_plane_traces == []
    transitions = [
        next(item for item in round_record["transitions"] if item["node_id"] == 0)
        for round_record in result["round_trace"]
    ]
    assert transitions[0]["control_plane"] == "applied"
    for transition in transitions[1:]:
        assert transition["control_plane"] == "none"
