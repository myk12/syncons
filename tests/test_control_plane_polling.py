from __future__ import annotations

from scenario_assertions import run_named_scenario


def test_stable_control_plane_is_polled_but_not_reapplied_every_epoch() -> None:
    result = run_named_scenario("perfect", epochs=4)
    node0_trace = result["nodes"][0]["trace"]

    control_plane_traces = [entry for entry in node0_trace if "control plane" in entry]

    assert control_plane_traces == []

    observed_noop_polls = [
        entry
        for entry in result["event_log"]
        if "observed no control-plane transaction" in entry
    ]
    assert observed_noop_polls
