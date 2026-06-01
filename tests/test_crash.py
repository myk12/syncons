from __future__ import annotations

from scenario_assertions import assert_named_scenario


def test_node2_crash() -> None:
    assert_named_scenario("node2_crash")


def test_quorum_loss() -> None:
    assert_named_scenario("quorum_loss")
