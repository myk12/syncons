#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from sim.protocol.types import JsonDict, SimulationTiming, format_duration_ns, parse_duration_ns
from sim.runtime.cluster import ClusterRun
from sim.scenarios.builtin import SCENARIOS


DEFAULT_STEADY_VALUES = ["4us", "6us", "8us", "10us", "12us"]
DEFAULT_RECOVERY_VALUES = ["500us", "1ms", "2ms", "4ms"]

DEFAULT_TIMING_PROFILE = "paper-baseline"
DEFAULT_STEADY_ROUNDS = 2000
DEFAULT_RECOVERY_ROUNDS = 1500
DEFAULT_STEADY_NODE_COUNTS = "3,5"
DEFAULT_HALT_REPORT_DELAY = "100us"
DEFAULT_CP_COLLECTION_DELAY = "1ms"
DEFAULT_CP_DECISION_DELAY = "500us"
DEFAULT_REENTRY_DELAY = "250us"
DEFAULT_APP_DELIVERY_DELAY = "5us"
DEFAULT_BASE_ROUND_LENGTH = "4us"
DEFAULT_BASE_REPAIR_DELAY = "2ms"
DEFAULT_BASE_INSTALL_DELAY = "1ms"
DEFAULT_SWEEPS = "all"


def parse_values(raw: str) -> list[int]:
    return [parse_duration_ns(value) for value in raw.split(",") if value.strip()]


def parse_int_values(raw: str) -> list[int]:
    return [int(value.strip()) for value in raw.split(",") if value.strip()]


def write_csv(path: Path, rows: list[JsonDict]) -> None:
    if not rows:
        raise ValueError(f"no rows to write for {path}")
    fieldnames: list[str] = []
    for row in rows:
        for key in row.keys():
            if key not in fieldnames:
                fieldnames.append(key)
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_manifest(path: Path, manifest: JsonDict) -> None:
    path.write_text(json.dumps(manifest, indent=2) + "\n")


def cp_metric_ns(result: JsonDict, action_name: str) -> int | None:
    runtime = result.get("control_plane_runtime") or {}
    for item in runtime.get("applied_actions", []):
        if item["action"] == action_name:
            return int(item["time_ns"])
    return None


def compute_metrics(result: JsonDict) -> JsonDict:
    node_count = int(result["node_count"])
    simulated_time_ns = int(result["simulated_time_ns"])
    total_commits = sum(len(node["committed_rounds"]) for node in result["nodes"])
    max_frontier = max(
        (-1 if not node["committed_rounds"] else int(node["committed_rounds"][-1]["round"]))
        for node in result["nodes"]
    )
    cluster_commit_rounds = max_frontier + 1 if max_frontier >= 0 else 0
    cluster_commit_rate = (
        cluster_commit_rounds / (simulated_time_ns / 1_000_000_000)
        if simulated_time_ns > 0
        else 0.0
    )
    per_node_commit_rate = (
        total_commits / node_count / (simulated_time_ns / 1_000_000_000)
        if simulated_time_ns > 0 and node_count > 0
        else 0.0
    )

    metrics: JsonDict = {
        "cluster_committed_rounds": cluster_commit_rounds,
        "cluster_commit_rate_eps": round(cluster_commit_rate, 2),
        "mean_per_node_commit_rate_eps": round(per_node_commit_rate, 2),
        "control_plane_events": len(result.get("control_plane_events", [])),
    }

    app_delivery_latencies = [
        int(entry["app_delivery_time_ns"]) - int(entry["commit_time_ns"])
        for node in result["nodes"]
        for entry in node["committed_rounds"]
        if "commit_time_ns" in entry and "app_delivery_time_ns" in entry
    ]
    if app_delivery_latencies:
        metrics["commit_to_application_ns"] = sum(app_delivery_latencies) // len(app_delivery_latencies)
        app_deliveries = sum(
            1
            for node in result["nodes"]
            for entry in node["committed_rounds"]
            if "app_delivery_time_ns" in entry
        )
        app_delivery_rate = (
            app_deliveries / node_count / (simulated_time_ns / 1_000_000_000)
            if simulated_time_ns > 0 and node_count > 0
            else 0.0
        )
        metrics["mean_per_node_application_rate_eps"] = round(app_delivery_rate, 2)

    control_events = result.get("control_plane_events", [])
    interruptions = [
        event for event in control_events if event.get("kind") in {"NodeCrashed", "NodeHalted"}
    ]
    if interruptions:
        first_available_ns = min(int(event["available_at_ns"]) for event in interruptions)
        metrics["interruption_count"] = len(interruptions)
        metrics["interruption_kind"] = "|".join(sorted({str(event["kind"]) for event in interruptions}))
        mark_recovering = cp_metric_ns(result, "mark_recovering")
        prepare_at = cp_metric_ns(result, "prepare_online_rejoin")
        commit_at = cp_metric_ns(result, "commit_online_rejoin")
        activate_at = cp_metric_ns(result, "activate_online_rejoin")
        if mark_recovering is not None:
            metrics["interruption_to_mark_recovering_ns"] = mark_recovering - first_available_ns
        if mark_recovering is not None and prepare_at is not None:
            metrics["mark_recovering_to_prepare_ns"] = prepare_at - mark_recovering
        if prepare_at is not None and commit_at is not None:
            metrics["prepare_to_commit_ns"] = commit_at - prepare_at
        if commit_at is not None and activate_at is not None:
            metrics["commit_to_activate_ns"] = activate_at - commit_at
        if activate_at is not None:
            interrupted_node_ids = {int(event["node_id"]) for event in interruptions}
            rejoin_commit_times = [
                int(entry["commit_time_ns"])
                for node in result["nodes"]
                if int(node["node_id"]) in interrupted_node_ids
                for entry in node["committed_rounds"]
                if "commit_time_ns" in entry and int(entry["commit_time_ns"]) >= activate_at
            ]
            if rejoin_commit_times:
                metrics["activate_to_first_rejoin_commit_ns"] = (
                    min(rejoin_commit_times) - activate_at
                )

    return metrics


def run_scenario(
    scenario_name: str,
    *,
    rounds: int,
    timing: SimulationTiming,
    node_count: int = 3,
) -> JsonDict:
    spec = SCENARIOS[scenario_name]
    run = ClusterRun(
        node_count=node_count,
        rounds=rounds,
        network_fault_model=spec.network_fault_model,
        node_fault_model=spec.node_fault_model,
        timing=timing,
    )
    result = run.run()
    result["scenario"] = scenario_name
    result["description"] = spec.description
    return result


def build_row(
    *,
    sweep_name: str,
    sweep_parameter: str,
    sweep_value_ns: int,
    timing: SimulationTiming,
    result: JsonDict,
) -> JsonDict:
    row = {
        "sweep": sweep_name,
        "scenario": result["scenario"],
        "node_count": int(result["node_count"]),
        "rounds": int(result["rounds"]),
        "round_length_ns": timing.round_length_ns,
        "round_length": format_duration_ns(timing.round_length_ns),
        "halt_report_delay_ns": timing.halt_report_delay_ns,
        "cp_collection_delay_ns": timing.cp_collection_delay_ns,
        "cp_decision_delay_ns": timing.cp_decision_delay_ns,
        "repair_delay_ns": timing.repair_delay_ns,
        "install_delay_ns": timing.install_delay_ns,
        "reentry_delay_ns": timing.reentry_delay_ns,
        "app_delivery_delay_ns": timing.app_delivery_delay_ns,
        "sweep_parameter": sweep_parameter,
        "sweep_value_ns": sweep_value_ns,
        "sweep_value": format_duration_ns(sweep_value_ns),
        "simulated_time_ns": int(result["simulated_time_ns"]),
        "statuses": "|".join(node["status"] for node in result["nodes"]),
    }
    row.update(compute_metrics(result))
    return row


def announce_sweep(name: str, values: list[int]) -> None:
    pretty_values = ", ".join(format_duration_ns(value) for value in values)
    print(f"[start] {name}: {pretty_values}", flush=True)


def finish_sweep(path: Path, rows: list[JsonDict]) -> None:
    write_csv(path, rows)
    print(f"[done] wrote {path}", flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate CSV sweeps for SSR protocol timing studies.")
    parser.add_argument("--out", type=Path, default=Path("eval/results/protocol_sweeps"))
    parser.add_argument(
        "--timing-profile",
        choices=(DEFAULT_TIMING_PROFILE,),
        default=DEFAULT_TIMING_PROFILE,
        help="Named timing profile to use for protocol evaluation sweeps.",
    )
    parser.add_argument(
        "--steady-rounds",
        "--steady-epochs",
        dest="steady_rounds",
        type=int,
        default=DEFAULT_STEADY_ROUNDS,
    )
    parser.add_argument(
        "--recovery-rounds",
        "--recovery-epochs",
        dest="recovery_rounds",
        type=int,
        default=DEFAULT_RECOVERY_ROUNDS,
    )
    parser.add_argument(
        "--steady-values",
        default=",".join(DEFAULT_STEADY_VALUES),
        help="Comma-separated round lengths for the steady-state sweep.",
    )
    parser.add_argument(
        "--steady-node-counts",
        default=DEFAULT_STEADY_NODE_COUNTS,
        help="Comma-separated node counts for the steady-state sweep.",
    )
    parser.add_argument(
        "--recovery-values",
        default=",".join(DEFAULT_RECOVERY_VALUES),
        help="Comma-separated duration values for recovery-delay sweeps.",
    )
    parser.add_argument("--halt-report-delay", default=DEFAULT_HALT_REPORT_DELAY)
    parser.add_argument("--cp-collection-delay", default=DEFAULT_CP_COLLECTION_DELAY)
    parser.add_argument("--cp-decision-delay", default=DEFAULT_CP_DECISION_DELAY)
    parser.add_argument("--reentry-delay", default=DEFAULT_REENTRY_DELAY)
    parser.add_argument("--app-delivery-delay", default=DEFAULT_APP_DELIVERY_DELAY)
    parser.add_argument(
        "--base-round-length",
        "--base-epoch-length",
        dest="base_round_length",
        default=DEFAULT_BASE_ROUND_LENGTH,
    )
    parser.add_argument("--base-repair-delay", default=DEFAULT_BASE_REPAIR_DELAY)
    parser.add_argument("--base-install-delay", default=DEFAULT_BASE_INSTALL_DELAY)
    parser.add_argument(
        "--sweeps",
        choices=("all", "steady", "recovery"),
        default=DEFAULT_SWEEPS,
        help=(
            "Which sweep families to run: `steady` runs only perfect steady-state "
            "round-length sweeps, `recovery` runs only recovery-delay sweeps, and "
            "`all` runs both."
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    steady_values = parse_values(args.steady_values)
    steady_node_counts = parse_int_values(args.steady_node_counts)
    recovery_values = parse_values(args.recovery_values)

    base_round_length_ns = parse_duration_ns(args.base_round_length)
    halt_report_delay_ns = parse_duration_ns(args.halt_report_delay)
    cp_collection_delay_ns = parse_duration_ns(args.cp_collection_delay)
    cp_decision_delay_ns = parse_duration_ns(args.cp_decision_delay)
    reentry_delay_ns = parse_duration_ns(args.reentry_delay)
    app_delivery_delay_ns = parse_duration_ns(args.app_delivery_delay)
    base_repair_delay_ns = parse_duration_ns(args.base_repair_delay)
    base_install_delay_ns = parse_duration_ns(args.base_install_delay)

    steady_path = args.out / "steady_state_throughput.csv"
    repair_path = args.out / "online_rejoin_repair_delay.csv"
    halt_repair_path = args.out / "asymmetric_loss_repair_delay.csv"
    install_path = args.out / "online_rejoin_install_delay.csv"
    halt_install_path = args.out / "asymmetric_loss_install_delay.csv"

    selected_files: list[str] = []
    if args.sweeps in {"all", "steady"}:
        selected_files.append(str(steady_path))
    if args.sweeps in {"all", "recovery"}:
        selected_files.extend(
            [
                str(repair_path),
                str(halt_repair_path),
                str(install_path),
                str(halt_install_path),
            ]
        )

    manifest = {
        "timing_profile": args.timing_profile,
        "sweeps": args.sweeps,
        "files": selected_files,
        "steady_rounds": args.steady_rounds,
        "recovery_rounds": args.recovery_rounds,
        "steady_values_ns": steady_values,
        "steady_node_counts": steady_node_counts,
        "recovery_values_ns": recovery_values,
        "base_round_length_ns": base_round_length_ns,
        "base_repair_delay_ns": base_repair_delay_ns,
        "base_install_delay_ns": base_install_delay_ns,
        "halt_report_delay_ns": halt_report_delay_ns,
        "cp_collection_delay_ns": cp_collection_delay_ns,
        "cp_decision_delay_ns": cp_decision_delay_ns,
        "reentry_delay_ns": reentry_delay_ns,
        "app_delivery_delay_ns": app_delivery_delay_ns,
    }
    manifest_path = args.out / "manifest.json"
    write_manifest(manifest_path, manifest)

    if args.sweeps in {"all", "steady"}:
        steady_rows: list[JsonDict] = []
        announce_sweep(
            "steady_state_throughput",
            steady_values,
        )
        for node_count in steady_node_counts:
            for round_length_ns in steady_values:
                timing = SimulationTiming(
                    round_length_ns=round_length_ns,
                    halt_report_delay_ns=halt_report_delay_ns,
                    cp_collection_delay_ns=cp_collection_delay_ns,
                    cp_decision_delay_ns=cp_decision_delay_ns,
                    repair_delay_ns=base_repair_delay_ns,
                    install_delay_ns=base_install_delay_ns,
                    reentry_delay_ns=reentry_delay_ns,
                    app_delivery_delay_ns=app_delivery_delay_ns,
                )
                result = run_scenario(
                    "perfect",
                    rounds=args.steady_rounds,
                    timing=timing,
                    node_count=node_count,
                )
                steady_rows.append(
                    build_row(
                        sweep_name="steady_state_throughput",
                        sweep_parameter="round_length_ns",
                        sweep_value_ns=round_length_ns,
                        timing=timing,
                        result=result,
                    )
                )
        finish_sweep(steady_path, steady_rows)

    if args.sweeps in {"all", "recovery"}:
        repair_rows: list[JsonDict] = []
        announce_sweep("online_rejoin_repair_delay", recovery_values)
        for repair_delay_ns in recovery_values:
            timing = SimulationTiming(
                round_length_ns=base_round_length_ns,
                halt_report_delay_ns=halt_report_delay_ns,
                cp_collection_delay_ns=cp_collection_delay_ns,
                cp_decision_delay_ns=cp_decision_delay_ns,
                repair_delay_ns=repair_delay_ns,
                install_delay_ns=base_install_delay_ns,
                reentry_delay_ns=reentry_delay_ns,
                app_delivery_delay_ns=app_delivery_delay_ns,
            )
            result = run_scenario(
                "online_rejoin",
                rounds=args.recovery_rounds,
                timing=timing,
            )
            repair_rows.append(
                build_row(
                    sweep_name="online_rejoin_repair_delay",
                    sweep_parameter="repair_delay_ns",
                    sweep_value_ns=repair_delay_ns,
                    timing=timing,
                    result=result,
                )
            )
        finish_sweep(repair_path, repair_rows)

        halt_repair_rows: list[JsonDict] = []
        announce_sweep("asymmetric_loss_repair_delay", recovery_values)
        for repair_delay_ns in recovery_values:
            timing = SimulationTiming(
                round_length_ns=base_round_length_ns,
                halt_report_delay_ns=halt_report_delay_ns,
                cp_collection_delay_ns=cp_collection_delay_ns,
                cp_decision_delay_ns=cp_decision_delay_ns,
                repair_delay_ns=repair_delay_ns,
                install_delay_ns=base_install_delay_ns,
                reentry_delay_ns=reentry_delay_ns,
                app_delivery_delay_ns=app_delivery_delay_ns,
            )
            result = run_scenario(
                "asymmetric_loss",
                rounds=args.recovery_rounds,
                timing=timing,
            )
            halt_repair_rows.append(
                build_row(
                    sweep_name="asymmetric_loss_repair_delay",
                    sweep_parameter="repair_delay_ns",
                    sweep_value_ns=repair_delay_ns,
                    timing=timing,
                    result=result,
                )
            )
        finish_sweep(halt_repair_path, halt_repair_rows)

        install_rows: list[JsonDict] = []
        announce_sweep("online_rejoin_install_delay", recovery_values)
        for install_delay_ns in recovery_values:
            timing = SimulationTiming(
                round_length_ns=base_round_length_ns,
                halt_report_delay_ns=halt_report_delay_ns,
                cp_collection_delay_ns=cp_collection_delay_ns,
                cp_decision_delay_ns=cp_decision_delay_ns,
                repair_delay_ns=base_repair_delay_ns,
                install_delay_ns=install_delay_ns,
                reentry_delay_ns=reentry_delay_ns,
                app_delivery_delay_ns=app_delivery_delay_ns,
            )
            result = run_scenario(
                "online_rejoin",
                rounds=args.recovery_rounds,
                timing=timing,
            )
            install_rows.append(
                build_row(
                    sweep_name="online_rejoin_install_delay",
                    sweep_parameter="install_delay_ns",
                    sweep_value_ns=install_delay_ns,
                    timing=timing,
                    result=result,
                )
            )
        finish_sweep(install_path, install_rows)

        halt_install_rows: list[JsonDict] = []
        announce_sweep("asymmetric_loss_install_delay", recovery_values)
        for install_delay_ns in recovery_values:
            timing = SimulationTiming(
                round_length_ns=base_round_length_ns,
                halt_report_delay_ns=halt_report_delay_ns,
                cp_collection_delay_ns=cp_collection_delay_ns,
                cp_decision_delay_ns=cp_decision_delay_ns,
                repair_delay_ns=base_repair_delay_ns,
                install_delay_ns=install_delay_ns,
                reentry_delay_ns=reentry_delay_ns,
                app_delivery_delay_ns=app_delivery_delay_ns,
            )
            result = run_scenario(
                "asymmetric_loss",
                rounds=args.recovery_rounds,
                timing=timing,
            )
            halt_install_rows.append(
                build_row(
                    sweep_name="asymmetric_loss_install_delay",
                    sweep_parameter="install_delay_ns",
                    sweep_value_ns=install_delay_ns,
                    timing=timing,
                    result=result,
                )
            )
        finish_sweep(halt_install_path, halt_install_rows)

    print(f"[done] wrote {manifest_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
