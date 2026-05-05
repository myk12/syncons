from __future__ import annotations

from scenario_assertions import assert_named_scenario


def test_one_round_delay_scenario_alias() -> None:
    assert_named_scenario("one_epoch_delay")
