#!/usr/bin/env python3

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
import pandas as pd

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

BASELINES = {
    3: {"NOPaxos": 100_000.0, "Watchmaker": 99_000.0},
    5: {"NOPaxos": 100_000.0, "Watchmaker": 99_000.0},
}

ORDER = ["NOPaxos", "Watchmaker", "8us", "4us", "2us"]
DISPLAY_LABELS = {
    "NOPaxos": "NOPaxos",
    "Watchmaker": "WatchMaker",
    "8us": "SSR-8us",
    "4us": "SSR-4us",
    "2us": "SSR-2us",
}
SYSTEM_STYLE = {
    "NOPaxos": {"facecolor": "#7A4A0C", "edgecolor": "#7A4A0C", "hatch": ""},
    "Watchmaker": {"facecolor": "#B05CC1", "edgecolor": "#6F2B7A", "hatch": "//"},
    "8us": {"facecolor": "#7FB069", "edgecolor": "#4A7A3B", "hatch": "\\\\"},
    "4us": {"facecolor": "#F4A53A", "edgecolor": "#8A5A12", "hatch": "++"},
    "2us": {"facecolor": "#4169E1", "edgecolor": "#27408B", "hatch": ".."},
}
GROUP_ORDER = [3, 5]


def _load_throughput_data(file_path: Path) -> pd.DataFrame:
    if not file_path.exists():
        raise FileNotFoundError(f"{file_path} does not exist")

    data = pd.read_csv(file_path)
    required_columns = {"round_length", "cluster_commit_rate_eps", "node_count"}
    missing = required_columns.difference(data.columns)
    if missing:
        raise ValueError(f"missing columns in throughput data: {sorted(missing)}")

    sim_rows = []
    for _, row in data.iterrows():
        node_count = int(row["node_count"])
        label = str(row["round_length"])
        throughput_ops = float(row["cluster_commit_rate_eps"]) * node_count
        sim_rows.append(
            {
                "node_count": node_count,
                "label": label,
                "throughput_mops": throughput_ops / 1_000_000,
                "kind": "syncons",
            }
        )

    baseline_rows = []
    for node_count in sorted(BASELINES):
        for label, throughput_ops in BASELINES[node_count].items():
            baseline_rows.append(
                {
                    "node_count": node_count,
                    "label": label,
                    "throughput_mops": throughput_ops / 1_000_000,
                    "kind": "baseline",
                }
            )

    plot_data = pd.DataFrame(sim_rows + baseline_rows)
    plot_data["label"] = pd.Categorical(plot_data["label"], categories=ORDER, ordered=True)
    plot_data = plot_data.sort_values(["node_count", "label"]).reset_index(drop=True)
    return plot_data


def plot_throughput(data: pd.DataFrame, out_path: Path) -> None:
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.size": 8.5,
            "axes.linewidth": 0.9,
            "axes.edgecolor": "black",
            "axes.labelsize": 9.5,
            "xtick.labelsize": 8.0,
            "ytick.labelsize": 8.0,
            "legend.fontsize": 8.0,
            "hatch.color": "black",
        }
    )

    fig, ax = plt.subplots(figsize=(6.0, 1.5), dpi=300)
    group_positions = list(range(len(GROUP_ORDER)))
    bar_width = 0.14
    offsets = {
        label: (idx - (len(ORDER) - 1) / 2.0) * bar_width
        for idx, label in enumerate(ORDER)
    }

    for label in ORDER:
        style = SYSTEM_STYLE[label]
        xs: list[float] = []
        heights: list[float] = []
        for idx, node_count in enumerate(GROUP_ORDER):
            row = data[(data["node_count"] == node_count) & (data["label"] == label)]
            if row.empty:
                continue
            xs.append(group_positions[idx] + offsets[label])
            heights.append(float(row["throughput_mops"].iloc[0]))

        bars = ax.bar(
            xs,
            heights,
            width=bar_width,
            color=style["facecolor"],
            edgecolor="black",
            linewidth=0.8,
            zorder=3,
            label=DISPLAY_LABELS[label],
        )
        for bar in bars:
            if style["hatch"]:
                bar.set_hatch(style["hatch"])

    ax.set_ylabel("Throughput (M ops/s)")
    ax.set_xticks(group_positions)
    ax.set_xticklabels(["3 replicas", "5 replicas"], rotation=0)
    ax.set_xlim(min(group_positions) - 0.5, max(group_positions) + 0.5)
    ax.set_ylim(bottom=0)
    ax.set_facecolor("white")
    ax.grid(axis="y", color="#E5E7EB", linewidth=0.45, linestyle="--", alpha=0.7)
    ax.grid(axis="x", color="#F3F4F6", linewidth=0.35, linestyle="--", alpha=0.5)
    for spine in ax.spines.values():
        spine.set_visible(True)
        spine.set_color("black")
        spine.set_linewidth(0.9)
    ax.tick_params(axis="both", colors="black", width=0.8, length=3, direction="in", top=True, right=True)
    legend_handles = [
        Patch(
            facecolor=SYSTEM_STYLE[label]["facecolor"],
            edgecolor="black",
            linewidth=0.8,
            hatch=SYSTEM_STYLE[label]["hatch"],
            label=DISPLAY_LABELS[label],
        )
        for label in ORDER
    ]
    ax.legend(
        handles=legend_handles,
        loc="best",
        ncol=3,
        frameon=True,
        fancybox=False,
        framealpha=1.0,
        edgecolor="#BFC6CF",
        facecolor="white",
        handlelength=1.8,
        columnspacing=1.1,
        fontsize=8.4,
    )
    ax.set_ylim(0, 2.7)
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda y, _: f"{y:.1f}"))

    fig.tight_layout(pad=0.3)
    fig.savefig(out_path, bbox_inches="tight")
    logging.info("Wrote %s", out_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot the SSR steady-state throughput comparison.")
    parser.add_argument(
        "--file-path",
        type=Path,
        default=Path("eval/results/steady_state_throughput/steady_state_throughput.csv"),
        help="Path to the steady-state throughput CSV.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("eval/results/steady_state_throughput/throughput_comparison.pdf"),
        help="Output path for the rendered figure.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    data = _load_throughput_data(args.file_path)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    plot_throughput(data, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
