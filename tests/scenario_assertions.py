from __future__ import annotations

from sim.core.cluster import ClusterRun
from sim.core.scenarios import SCENARIOS


def run_named_scenario(name: str, *, node_count: int = 3, epochs: int | None = None) -> dict[str, object]:
    spec = SCENARIOS[name]
    run = ClusterRun(
        node_count=node_count,
        epochs=spec.epochs if epochs is None else epochs,
        network_fault_model=spec.network_fault_model,
        node_fault_model=spec.node_fault_model,
        control_plane_model=spec.control_plane_model,
    )
    return run.run()


def assert_named_scenario(name: str, *, node_count: int = 3, epochs: int | None = None) -> dict[str, object]:
    spec = SCENARIOS[name]
    result = run_named_scenario(name, node_count=node_count, epochs=epochs)
    failures = spec.expectation.check(result)
    assert not failures, f"{name} expectation failures: {failures}"
    return result
