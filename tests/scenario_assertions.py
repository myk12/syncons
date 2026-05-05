from __future__ import annotations

from sim.runtime.cluster import ClusterRun
from sim.scenarios.builtin import SCENARIOS


def run_named_scenario(name: str, *, node_count: int = 3, rounds: int | None = None) -> dict[str, object]:
    spec = SCENARIOS[name]
    run = ClusterRun(
        node_count=node_count,
        rounds=spec.rounds if rounds is None else rounds,
        network_fault_model=spec.network_fault_model,
        node_fault_model=spec.node_fault_model,
    )
    return run.run()


def assert_named_scenario(name: str, *, node_count: int = 3, rounds: int | None = None) -> dict[str, object]:
    spec = SCENARIOS[name]
    result = run_named_scenario(name, node_count=node_count, rounds=rounds)
    failures = spec.expectation.check(result)
    assert not failures, f"{name} expectation failures: {failures}"
    return result
