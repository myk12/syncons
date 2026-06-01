#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from sim.protocol.types import JsonDict
from sim.runtime.random_campaign import RandomFaultConfig, sweep_campaigns


DEFAULT_VALUES = [0.0, 0.001, 0.005, 0.01, 0.02, 0.05]
DEFAULT_PRESETS = [
    "packet_loss",
    "packet_delay",
    "ack_corruption",
    "duplicate",
    "node_crash",
]


def write_csv(path: Path, rows: list[JsonDict]) -> None:
    if not rows:
        raise ValueError(f"no rows to write for {path}")
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def parse_values(raw: str) -> list[float]:
    return [float(value) for value in raw.split(",") if value]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate SSR evaluation sweep CSVs.")
    parser.add_argument("--out", type=Path, default=Path("eval/results/random_sweeps"))
    parser.add_argument("--nodes", type=int, default=3)
    parser.add_argument("--rounds", "--epochs", dest="rounds", type=int, default=8)
    parser.add_argument("--trials", type=int, default=200)
    parser.add_argument("--seed", type=int, default=20260425)
    parser.add_argument(
        "--values",
        default=",".join(str(value) for value in DEFAULT_VALUES),
        help="Comma-separated probability values for each sweep.",
    )
    parser.add_argument(
        "--presets",
        default=",".join(DEFAULT_PRESETS),
        help="Comma-separated presets to run.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    values = parse_values(args.values)
    presets = [preset for preset in args.presets.split(",") if preset]
    base_config = RandomFaultConfig(
        node_count=args.nodes,
        rounds=args.rounds,
        trials=args.trials,
        seed=args.seed,
    )

    manifest = {
        "base_config": asdict(base_config),
        "values": values,
        "presets": presets,
        "files": [],
    }
    safety_violation_runs = 0

    for preset in presets:
        rows = sweep_campaigns(base_config, parameter=preset, values=values)
        safety_violation_runs += sum(int(row["safety_violation_runs"]) for row in rows)
        output_path = args.out / f"{preset}.csv"
        write_csv(output_path, rows)
        manifest["files"].append(str(output_path))
        print(f"wrote {output_path}")

    manifest_path = args.out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {manifest_path}")

    return 1 if safety_violation_runs else 0


if __name__ == "__main__":
    raise SystemExit(main())
