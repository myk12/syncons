#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from sim.protocol.types import JsonDict, SimulationTiming, format_duration_ns, parse_duration_ns
from sim.runtime.cluster import ClusterRun
from sim.runtime.metrics import InMemoryMetricsCollector, RoundSummary
from sim.scenarios.builtin import SCENARIOS
from sim.scenarios.faults import (
    all_nodes_active,
    network_asymmetric_loss_at,
    network_bridge_partition_at,
    network_perfect,
    staggered_recoverable_crashes,
)


DEFAULT_SCENARIOS = ("node_crash", "asymmetric_loss", "bridge_partition")
DEFAULT_NODE_COUNT = 5
DEFAULT_ROUNDS = 120
DEFAULT_WINDOW = "24us"
DEFAULT_STEP = "4us"
DEFAULT_FAULT_FRACTION = 0.30

DEFAULT_HALT_REPORT_DELAY = "8us"
DEFAULT_CP_COLLECTION_DELAY = "24us"
DEFAULT_CP_DECISION_DELAY = "12us"
DEFAULT_REPAIR_DELAY = "64us"
DEFAULT_INSTALL_DELAY = "24us"
DEFAULT_REENTRY_DELAY = "16us"
DEFAULT_APP_DELIVERY_DELAY = "5us"
DEFAULT_ROUND_LENGTH = "4us"


def write_csv(path: Path, rows: list[JsonDict]) -> None:
    if not rows:
        raise ValueError(f"no rows to write for {path}")
    fieldnames = list(rows[0].keys())
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def rolling_rows(
    *,
    scenario: str,
    round_summaries: list[RoundSummary],
    round_length_ns: int,
    window_ns: int,
    step_ns: int,
) -> list[JsonDict]:
    rows: list[JsonDict] = []
    if not round_summaries:
        return rows

    start_ns = 0
    simulated_time_ns = int(round_summaries[-1].end_time_ns)
    end_ns = simulated_time_ns + window_ns
    left = 0
    right = 0
    round_end_times = [int(summary.end_time_ns) for summary in round_summaries]
    round_commit_counts = [int(summary.committed_txns) for summary in round_summaries]
    raw_commits_by_end_time = {
        int(summary.end_time_ns): int(summary.committed_txns)
        for summary in round_summaries
    }
    commits_in_window = 0

    for sample_ns in range(start_ns, end_ns + 1, step_ns):
        window_start = max(0, sample_ns - window_ns)
        while left < len(round_summaries) and round_end_times[left] <= window_start:
            commits_in_window -= round_commit_counts[left]
            left += 1
        while right < len(round_summaries) and round_end_times[right] <= sample_ns:
            commits_in_window += round_commit_counts[right]
            right += 1
        throughput_ops = commits_in_window / (window_ns / 1_000_000_000)
        rows.append(
            {
                "scenario": scenario,
                "time_ms": round(sample_ns / 1_000_000, 3),
                "throughput_mops": round(throughput_ops / 1_000_000, 6),
                "raw_committed_txns": raw_commits_by_end_time.get(sample_ns, 0),
                "commits_in_window": commits_in_window,
                "window_ns": window_ns,
                "step_ns": step_ns,
                "round_length_ns": round_length_ns,
            }
        )
    return rows


def cp_action_time_ns(result: JsonDict, action_name: str) -> int | None:
    runtime = result.get("control_plane_runtime") or {}
    applied = runtime.get("applied_actions") or []
    for action in applied:
        if action.get("action") == action_name:
            return int(action["time_ns"])
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export rolling recovery throughput timelines.")
    parser.add_argument(
        "--scenarios",
        default=",".join(DEFAULT_SCENARIOS),
        help="Comma-separated builtin scenarios to export.",
    )
    parser.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS)
    parser.add_argument("--node-count", type=int, default=DEFAULT_NODE_COUNT)
    parser.add_argument(
        "--fault-round",
        type=int,
        default=None,
        help="Round at which the primary fault is injected. Defaults to roughly 30%% into the run.",
    )
    parser.add_argument("--window", default=DEFAULT_WINDOW, help="Rolling throughput window.")
    parser.add_argument("--step", default=DEFAULT_STEP, help="Sampling step for the timeline.")
    parser.add_argument("--round-length", default=DEFAULT_ROUND_LENGTH)
    parser.add_argument("--halt-report-delay", default=DEFAULT_HALT_REPORT_DELAY)
    parser.add_argument("--cp-collection-delay", default=DEFAULT_CP_COLLECTION_DELAY)
    parser.add_argument("--cp-decision-delay", default=DEFAULT_CP_DECISION_DELAY)
    parser.add_argument("--repair-delay", default=DEFAULT_REPAIR_DELAY)
    parser.add_argument("--install-delay", default=DEFAULT_INSTALL_DELAY)
    parser.add_argument("--reentry-delay", default=DEFAULT_REENTRY_DELAY)
    parser.add_argument("--app-delivery-delay", default=DEFAULT_APP_DELIVERY_DELAY)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("eval/results/recovery_timeline/recovery_timeline.csv"),
        help="Output CSV path.",
    )
    return parser.parse_args()


def figure_fault_round(total_rounds: int, explicit_fault_round: int | None) -> int:
    if explicit_fault_round is not None:
        return explicit_fault_round
    return max(2, int(total_rounds * DEFAULT_FAULT_FRACTION))


def figure_fault_models(
    scenario: str,
    *,
    total_rounds: int,
    fault_round: int | None,
) -> tuple:
    injection_round = figure_fault_round(total_rounds, fault_round)

    if scenario == "node_crash":
        crash_rounds = (injection_round, injection_round + 4)
        return (
            network_perfect,
            staggered_recoverable_crashes(
                ((4, crash_rounds[0]), (3, crash_rounds[1]))
            ),
            crash_rounds,
        )
    if scenario == "asymmetric_loss":
        return network_asymmetric_loss_at(injection_round), all_nodes_active, (injection_round,)
    if scenario == "bridge_partition":
        return network_bridge_partition_at(injection_round), all_nodes_active, (injection_round,)
    if scenario in SCENARIOS:
        spec = SCENARIOS[scenario]
        return spec.network_fault_model, spec.node_fault_model, (injection_round,)
    raise ValueError(f"unknown scenario: {scenario}")


def main() -> int:
    args = parse_args()
    scenarios = [item.strip() for item in args.scenarios.split(",") if item.strip()]

    timing = SimulationTiming(
        round_length_ns=parse_duration_ns(args.round_length),
        halt_report_delay_ns=parse_duration_ns(args.halt_report_delay),
        cp_collection_delay_ns=parse_duration_ns(args.cp_collection_delay),
        cp_decision_delay_ns=parse_duration_ns(args.cp_decision_delay),
        repair_delay_ns=parse_duration_ns(args.repair_delay),
        install_delay_ns=parse_duration_ns(args.install_delay),
        reentry_delay_ns=parse_duration_ns(args.reentry_delay),
        app_delivery_delay_ns=parse_duration_ns(args.app_delivery_delay),
    )
    window_ns = parse_duration_ns(args.window)
    step_ns = parse_duration_ns(args.step)

    rows: list[JsonDict] = []
    for scenario in scenarios:
        network_fault_model, node_fault_model, injection_rounds = figure_fault_models(
            scenario,
            total_rounds=args.rounds,
            fault_round=args.fault_round,
        )
        collector = InMemoryMetricsCollector()
        run = ClusterRun(
            node_count=args.node_count,
            rounds=args.rounds,
            network_fault_model=network_fault_model,
            node_fault_model=node_fault_model,
            timing=timing,
            metrics_sink=collector,
        )
        result = run.run()
        scenario_rows = rolling_rows(
            scenario=scenario,
            round_summaries=collector.rounds,
            round_length_ns=timing.round_length_ns,
            window_ns=window_ns,
            step_ns=step_ns,
        )
        recovery_time_ns = cp_action_time_ns(result, "activate_online_rejoin")
        for row in scenario_rows:
            row["fault_round"] = injection_rounds[0]
            row["fault_rounds"] = ",".join(str(round_id) for round_id in injection_rounds)
            row["node_count"] = args.node_count
            if recovery_time_ns is not None:
                row["recovery_time_ms"] = round(recovery_time_ns / 1_000_000, 3)
        rows.extend(scenario_rows)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_csv(args.out, rows)

    print(
        "[recovery-timeline] wrote "
        + str(args.out)
        + f" for scenarios={','.join(scenarios)} "
        + f"window={format_duration_ns(window_ns)} step={format_duration_ns(step_ns)} "
        + f"fault_round={figure_fault_round(args.rounds, args.fault_round)}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
