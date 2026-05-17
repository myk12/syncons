#!/usr/bin/env python3

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
import pandas as pd

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

SCENARIO_LABELS = {
    "node_crash": "Node crashes",
    "asymmetric_loss": "Asymmetric loss",
    "bridge_partition": "Bridge partition",
}

SCENARIO_ORDER = ["node_crash", "asymmetric_loss", "bridge_partition"]
PALETTE = {
    "node_crash": "#4169E1",
    "asymmetric_loss": "#FF8C00",
    "bridge_partition": "#DC143C",
}
EVENT_STYLE = {
    "fault": {"color": "#F85858", "linestyle": (0, (3, 2)), "linewidth": 1.1, "label": "Fault injected"},
    "recovery": {"color": "#035628", "linestyle": "-", "linewidth": 1.1, "label": "Recovery activated"},
}
MARKERS = {
    "node_crash": "s",
    "asymmetric_loss": "^",
    "bridge_partition": "o",
}
LINESTYLES = {
    "node_crash": "-",
    "asymmetric_loss": "--",
    "bridge_partition": ":",
}
LINEWIDTHS = {
    "node_crash": 3.0,
    "asymmetric_loss": 3.0,
    "bridge_partition": 3.0,
}
MARKERSIZES = {
    "node_crash": 5.0,
    "asymmetric_loss": 5.0,
    "bridge_partition": 5.0,
}


def load_timeline_data(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"{path} does not exist")

    data = pd.read_csv(path)
    required = {"scenario", "time_ms", "throughput_mops"}
    missing = required.difference(data.columns)
    if missing:
        raise ValueError(f"missing columns in recovery timeline data: {sorted(missing)}")

    data = data[data["scenario"].isin(SCENARIO_ORDER)].copy()
    data["scenario"] = pd.Categorical(data["scenario"], categories=SCENARIO_ORDER, ordered=True)
    data = data.sort_values(["scenario", "time_ms"]).reset_index(drop=True)
    return data


def _apply_axes_style(ax: plt.Axes, *, ylabel: str | None = None) -> None:
    ax.set_facecolor("white")
    ax.grid(axis="y", color="#E5E7EB", linewidth=0.45, linestyle="--", alpha=0.7)
    ax.grid(axis="x", color="#F3F4F6", linewidth=0.35, linestyle="--", alpha=0.55)
    for spine in ax.spines.values():
        spine.set_visible(True)
        spine.set_color("black")
        spine.set_linewidth(0.9)
    ax.tick_params(axis="both", colors="black", width=0.8, length=3)
    if ylabel is not None:
        ax.set_ylabel(ylabel)
    ax.set_ylim(bottom=0)


def plot_timeline_panels(data: pd.DataFrame, out_path: Path) -> None:
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.size": 8.5,
            "axes.linewidth": 0.9,
            "axes.edgecolor": "black",
            "axes.labelsize": 9.5,
            "axes.titlesize": 9.5,
            "xtick.labelsize": 8.0,
            "ytick.labelsize": 8.0,
            "legend.fontsize": 8.0,
        }
    )

    fig, axes = plt.subplots(1, 3, figsize=(6.0, 1.7), dpi=300, sharey=True)
    for idx, scenario in enumerate(SCENARIO_ORDER):
        ax = axes[idx]
        scenario_data = data[data["scenario"] == scenario]
        if scenario_data.empty:
            continue

        ax.plot(
            scenario_data["time_ms"],
            scenario_data["throughput_mops"],
            color=PALETTE[scenario],
            linewidth=LINEWIDTHS[scenario],
            linestyle=LINESTYLES[scenario],
            marker=MARKERS[scenario],
            markersize=MARKERSIZES[scenario],
            markerfacecolor=PALETTE[scenario],
            markeredgewidth=0.0,
            markevery=6,
        )
        if "fault_rounds" in scenario_data.columns and "round_length_ns" in scenario_data.columns:
            round_length_ns = int(scenario_data["round_length_ns"].iloc[0])
            fault_rounds = [
                int(item)
                for item in str(scenario_data["fault_rounds"].iloc[0]).split(",")
                if item.strip()
            ]
            for fault_round in fault_rounds:
                fault_time_ms = (fault_round * round_length_ns) / 1_000_000
                ax.axvline(
                    fault_time_ms,
                    color=EVENT_STYLE["fault"]["color"],
                    linewidth=EVENT_STYLE["fault"]["linewidth"],
                    linestyle=EVENT_STYLE["fault"]["linestyle"],
                    alpha=0.95,
                )
        if "recovery_time_ms" in scenario_data.columns:
            recovery_time_ms = float(scenario_data["recovery_time_ms"].iloc[0])
            ax.axvline(
                recovery_time_ms,
                color=EVENT_STYLE["recovery"]["color"],
                linewidth=EVENT_STYLE["recovery"]["linewidth"],
                linestyle=EVENT_STYLE["recovery"]["linestyle"],
                alpha=0.95,
            )

        ax.set_xlabel("Time (ms)")
        if idx == 0:
            _apply_axes_style(ax, ylabel="Throughput (M ops/s)")
        else:
            _apply_axes_style(ax, ylabel=None)

    fig.tight_layout(pad=0.35, w_pad=0.55)
    event_handles = [
        Line2D(
            [0],
            [0],
            color=EVENT_STYLE["fault"]["color"],
            linestyle=EVENT_STYLE["fault"]["linestyle"],
            linewidth=EVENT_STYLE["fault"]["linewidth"],
            label=EVENT_STYLE["fault"]["label"],
        ),
        Line2D(
            [0],
            [0],
            color=EVENT_STYLE["recovery"]["color"],
            linestyle=EVENT_STYLE["recovery"]["linestyle"],
            linewidth=EVENT_STYLE["recovery"]["linewidth"],
            label=EVENT_STYLE["recovery"]["label"],
        ),
    ]
    scenario_handles = [
        Line2D(
            [0],
            [0],
            color=PALETTE[scenario],
            linestyle=LINESTYLES[scenario],
            marker=MARKERS[scenario],
            markersize=MARKERSIZES[scenario],
            linewidth=LINEWIDTHS[scenario],
            label=SCENARIO_LABELS[scenario],
        )
        for scenario in SCENARIO_ORDER
    ]
    axes[0].legend(
        handles=event_handles,
        loc="best",
        frameon=True,
        fancybox=False,
        framealpha=1.0,
        edgecolor="#BFC6CF",
        facecolor="white",
        borderpad=0.35,
        handlelength=1.9,
        fontsize=7.8,
    )
    axes[1].legend(
        handles=scenario_handles,
        loc="best",
        frameon=True,
        fancybox=False,
        framealpha=1.0,
        edgecolor="#BFC6CF",
        facecolor="white",
        borderpad=0.35,
        handlelength=1.8,
        fontsize=7.8,
    )
    fig.savefig(out_path, bbox_inches="tight")
    logging.info("Wrote %s", out_path)


def plot_timeline_merged(data: pd.DataFrame, out_path: Path) -> None:
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.size": 8.5,
            "axes.linewidth": 0.9,
            "axes.edgecolor": "black",
            "axes.labelsize": 9.5,
            "axes.titlesize": 9.5,
            "xtick.labelsize": 8.0,
            "ytick.labelsize": 8.0,
            "legend.fontsize": 8.2,
        }
    )

    fig, ax = plt.subplots(figsize=(4.0, 3.0))

    for scenario in SCENARIO_ORDER:
        scenario_data = data[data["scenario"] == scenario]
        if scenario_data.empty:
            continue
        ax.plot(
            scenario_data["time_ms"],
            scenario_data["throughput_mops"],
            color=PALETTE[scenario],
            linewidth=LINEWIDTHS[scenario],
            linestyle=LINESTYLES[scenario],
            marker=MARKERS[scenario],
            markersize=3.4,
            markerfacecolor=PALETTE[scenario],
            markeredgewidth=0.0,
            markevery=6,
            label=SCENARIO_LABELS[scenario],
        )

        if "fault_rounds" in scenario_data.columns and "round_length_ns" in scenario_data.columns:
            round_length_ns = int(scenario_data["round_length_ns"].iloc[0])
            fault_rounds = [
                int(item)
                for item in str(scenario_data["fault_rounds"].iloc[0]).split(",")
                if item.strip()
            ]
            if fault_rounds:
                fault_time_ms = (fault_rounds[0] * round_length_ns) / 1_000_000
                ax.axvline(
                    fault_time_ms,
                    color=EVENT_STYLE["fault"]["color"],
                    linewidth=EVENT_STYLE["fault"]["linewidth"],
                    linestyle=EVENT_STYLE["fault"]["linestyle"],
                    alpha=0.85,
                )
        if "recovery_time_ms" in scenario_data.columns:
            recovery_time_ms = float(scenario_data["recovery_time_ms"].iloc[0])
            ax.axvline(
                recovery_time_ms,
                color=EVENT_STYLE["recovery"]["color"],
                linewidth=EVENT_STYLE["recovery"]["linewidth"],
                linestyle=EVENT_STYLE["recovery"]["linestyle"],
                alpha=0.85,
            )

    ax.set_xlabel("Time (ms)")
    _apply_axes_style(ax, ylabel="Throughput (M ops/s)")

    scenario_handles = [
        Line2D(
            [0],
            [0],
            color=PALETTE[scenario],
            linestyle=LINESTYLES[scenario],
            marker=MARKERS[scenario],
            markersize=MARKERSIZES[scenario],
            linewidth=LINEWIDTHS[scenario],
            label=SCENARIO_LABELS[scenario],
        )
        for scenario in SCENARIO_ORDER
    ]
    event_handles = [
        Line2D(
            [0],
            [0],
            color=EVENT_STYLE["fault"]["color"],
            linestyle=EVENT_STYLE["fault"]["linestyle"],
            linewidth=EVENT_STYLE["fault"]["linewidth"],
            label=EVENT_STYLE["fault"]["label"],
        ),
        Line2D(
            [0],
            [0],
            color=EVENT_STYLE["recovery"]["color"],
            linestyle=EVENT_STYLE["recovery"]["linestyle"],
            linewidth=EVENT_STYLE["recovery"]["linewidth"],
            label=EVENT_STYLE["recovery"]["label"],
        ),
    ]
    handles = scenario_handles + event_handles
    ax.legend(
        handles=handles,
        loc="bottom center",
        bbox_to_anchor=(0.5, 1.0),
        ncol=2,
        frameon=False,
        handlelength=2.0,
        columnspacing=1.1,
    )

    fig.tight_layout(pad=0.35)
    fig.savefig(out_path, bbox_inches="tight")
    logging.info("Wrote %s", out_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot the SynCons recovery throughput timeline.")
    parser.add_argument(
        "--file-path",
        type=Path,
        default=Path("eval/results/recovery_timeline/recovery_timeline.csv"),
        help="Path to the recovery timeline CSV.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("eval/results/recovery_timeline/recovery_timeline.pdf"),
        help="Output path for the rendered figure.",
    )
    parser.add_argument(
        "--layout",
        choices=("panels", "merged"),
        default="panels",
        help="Plot scenarios as separate panels or merged into a single axes.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    data = load_timeline_data(args.file_path)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if args.layout == "merged":
        plot_timeline_merged(data, args.out)
    else:
        plot_timeline_panels(data, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
