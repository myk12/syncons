from __future__ import annotations

from scenario_assertions import assert_named_scenario


def test_future_round_skew_scenario_alias() -> None:
    assert_named_scenario("future_epoch_skew")


def test_sound_bitmap_corruption_scenario_alias() -> None:
    assert_named_scenario("ack_bitmap_corruption")


def test_controlled_rejoin_scenario_alias() -> None:
    assert_named_scenario("controlled_rejoin")
