from __future__ import annotations

import pytest

from scenario_assertions import run_named_scenario
from sim.scenarios.builtin import SCENARIOS


def committed_value(entry: dict[str, object]) -> tuple[object, object, object]:
    return (
        entry["membership_epoch"],
        entry["commit_set"],
        tuple(sorted(entry["proposals"].items())),
    )


def assert_no_conflicting_committed_rounds(result: dict[str, object]) -> None:
    committed_by_round: dict[int, tuple[object, object, object]] = {}

    for node in result["nodes"]:
        for entry in node["committed_rounds"]:
            round_id = int(entry["round"])
            value = committed_value(entry)
            previous = committed_by_round.setdefault(round_id, value)
            assert value == previous, (
                f"conflicting commit for round {round_id}: "
                f"node {node['node_id']} committed {value}, previous {previous}"
            )


def assert_each_node_commits_a_contiguous_prefix(result: dict[str, object]) -> None:
    for node in result["nodes"]:
        rounds = [entry["round"] for entry in node["committed_rounds"]]
        assert rounds == list(range(len(rounds))), (
            f"node {node['node_id']} committed non-prefix rounds {rounds}"
        )


@pytest.mark.parametrize("scenario_name", sorted(SCENARIOS))
def test_built_in_scenarios_have_no_conflicting_commits(scenario_name: str) -> None:
    result = run_named_scenario(scenario_name)

    assert_no_conflicting_committed_rounds(result)
    if scenario_name not in {"asymmetric_loss", "controlled_rejoin", "online_rejoin"}:
        assert_each_node_commits_a_contiguous_prefix(result)
