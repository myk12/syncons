from __future__ import annotations

import pytest

from scenario_assertions import run_named_scenario
from sim.core.scenarios import SCENARIOS


def committed_value(entry: dict[str, object]) -> tuple[object, object, object]:
    return (
        entry["membership_epoch"],
        entry["bitmap"],
        tuple(sorted(entry["proposals"].items())),
    )


def assert_no_conflicting_committed_epochs(result: dict[str, object]) -> None:
    committed_by_epoch: dict[int, tuple[object, object, object]] = {}

    for node in result["nodes"]:
        for entry in node["committed_epochs"]:
            epoch = int(entry["epoch"])
            value = committed_value(entry)
            previous = committed_by_epoch.setdefault(epoch, value)
            assert value == previous, (
                f"conflicting commit for epoch {epoch}: "
                f"node {node['node_id']} committed {value}, previous {previous}"
            )


def assert_each_node_commits_a_contiguous_prefix(result: dict[str, object]) -> None:
    for node in result["nodes"]:
        epochs = [entry["epoch"] for entry in node["committed_epochs"]]
        assert epochs == list(range(len(epochs))), (
            f"node {node['node_id']} committed non-prefix epochs {epochs}"
        )


@pytest.mark.parametrize("scenario_name", sorted(SCENARIOS))
def test_built_in_scenarios_have_no_conflicting_commits(scenario_name: str) -> None:
    result = run_named_scenario(scenario_name)

    assert_no_conflicting_committed_epochs(result)
    assert_each_node_commits_a_contiguous_prefix(result)
