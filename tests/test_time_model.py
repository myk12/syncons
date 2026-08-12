from __future__ import annotations

from scenario_assertions import run_named_scenario
from sim.protocol.types import format_duration_ns, parse_duration_ns


def assert_contains_ordered_subsequence(actions: list[str], required: list[str]) -> None:
    cursor = 0
    for action in actions:
        if cursor < len(required) and action == required[cursor]:
            cursor += 1
    assert cursor == len(required), (
        f"expected ordered subsequence {required}, got actions {actions}"
    )


def test_duration_round_trip_examples() -> None:
    assert parse_duration_ns("4000ns") == 4_000
    assert parse_duration_ns("4us") == 4_000
    assert parse_duration_ns("0.5us") == 500
    assert parse_duration_ns("2ms") == 2_000_000

    assert format_duration_ns(4_000) == "4us"
    assert format_duration_ns(500) == "500ns"
    assert format_duration_ns(2_000_000) == "2ms"


def test_result_carries_timing_and_control_plane_event_metadata() -> None:
    result = run_named_scenario("bridge_partition", rounds=4)

    assert result["timing"]["round_length_ns"] == 4_000
    assert result["simulated_time_ns"] == 16_000

    halt_events = [
        event for event in result["control_plane_events"] if event["kind"] == "NodeHalted"
    ]
    assert halt_events
    assert all(event["available_at_ns"] >= 10_000 for event in halt_events)


def test_halt_event_can_start_online_rejoin_recovery() -> None:
    result = run_named_scenario("asymmetric_loss", rounds=40)

    runtime = result["control_plane_runtime"]
    assert runtime is not None
    assert_contains_ordered_subsequence(
        [item["action"] for item in runtime["applied_actions"]],
        [
            "mark_recovering",
            "prepare_online_rejoin",
            "commit_online_rejoin",
            "activate_online_rejoin",
        ],
    )

    observed_kinds = [event["kind"] for event in runtime["observed_events"]]
    assert "NodeHalted" in observed_kinds

    node2 = result["nodes"][2]
    assert node2["status"] == "RUNNING"
    assert node2["membership_state"] == "ACTIVE"
    assert node2["run_id"] == 1


def test_controlled_rejoin_exposes_cp_action_timeline_and_commit_timestamps() -> None:
    result = run_named_scenario("controlled_rejoin", rounds=55)

    runtime = result["control_plane_runtime"]
    assert runtime is not None
    assert_contains_ordered_subsequence(
        [item["action"] for item in runtime["applied_actions"]],
        [
            "mark_recovering",
            "prepare_online_rejoin",
            "commit_online_rejoin",
            "activate_online_rejoin",
        ],
    )

    node2 = result["nodes"][2]
    assert node2["status"] == "RUNNING"
    assert node2["committed_rounds"]
    full_reinstall_at = runtime["applied_actions"][-1]["time_ns"]
    first_rejoin_commit = next(
        entry
        for entry in node2["committed_rounds"]
        if entry["commit_time_ns"] >= full_reinstall_at
    )
    assert first_rejoin_commit["commit_time_ns"] >= runtime["applied_actions"][-1]["time_ns"]
    assert (
        first_rejoin_commit["app_delivery_time_ns"] - first_rejoin_commit["commit_time_ns"]
        == result["timing"]["app_delivery_delay_ns"]
    )


def test_online_rejoin_exposes_prepare_commit_activate_timeline() -> None:
    result = run_named_scenario("online_rejoin", rounds=40)

    runtime = result["control_plane_runtime"]
    assert runtime is not None
    assert_contains_ordered_subsequence(
        [item["action"] for item in runtime["applied_actions"]],
        [
            "mark_recovering",
            "prepare_online_rejoin",
            "commit_online_rejoin",
            "activate_online_rejoin",
        ],
    )
    assert runtime["prepare_acks"] == [0, 1, 2]

    node2 = result["nodes"][2]
    assert node2["status"] == "RUNNING"
    assert node2["membership_state"] == "ACTIVE"
    assert node2["run_id"] == 1
    assert node2["committed_rounds"]
    assert node2["committed_rounds"][0]["round"] == 0
    activate_at = runtime["applied_actions"][-1]["time_ns"]
    first_post_cutover = next(
        entry
        for entry in node2["committed_rounds"]
        if entry["commit_time_ns"] >= activate_at
    )
    assert first_post_cutover["round"] == 35
