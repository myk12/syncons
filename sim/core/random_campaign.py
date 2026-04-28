from __future__ import annotations

import argparse
import csv
import json
import random
import sys
from dataclasses import dataclass, asdict
from typing import Any

from .cluster import ClusterRun
from .faults import control_plane_all_active
from .types import Delivery, NetworkFaultModel, NodeFaultModel, Packet


@dataclass(frozen=True)
class RandomFaultConfig:
    node_count: int = 3
    epochs: int = 8
    trials: int = 100
    seed: int = 20260425
    packet_loss: float = 0.0
    packet_delay: float = 0.0
    ack_corruption: float = 0.0
    duplicate: float = 0.0
    node_crash: float = 0.0


def committed_value(entry: dict[str, Any]) -> tuple[Any, Any, tuple[tuple[Any, Any], ...]]:
    return (
        entry["membership_epoch"],
        entry["bitmap"],
        tuple(sorted(entry["proposals"].items())),
    )


def safety_violations(result: dict[str, Any]) -> list[str]:
    violations: list[str] = []
    committed_by_epoch: dict[int, tuple[Any, Any, tuple[tuple[Any, Any], ...]]] = {}

    for node in result["nodes"]:
        epochs = [entry["epoch"] for entry in node["committed_epochs"]]
        if epochs != list(range(len(epochs))):
            violations.append(f"node {node['node_id']} committed non-prefix epochs {epochs}")

        for entry in node["committed_epochs"]:
            epoch = int(entry["epoch"])
            value = committed_value(entry)
            previous = committed_by_epoch.setdefault(epoch, value)
            if value != previous:
                violations.append(
                    f"conflicting commit for epoch {epoch}: "
                    f"node {node['node_id']} committed {value}, previous {previous}"
                )

    return violations


def _random_network_fault_model(
    rng: random.Random,
    config: RandomFaultConfig,
) -> NetworkFaultModel:
    def model(packet: Packet, dst: int) -> Delivery:
        roll = rng.random()
        if roll < config.packet_loss:
            return Delivery(deliver_epoch=None, reason="random packet loss")

        roll -= config.packet_loss
        if roll < config.packet_delay:
            return Delivery(
                deliver_epoch=packet.epoch_id + 1,
                reason="random one-epoch delay",
            )

        ack_override = None
        if rng.random() < config.ack_corruption:
            ack_override = rng.randrange(1 << config.node_count)

        extra_deliver_epochs = ()
        if rng.random() < config.duplicate:
            extra_deliver_epochs = (packet.epoch_id,)

        return Delivery(
            deliver_epoch=packet.epoch_id,
            reason="random same-epoch delivery",
            ack_override=ack_override,
            extra_deliver_epochs=extra_deliver_epochs,
        )

    return model


def _random_node_fault_model(
    rng: random.Random,
    config: RandomFaultConfig,
) -> NodeFaultModel:
    crash_epochs: dict[int, int] = {}
    for node_id in range(config.node_count):
        for epoch in range(1, config.epochs):
            if rng.random() < config.node_crash:
                crash_epochs[node_id] = epoch
                break

    def model(node_id: int, epoch_id: int) -> bool:
        crash_epoch = crash_epochs.get(node_id)
        return crash_epoch is None or epoch_id < crash_epoch

    return model


def run_random_trial(config: RandomFaultConfig, trial_seed: int) -> dict[str, Any]:
    rng = random.Random(trial_seed)
    run = ClusterRun(
        node_count=config.node_count,
        epochs=config.epochs,
        network_fault_model=_random_network_fault_model(rng, config),
        node_fault_model=_random_node_fault_model(rng, config),
        control_plane_model=control_plane_all_active,
    )
    return run.run()


def summarize_trial(result: dict[str, Any]) -> dict[str, Any]:
    statuses = [node["status"] for node in result["nodes"]]
    committed_counts = [len(node["committed_epochs"]) for node in result["nodes"]]
    halt_epochs = [
        node["halted_epoch"]
        for node in result["nodes"]
        if node["status"] == "HALTED" and node["halted_epoch"] is not None
    ]
    crash_epochs = [
        node["halted_epoch"]
        for node in result["nodes"]
        if node["status"] == "CRASHED" and node["halted_epoch"] is not None
    ]

    return {
        "statuses": statuses,
        "committed_counts": committed_counts,
        "max_committed": max(committed_counts, default=0),
        "halted_nodes": statuses.count("HALTED"),
        "crashed_nodes": statuses.count("CRASHED"),
        "first_halt_epoch": min(halt_epochs) if halt_epochs else None,
        "first_crash_epoch": min(crash_epochs) if crash_epochs else None,
        "safety_violations": safety_violations(result),
    }


def run_campaign(config: RandomFaultConfig) -> dict[str, Any]:
    seed_rng = random.Random(config.seed)
    trials = []

    for trial_id in range(config.trials):
        trial_seed = seed_rng.randrange(2**63)
        result = run_random_trial(config, trial_seed)
        summary = summarize_trial(result)
        trials.append(
            {
                "trial": trial_id,
                "seed": trial_seed,
                **summary,
            }
        )

    violation_count = sum(1 for trial in trials if trial["safety_violations"])
    halted_runs = sum(1 for trial in trials if trial["halted_nodes"] > 0)
    crashed_runs = sum(1 for trial in trials if trial["crashed_nodes"] > 0)
    all_running_runs = sum(
        1
        for trial in trials
        if trial["halted_nodes"] == 0 and trial["crashed_nodes"] == 0
    )
    total_committed = sum(sum(trial["committed_counts"]) for trial in trials)
    total_node_runs = config.trials * config.node_count

    return {
        "config": asdict(config),
        "summary": {
            "trials": config.trials,
            "safety_violation_runs": violation_count,
            "halted_runs": halted_runs,
            "crashed_runs": crashed_runs,
            "all_running_runs": all_running_runs,
            "avg_committed_epochs_per_node": total_committed / total_node_runs
            if total_node_runs
            else 0.0,
        },
        "trials": trials,
    }


def sweep_campaigns(
    base_config: RandomFaultConfig,
    *,
    parameter: str,
    values: list[float],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []

    for value in values:
        config = RandomFaultConfig(
            **{
                **asdict(base_config),
                parameter: value,
            }
        )
        report = run_campaign(config)
        summary = report["summary"]
        rows.append(
            {
                "parameter": parameter,
                "value": value,
                "node_count": config.node_count,
                "epochs": config.epochs,
                "trials": config.trials,
                "seed": config.seed,
                "packet_loss": config.packet_loss,
                "packet_delay": config.packet_delay,
                "ack_corruption": config.ack_corruption,
                "duplicate": config.duplicate,
                "node_crash": config.node_crash,
                "safety_violation_runs": summary["safety_violation_runs"],
                "halted_runs": summary["halted_runs"],
                "crashed_runs": summary["crashed_runs"],
                "all_running_runs": summary["all_running_runs"],
                "halt_rate": summary["halted_runs"] / config.trials if config.trials else 0.0,
                "all_running_rate": summary["all_running_runs"] / config.trials if config.trials else 0.0,
                "avg_committed_epochs_per_node": summary["avg_committed_epochs_per_node"],
            }
        )

    return rows


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run randomized SynCons fault campaigns.")
    parser.add_argument("--nodes", type=int, default=3)
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--trials", type=int, default=100)
    parser.add_argument("--seed", type=int, default=20260425)
    parser.add_argument("--packet-loss", type=float, default=0.0)
    parser.add_argument("--packet-delay", type=float, default=0.0)
    parser.add_argument("--ack-corruption", type=float, default=0.0)
    parser.add_argument("--duplicate", type=float, default=0.0)
    parser.add_argument("--node-crash", type=float, default=0.0)
    parser.add_argument(
        "--sweep",
        choices=[
            "packet_loss",
            "packet_delay",
            "ack_corruption",
            "duplicate",
            "node_crash",
        ],
        default=None,
        help="Sweep one fault parameter and emit CSV rows.",
    )
    parser.add_argument(
        "--values",
        default="0,0.001,0.005,0.01,0.02,0.05",
        help="Comma-separated sweep values used with --sweep.",
    )
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def text_summary(report: dict[str, Any]) -> str:
    config = report["config"]
    summary = report["summary"]
    return "\n".join(
        [
            "Random SynCons fault campaign",
            f"nodes={config['node_count']} epochs={config['epochs']} trials={config['trials']} seed={config['seed']}",
            (
                "faults="
                + f"loss:{config['packet_loss']} "
                + f"delay:{config['packet_delay']} "
                + f"ack_corruption:{config['ack_corruption']} "
                + f"duplicate:{config['duplicate']} "
                + f"node_crash:{config['node_crash']}"
            ),
            f"safety_violation_runs={summary['safety_violation_runs']}",
            f"halted_runs={summary['halted_runs']}",
            f"crashed_runs={summary['crashed_runs']}",
            f"all_running_runs={summary['all_running_runs']}",
            f"avg_committed_epochs_per_node={summary['avg_committed_epochs_per_node']:.2f}",
        ]
    )


def main() -> int:
    args = parse_args()
    config = RandomFaultConfig(
        node_count=args.nodes,
        epochs=args.epochs,
        trials=args.trials,
        seed=args.seed,
        packet_loss=args.packet_loss,
        packet_delay=args.packet_delay,
        ack_corruption=args.ack_corruption,
        duplicate=args.duplicate,
        node_crash=args.node_crash,
    )

    if args.sweep is not None:
        values = [float(value) for value in args.values.split(",") if value]
        rows = sweep_campaigns(config, parameter=args.sweep, values=values)
        writer = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
        return 1 if any(row["safety_violation_runs"] for row in rows) else 0

    report = run_campaign(config)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(text_summary(report))

    return 1 if report["summary"]["safety_violation_runs"] else 0
