from __future__ import annotations

import argparse
import json
import os

from .cluster import ClusterRun
from .scenarios import SCENARIOS
from .types import ScenarioExpectation, bitmap_text


def _format_rows(rows: dict[int, int], node_count: int) -> str:
    return "{%s}" % ", ".join(
        f"{node_id}:{bitmap_text(rows.get(node_id, 0), node_count)}"
        for node_id in range(node_count)
    )


def _format_stage(stage: dict[str, object], node_count: int) -> str:
    return (
        f"epoch={stage['epoch']} "
        f"membership={bitmap_text(stage['membership_bitmap'], node_count)} "
        f"ack_bitmap={bitmap_text(stage['my_bitmap'], node_count)} "
        f"ack_matrix={_format_rows(stage['ack_rows'], node_count)}"
    )


def _color_enabled() -> bool:
    term = os.environ.get("TERM", "")
    return term not in ("", "dumb") and os.environ.get("NO_COLOR") is None


def _paint(text: str, color: str | None, bold: bool = False) -> str:
    if not _color_enabled() or color is None:
        return text
    colors = {
        "blue": "34",
        "cyan": "36",
        "green": "32",
        "yellow": "33",
        "red": "31",
        "magenta": "35",
        "gray": "90",
    }
    code = colors[color]
    prefix = "\033[" + ("1;" if bold else "") + code + "m"
    return prefix + text + "\033[0m"


def _status_color(status: str) -> str | None:
    if status == "RUNNING":
        return "green"
    if status == "HALTED":
        return "red"
    if status == "CRASHED":
        return "magenta"
    return None


def _decision_color(decision: str | None) -> str | None:
    if decision == "CONTINUE":
        return "green"
    if decision == "HALT":
        return "red"
    if decision == "SKIP":
        return "gray"
    return None


def _membership_state_short(value: str) -> str:
    return {
        "ACTIVE": "A",
        "FAILED": "F",
        "RECOVERING": "R",
        "REJOIN_PENDING": "P",
    }.get(value, value[:1])


def _is_fault_reason(reason: str) -> bool:
    normalized = reason.lower()
    benign_markers = (
        "same-epoch delivery",
        "deliver",
    )
    if any(marker in normalized for marker in benign_markers):
        return False
    return True


def _bitmap_membership_states(node_states: dict[int, str]) -> str:
    return " ".join(
        f"{node_id}:{_membership_state_short(state)}"
        for node_id, state in sorted(node_states.items())
    )


def _format_bitmap_or_none(value: int | None, node_count: int) -> str:
    if value is None:
        return "none"
    return bitmap_text(value, node_count)


def _boundary_summary(boundary: dict[str, object] | None, node_count: int) -> str:
    if boundary is None:
        return "boundary=none"
    if not boundary.get("evaluated", False):
        return f"boundary=SKIP reason={boundary.get('reason')} stage_epoch={boundary.get('stage_epoch')}"

    decision = str(boundary.get("decision", "unknown"))
    decision_text = _paint(decision, _decision_color(decision), bold=True)
    parts = [
        f"stage_epoch={boundary['stage_epoch']}",
        f"quorum={boundary['quorum']}",
        f"previous_witness_core={_format_bitmap_or_none(boundary.get('previous_witness_core'), node_count)}",
        f"self_row={_format_bitmap_or_none(boundary.get('self_row'), node_count)}",
        f"certified_row={_format_bitmap_or_none(boundary.get('certified_row'), node_count)}",
        f"commit_set={_format_bitmap_or_none(boundary.get('commit_set'), node_count)}",
        f"witness_core={_format_bitmap_or_none(boundary.get('witness_core'), node_count)}",
        f"decision={decision_text}",
    ]
    if boundary.get("halt_reason") is not None:
        parts.append(f"reason={boundary['halt_reason']}")
    return " ".join(parts)


def _stage_compact(stage: dict[str, object], node_count: int) -> str:
    return (
        f"epoch={stage['epoch']} "
        f"membership={bitmap_text(stage['membership_bitmap'], node_count)} "
        f"ack_bitmap={bitmap_text(stage['my_bitmap'], node_count)} "
        f"ack_matrix={_format_rows(stage['ack_rows'], node_count)}"
    )


def _box_header(title: str, color: str = "blue") -> str:
    bar = "━" * 24
    return _paint(f"{bar} {title} {bar}", color, bold=True)


def _section_header(title: str, color: str = "cyan") -> str:
    return _paint(f"{title}:", color, bold=True)


def epoch_trace_text(result: dict[str, object]) -> str:
    node_count = result["node_count"]
    lines: list[str] = []

    for epoch in result["epoch_trace"]:
        control = epoch["control"]
        lines.append(_box_header(f"Epoch {epoch['epoch']}", "blue"))
        lines.append(
            "  "
            + f"control  membership_epoch={control['membership_epoch']} "
            + f"membership={bitmap_text(control['members_bitmap'], node_count)} "
            + f"run_id={control['run_id']} "
            + f"node_states=[{_bitmap_membership_states(control['node_states'])}]"
        )

        lines.append(_section_header("Advance", "cyan"))
        for transition in epoch["transitions"]:
            node_state = next(node for node in epoch["node_end_state"] if node["node_id"] == transition["node_id"])
            boundary = node_state.get("last_boundary_evaluation")
            status_after = _paint(
                transition["status_after"],
                _status_color(transition["status_after"]),
                bold=True,
            )
            fault_value = transition["fault"] or "-"
            if transition["fault"] is not None:
                fault_value = _paint(str(transition["fault"]), "red", bold=True)
            lines.append(
                "  "
                + f"node{transition['node_id']}  "
                + f"cp={transition['control_plane']}  "
                + f"fault={fault_value}  "
                + f"status={transition['status_before']}->{status_after}  "
                + f"membership={transition['membership_state_before']}->{transition['membership_state_after']}"
            )
            outbound = transition["outbound"]
            if outbound is None:
                lines.append("    tx        none")
            else:
                lines.append(
                    "    tx        "
                    + f"dst={tuple(outbound['destinations'])}  "
                    + f"run_id={outbound['run_id']}  "
                    + f"ack={bitmap_text(outbound['ack_bitmap'], node_count)}  "
                    + f"payload={outbound['payload']}"
                )
            lines.append("    boundary  " + _boundary_summary(boundary, node_count))

        lines.append(_section_header("Network", "yellow"))
        if epoch["network"]:
            queue_count = sum(1 for entry in epoch["network"] if entry["kind"] == "queue")
            deliver_count = sum(1 for entry in epoch["network"] if entry["kind"] == "deliver")
            drop_count = sum(1 for entry in epoch["network"] if entry["kind"] == "drop")
            lines.append(
                "  "
                + f"summary  queue={queue_count}  deliver={deliver_count}  drop={drop_count}"
            )
            for entry in epoch["network"]:
                if entry["kind"] == "drop":
                    reason = (
                        _paint(entry["reason"], "red", bold=True)
                        if _is_fault_reason(entry["reason"])
                        else entry["reason"]
                    )
                    lines.append(
                        _paint("  DROP  ", "red", bold=True)
                        + f"n{entry['src']}->{entry['dst']} "
                        + f"packet_epoch={entry['packet_epoch']} "
                        + f"run_id={entry['run_id']} "
                        + f"ack={bitmap_text(entry['ack_bitmap'], node_count)} "
                        + f"reason={reason}"
                    )
                elif entry["kind"] == "queue":
                    reason = (
                        _paint(entry["reason"], "red", bold=True)
                        if _is_fault_reason(entry["reason"])
                        else entry["reason"]
                    )
                    lines.append(
                        _paint("  QUEUE", "yellow", bold=True)
                        + f" n{entry['src']}->{entry['dst']} "
                        + f"packet_epoch={entry['packet_epoch']} "
                        + f"deliver_epoch={entry['deliver_epoch']} "
                        + f"run_id={entry['run_id']} "
                        + f"ack={bitmap_text(entry['ack_bitmap'], node_count)} "
                        + f"reason={reason}"
                    )
                else:
                    lines.append(
                        _paint("  DELIVR", "green", bold=True)
                        + f" n{entry['src']}->{entry['dst']} "
                        + f"packet_epoch={entry['packet_epoch']} "
                        + f"run_id={entry['run_id']} "
                        + f"ack={bitmap_text(entry['ack_bitmap'], node_count)}"
                    )
        else:
            lines.append("  summary  queue=0  deliver=0  drop=0")
            lines.append("  none")

        lines.append(_section_header("State", "magenta"))
        for node in epoch["node_end_state"]:
            status_text = _paint(node["status"], _status_color(node["status"]), bold=True)
            lines.append(
                "  "
                + f"node{node['node_id']} "
                + f"status={status_text} "
                + f"membership_state={node['membership_state']} "
                + f"installed={bitmap_text(node['installed_membership'], node_count)} "
                + f"current_witness_core={bitmap_text(node['fast_path_bitmap'], node_count)} "
                + f"run_id={node['run_id']}"
            )
            lines.append(
                "    "
                + f"current_stage[{_stage_compact(node['current_stage'], node_count)}]"
            )
            lines.append(
                "    "
                + f"ack_stage    [{_stage_compact(node['ack_stage'], node_count)}]"
            )
            lines.append(
                "    "
                + f"commit_stage [{_stage_compact(node['commit_stage'], node_count)}]"
            )

        lines.append(_paint("━" * 58, "blue"))
        lines.append("")

    return "\n".join(lines).rstrip()


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
            group = details["witness_core_lineage"]
            group_text = (
                "none"
                if group is None
                else bitmap_text(group, result["node_count"])
            )
            lines.append(
                "  "
                + "halt failed_epoch="
                + str(details["failed_epoch"])
                + f" run_id={details['run_id']}"
                + f" reason={details['halt_reason']}"
                + f" membership={bitmap_text(details['membership_bitmap'], result['node_count'])}"
                + f" self_row={bitmap_text(details['self_row'], result['node_count'])}"
                + f" frontier={details['committed_frontier']}"
                + f" witness_core_lineage={group_text}"
                + f" log_digest={str(details['log_digest'])[:12]}"
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
        network_fault_model=spec.network_fault_model,
        node_fault_model=spec.node_fault_model,
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
        print("\nEpoch trace:")
        print(epoch_trace_text(result))

    if args.show_trace:
        for node in result["nodes"]:
            print(f"\nTrace for node {node['node_id']}:")
            for entry in node["trace"]:
                print(entry)

    return 1 if failures else 0
