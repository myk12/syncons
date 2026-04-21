from __future__ import annotations

import argparse
import json

from .cluster import ClusterRun
from .scenarios import SCENARIOS
from .types import ScenarioExpectation, bitmap_text


def text_summary(result: dict[str, object]) -> str:
    lines = [
        f"Cluster run: {result['node_count']} nodes for {result['epochs']} epochs",
        "",
    ]
    for node in result["nodes"]:
        committed = [entry["epoch"] for entry in node["committed_epochs"]]
        lines.append(
            f"Node {node['node_id']}: status={node['status']}, committed={committed}, halted_epoch={node['halted_epoch']}"
        )
        if node["halt_details"] is not None:
            details = node["halt_details"]
            lines.append(
                "  "
                + "halt failed_epoch="
                + str(details["failed_epoch"])
                + f" expected={bitmap_text(details['expected_bitmap'], result['node_count'])}"
                + f" mismatches={list(details['mismatch_rows'])}"
            )
    return "\n".join(lines)


def evaluate_expectation(result: dict[str, object], expectation: ScenarioExpectation) -> list[str]:
    return expectation.check(result)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Reference simulator for Safe-ABSC.")
    parser.add_argument(
        "scenario",
        choices=sorted(SCENARIOS),
        help="Built-in fault scenario to execute.",
    )
    parser.add_argument(
        "--epochs",
        type=int,
        default=None,
        help="Number of epochs to simulate.",
    )
    parser.add_argument(
        "--nodes",
        type=int,
        default=3,
        help="Cluster size.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the full trace as JSON.",
    )
    parser.add_argument(
        "--show-events",
        action="store_true",
        help="Print cluster event log after the summary.",
    )
    parser.add_argument(
        "--show-trace",
        action="store_true",
        help="Print per-node traces after the summary.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check the scenario result against its built-in expectation.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    spec = SCENARIOS[args.scenario]
    run = ClusterRun(
        node_count=args.nodes,
        epochs=spec.epochs if args.epochs is None else args.epochs,
        fault_model=spec.fault_model,
        activity_model=spec.activity_model,
        control_plane_model=spec.control_plane_model,
    )
    result = run.run()
    result["scenario"] = args.scenario
    result["description"] = spec.description

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    print(f"Scenario: {args.scenario}")
    print(spec.description)
    print()
    print(text_summary(result))

    failures: list[str] = []
    if args.check:
        failures = evaluate_expectation(result, spec.expectation)
        if failures:
            print("\nExpectation check: FAIL")
            for failure in failures:
                print(f"- {failure}")
        else:
            print("\nExpectation check: PASS")

    if args.show_events:
        print("\nEvent log:")
        for entry in result["event_log"]:
            print(entry)

    if args.show_trace:
        for node in result["nodes"]:
            print(f"\nTrace for node {node['node_id']}:")
            for entry in node["trace"]:
                print(entry)

    return 1 if failures else 0
