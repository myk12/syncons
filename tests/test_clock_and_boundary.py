from __future__ import annotations

from scenario_assertions import assert_named_scenario


def test_future_epoch_skew() -> None:
    assert_named_scenario("future_epoch_skew")


def test_ack_bitmap_corruption() -> None:
    assert_named_scenario("ack_bitmap_corruption")


def test_controlled_rejoin() -> None:
    assert_named_scenario("controlled_rejoin")
