from __future__ import annotations

import argparse
import json

from .cluster import ClusterRun
from ..protocol.types import JsonDict, ScenarioExpectation, SimulationTiming, bitmap_text, format_duration_ns, parse_duration_ns
from ..scenarios.builtin import SCENARIOS


def _compact_round_list(rounds: list[int]) -> str:
    if not rounds:
        return "[]"
    ranges: list[str] = []
    start = rounds[0]
    end = rounds[0]
    for value in rounds[1:]:
        if value == end + 1:
            end = value
            continue
        ranges.append(str(start) if start == end else f"{start}-{end}")
        start = end = value
    ranges.append(str(start) if start == end else f"{start}-{end}")
    return "[" + ", ".join(ranges) + "]"


def text_summary(result: JsonDict) -> str:
    lines = [
        f"Cluster run: {result['node_count']} nodes for {result['rounds']} rounds",
        "Timing: "
        + f"round_length={format_duration_ns(result['timing']['round_length_ns'])} "
        + f"simulated_time={format_duration_ns(result['simulated_time_ns'])}",
        "",
    ]
    for node in result["nodes"]:
        committed = [entry["round"] for entry in node["committed_rounds"]]
        lines.append(
            f"Node {node['node_id']}: status={node['status']}, committed={_compact_round_list(committed)}, halted_round={node['halted_round']}"
        )
        if node["halt_details"] is not None:
            details = node["halt_details"]
            group = details["sound_set_lineage"]
            group_text = (
                "none"
                if group is None
                else bitmap_text(group, result["node_count"])
            )
            lines.append(
                "  "
                + "halt failed_round="
                + str(details["failed_round"])
                + f" run_id={details['run_id']}"
                + f" reason={details['halt_reason']}"
                + f" membership={bitmap_text(details['installed_membership'], result['node_count'])}"
                + f" self_row={bitmap_text(details['self_row'], result['node_count'])}"
                + f" frontier={details['committed_frontier']}"
                + f" sound_set_lineage={group_text}"
                + f" log_digest={str(details['log_digest'])[:12]}"
            )
    return "\n".join(lines)


def performance_summary_text(result: JsonDict) -> str:
    node_count = int(result["node_count"])
    simulated_time_ns = int(result["simulated_time_ns"])
    round_length_ns = int(result["timing"]["round_length_ns"])
    total_commits = sum(len(node["committed_rounds"]) for node in result["nodes"])
    max_frontier = max(
        (-1 if not node["committed_rounds"] else int(node["committed_rounds"][-1]["round"]))
        for node in result["nodes"]
    )
    cluster_commit_rounds = max_frontier + 1 if max_frontier >= 0 else 0
    cluster_commit_rate = (
        cluster_commit_rounds / (simulated_time_ns / 1_000_000_000)
        if simulated_time_ns > 0 else 0.0
    )
    per_node_commit_rate = (
        total_commits / node_count / (simulated_time_ns / 1_000_000_000)
        if simulated_time_ns > 0 and node_count > 0 else 0.0
    )
    lines = [
        "Performance summary:",
        f"  round_length={format_duration_ns(round_length_ns)}",
        f"  simulated_time={format_duration_ns(simulated_time_ns)}",
        f"  cluster_committed_rounds={cluster_commit_rounds}",
        f"  cluster_commit_rate={cluster_commit_rate:.2f} rounds/s",
        f"  mean_per_node_commit_rate={per_node_commit_rate:.2f} rounds/s",
        f"  control_plane_events={len(result.get('control_plane_events', []))}",
    ]

    control_events = result.get("control_plane_events", [])
    cp_runtime = result.get("control_plane_runtime") or {}
    applied_actions = cp_runtime.get("applied_actions", [])
    interruptions = [
        event
        for event in control_events
        if event.get("kind") in {"NodeCrashed", "NodeHalted"}
    ]
    if interruptions and applied_actions:
        first_available_ns = min(int(event["available_at_ns"]) for event in interruptions)
        mark_recovering = next(
            (int(action["time_ns"]) for action in applied_actions if action["action"] == "mark_recovering"),
            None,
        )
        prepare_at = next(
            (int(action["time_ns"]) for action in applied_actions if action["action"] == "prepare_online_rejoin"),
            None,
        )
        commit_at = next(
            (int(action["time_ns"]) for action in applied_actions if action["action"] == "commit_online_rejoin"),
            None,
        )
        activate_at = next(
            (int(action["time_ns"]) for action in applied_actions if action["action"] == "activate_online_rejoin"),
            None,
        )
        if mark_recovering is not None:
            lines.append(
                "  interruption_to_mark_recovering="
                + format_duration_ns(mark_recovering - first_available_ns)
            )
        if mark_recovering is not None and prepare_at is not None:
            lines.append(
                "  mark_recovering_to_prepare="
                + format_duration_ns(prepare_at - mark_recovering)
            )
        if prepare_at is not None and commit_at is not None:
            lines.append(
                "  prepare_to_commit="
                + format_duration_ns(commit_at - prepare_at)
            )
        if commit_at is not None and activate_at is not None:
            lines.append(
                "  commit_to_activate="
                + format_duration_ns(activate_at - commit_at)
            )
        if activate_at is not None:
            recovered_node_ids = sorted(
                {
                    int(event["node_id"])
                    for event in interruptions
                }
            )
            rejoin_commit_times = [
                int(entry["commit_time_ns"])
                for node in result["nodes"]
                if int(node["node_id"]) in recovered_node_ids
                for entry in node["committed_rounds"]
                if "commit_time_ns" in entry and int(entry["commit_time_ns"]) >= activate_at
            ]
            if rejoin_commit_times:
                lines.append(
                    "  activate_to_first_rejoin_commit="
                    + format_duration_ns(min(rejoin_commit_times) - activate_at)
                )

    app_delivery_times = [
        int(entry["app_delivery_time_ns"]) - int(entry["commit_time_ns"])
        for node in result["nodes"]
        for entry in node["committed_rounds"]
        if "commit_time_ns" in entry and "app_delivery_time_ns" in entry
    ]
    if app_delivery_times:
        mean_app_delivery_ns = sum(app_delivery_times) // len(app_delivery_times)
        lines.append(
            "  commit_to_application="
            + format_duration_ns(mean_app_delivery_ns)
        )
    return "\n".join(lines)


def evaluate_expectation(result: JsonDict, expectation: ScenarioExpectation) -> list[str]:
    return expectation.check(result)


def evaluate_expectation_for_round_budget(
    result: JsonDict,
    expectation: ScenarioExpectation,
    *,
    run_rounds: int,
    reference_rounds: int,
) -> tuple[list[str], str | None]:
    if run_rounds == reference_rounds:
        return expectation.check(result), None

    if run_rounds < reference_rounds:
        return [], (
            "SKIPPED (custom round budget is shorter than the built-in scenario; "
            "the run may not have reached the reference terminal behavior)"
        )

    failures: list[str] = []
    nodes = result["nodes"]

    actual_statuses = tuple(node["status"] for node in nodes)
    if actual_statuses != expectation.statuses:
        failures.append(f"status mismatch: expected {expectation.statuses}, got {actual_statuses}")

    actual_halts = tuple(node["halted_round"] for node in nodes)
    if actual_halts != expectation.halted_rounds:
        failures.append(f"halted_round mismatch: expected {expectation.halted_rounds}, got {actual_halts}")

    expected_commits = expectation.committed_rounds
    actual_commits = tuple(
        tuple(entry["round"] for entry in node["committed_rounds"])
        for node in nodes
    )

    for node_id, (expected, actual, status, halted_round) in enumerate(
        zip(expected_commits, actual_commits, actual_statuses, actual_halts, strict=True)
    ):
        if actual[: len(expected)] != expected:
            failures.append(
                f"commit prefix mismatch for node {node_id}: expected prefix {expected}, got {actual}"
            )
            continue

        if list(actual) != list(range(len(actual))):
            failures.append(
                f"non-contiguous commit prefix for node {node_id}: got {actual}"
            )
            continue

        if status != "RUNNING" or halted_round is not None:
            if actual != expected:
                failures.append(
                    f"unexpected extra commits for stopped node {node_id}: expected {expected}, got {actual}"
                )

    return failures, "RELAXED (custom round budget exceeds the built-in scenario horizon)"


def parse_args() -> argparse.Namespace:
    def duration_arg(text: str) -> int:
        try:
            return parse_duration_ns(text)
        except ValueError as exc:
            raise argparse.ArgumentTypeError(str(exc)) from exc

    parser = argparse.ArgumentParser(description="Reference simulator for the protocol prototype.")
    parser.add_argument(
        "scenario",
        choices=sorted(SCENARIOS),
        help="Built-in fault scenario to execute.",
    )
    parser.add_argument(
        "--rounds",
        "--epochs",
        dest="rounds",
        type=int,
        default=None,
        help="Number of rounds to simulate. `--epochs` remains as a compatibility alias.",
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
        help="Emit the simulation result as JSON.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check the scenario result against its built-in expectation.",
    )
    parser.add_argument(
        "--round-length",
        "--epoch-length",
        dest="round_length",
        type=duration_arg,
        default=parse_duration_ns("4us"),
        help="Synchronous round length (for example: 4000ns, 4us, 0.5us). `--epoch-length` remains as a compatibility alias.",
    )
    parser.add_argument(
        "--halt-report-delay",
        type=duration_arg,
        default=parse_duration_ns("10us"),
        help="Delay from local halt/crash to control-plane visibility.",
    )
    parser.add_argument(
        "--cp-collection-delay",
        type=duration_arg,
        default=parse_duration_ns("20us"),
        help="Time for the control plane to collect enough state to act.",
    )
    parser.add_argument(
        "--cp-decision-delay",
        type=duration_arg,
        default=parse_duration_ns("15us"),
        help="Time for the control plane to select a recovery prefix and next view.",
    )
    parser.add_argument(
        "--repair-delay",
        type=duration_arg,
        default=parse_duration_ns("50us"),
        help="Time to repair a node to the selected recovery prefix.",
    )
    parser.add_argument(
        "--install-delay",
        type=duration_arg,
        default=parse_duration_ns("20us"),
        help="Time to install a new membership epoch and run_id.",
    )
    parser.add_argument(
        "--reentry-delay",
        type=duration_arg,
        default=parse_duration_ns("10us"),
        help="Delay between config installation and data-plane restart authorization.",
    )
    parser.add_argument(
        "--app-delivery-delay",
        type=duration_arg,
        default=parse_duration_ns("5us"),
        help="Delay from data-plane commit to application delivery.",
    )
    parser.add_argument(
        "--perf-summary",
        action="store_true",
        help="Print a compact performance summary derived from the timing model.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    spec = SCENARIOS[args.scenario]
    run = ClusterRun(
        node_count=args.nodes,
        rounds=spec.rounds if args.rounds is None else args.rounds,
        network_fault_model=spec.network_fault_model,
        node_fault_model=spec.node_fault_model,
        timing=SimulationTiming(
            round_length_ns=args.round_length,
            halt_report_delay_ns=args.halt_report_delay,
            cp_collection_delay_ns=args.cp_collection_delay,
            cp_decision_delay_ns=args.cp_decision_delay,
            repair_delay_ns=args.repair_delay,
            install_delay_ns=args.install_delay,
            reentry_delay_ns=args.reentry_delay,
            app_delivery_delay_ns=args.app_delivery_delay,
        ),
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
    expectation_mode_note: str | None = None
    if args.check:
        failures, expectation_mode_note = evaluate_expectation_for_round_budget(
            result,
            spec.expectation,
            run_rounds=run.rounds,
            reference_rounds=spec.rounds,
        )
        if failures:
            print("\nExpectation check: FAIL")
            for failure in failures:
                print(f"- {failure}")
        else:
            print("\nExpectation check: PASS")
            if expectation_mode_note is not None:
                print(f"  {expectation_mode_note}")

    if args.perf_summary:
        print()
        print(performance_summary_text(result))

    return 1 if failures else 0
