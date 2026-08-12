from __future__ import annotations

from scenario_assertions import run_named_scenario


def test_halt_record_contains_recovery_metadata() -> None:
    result = run_named_scenario("asymmetric_loss", rounds=3)
    halted = result["nodes"][2]["halt_details"]

    assert halted is not None
    assert halted["installed_membership_epoch"] == halted["membership_epoch"]
    assert halted["run_id"] == 0
    assert halted["committed_frontier"] is None
    assert halted["sound_set_lineage"] is None
    assert halted["halt_reason"] == "commit_set_not_valid"
    assert isinstance(halted["log_digest"], str)
    assert len(halted["log_digest"]) == 64


def test_halt_record_frontier_tracks_last_actual_commit() -> None:
    result = run_named_scenario("ack_bitmap_corruption")

    node0_halt = result["nodes"][0]["halt_details"]
    node2_halt = result["nodes"][2]["halt_details"]

    assert node0_halt is None

    assert node2_halt is not None
    assert node2_halt["committed_frontier"] == 0
    assert node2_halt["sound_set_lineage"] == 0b101
