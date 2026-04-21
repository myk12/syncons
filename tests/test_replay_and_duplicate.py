from __future__ import annotations

from scenario_assertions import assert_named_scenario


def test_stale_replay() -> None:
    assert_named_scenario("stale_replay")


def test_duplicate_same_epoch() -> None:
    assert_named_scenario("duplicate_same_epoch")
