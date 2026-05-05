from __future__ import annotations

import argparse
import hashlib
import json
import os

from .cluster import ClusterRun
from ..protocol.types import ScenarioExpectation, SimulationTiming, bitmap_text, format_duration_ns, parse_duration_ns
from ..scenarios.builtin import SCENARIOS


def _format_rows(rows: dict[int, int], node_count: int) -> str:
    return "{%s}" % ", ".join(
        f"{node_id}:{bitmap_text(rows.get(node_id, 0), node_count)}"
        for node_id in range(node_count)
    )


def _format_stage(stage: dict[str, object], node_count: int) -> str:
    return (
        f"round={stage['round']} "
        f"membership={bitmap_text(stage['installed_membership'], node_count)} "
        f"sound_bitmap={bitmap_text(stage['sound_bitmap'], node_count)} "
        f"sound_matrix={_format_rows(stage['sound_matrix'], node_count)}"
    )


def _format_stage_line(label: str, stage: dict[str, object], node_count: int) -> str:
    return "    " + f"{label:<15}[{_stage_compact(stage, node_count)}]"


def _format_pending_config(pending: dict[str, object] | None, node_count: int) -> str:
    if pending is None:
        return "none"
    return (
        f"status={pending['status']} "
        f"effective_round={pending['effective_round']} "
        f"members={bitmap_text(pending['members_bitmap'], node_count)} "
        f"run_id={pending['run_id']}"
    )


def _format_committed_sequence(committed_rounds: list[dict[str, object]], node_count: int) -> str:
    if not committed_rounds:
        return "[]"
    encoded_entries: list[str] = []
    group_parts: list[str] = []
    current_bitmap = int(committed_rounds[0]["commit_set"])
    current_count = 0

    for entry in committed_rounds:
        round_id = int(entry["round"])
        commit_set = int(entry["commit_set"])
        members = tuple(sorted(int(member) for member in entry["proposals"].keys()))
        encoded_entries.append(
            f"{round_id}:{commit_set}:{','.join(str(member) for member in members)}"
        )
        if commit_set == current_bitmap:
            current_count += 1
            continue
        group_parts.append(f"{bitmap_text(current_bitmap, node_count)}x{current_count}")
        current_bitmap = commit_set
        current_count = 1

    group_parts.append(f"{bitmap_text(current_bitmap, node_count)}x{current_count}")

    digest = hashlib.sha256("|".join(encoded_entries).encode("utf-8")).hexdigest()[:12]
    first_round = int(committed_rounds[0]["round"])
    last_round = int(committed_rounds[-1]["round"])
    round_span = f"{first_round}" if first_round == last_round else f"{first_round}-{last_round}"
    return (
        f"[len={len(committed_rounds)} "
        + f"rounds={round_span} "
        + f"digest={digest} "
        + f"groups={','.join(group_parts)}]"
    )


def _format_control_plane_event(event: dict[str, object], node_count: int) -> str:
    kind = str(event["kind"])
    if kind == "PrepareAck":
        config = event["config"]
        return (
            f"PrepareAck node={event['node_id']} "
            + f"effective_round={config['effective_round']} "
            + f"members={bitmap_text(config['members_bitmap'], node_count)} "
            + f"run_id={config['run_id']}"
        )
    if kind == "NodeHalted":
        halt = event["halt_record"]
        return (
            f"NodeHalted node={event['node_id']} "
            + f"failed_round={halt['failed_round']} "
            + f"reason={halt['halt_reason']} "
            + f"visible_at={format_duration_ns(int(event['available_at_ns']))}"
        )
    if kind == "NodeCrashed":
        return (
            f"NodeCrashed node={event['node_id']} "
            + f"visible_at={format_duration_ns(int(event['available_at_ns']))}"
        )
    return json.dumps(event, sort_keys=True)


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


def _format_int_list_or_none(values: list[int] | None) -> str:
    if not values:
        return "none"
    return ",".join(str(value) for value in values)


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


def _boundary_summary(boundary: dict[str, object] | None, node_count: int) -> str:
    if boundary is None:
        return "boundary=none"
    if not boundary.get("evaluated", False):
        return f"boundary=SKIP reason={boundary.get('reason')} stage_round={boundary.get('stage_round')}"

    decision = str(boundary.get("decision", "unknown"))
    decision_text = _paint(decision, _decision_color(decision), bold=True)
    parts = [
        f"stage_round={boundary['stage_round']}",
        f"quorum={boundary['quorum']}",
        f"previous_sound_set={_format_bitmap_or_none(boundary.get('previous_sound_set'), node_count)}",
        f"self_row={_format_bitmap_or_none(boundary.get('self_row'), node_count)}",
        f"agreed_row={_format_bitmap_or_none(boundary.get('agreed_row'), node_count)}",
        f"commit_set={_format_bitmap_or_none(boundary.get('commit_set'), node_count)}",
        f"sound_set={_format_bitmap_or_none(boundary.get('sound_set'), node_count)}",
        f"decision={decision_text}",
    ]
    if boundary.get("halt_reason") is not None:
        parts.append(f"reason={boundary['halt_reason']}")
    return " ".join(parts)


def _stage_compact(stage: dict[str, object], node_count: int) -> str:
    return (
        f"round={stage['round']} "
        f"membership={bitmap_text(stage['installed_membership'], node_count)} "
        f"sound_bitmap={bitmap_text(stage['sound_bitmap'], node_count)} "
        f"sound_matrix={_format_rows(stage['sound_matrix'], node_count)}"
    )


def _box_header(title: str, color: str = "blue") -> str:
    bar = "━" * 24
    return _paint(f"{bar} {title} {bar}", color, bold=True)


def _section_header(title: str, color: str = "cyan") -> str:
    return _paint(f"{title}:", color, bold=True)


def _render_round_record(round_record: dict[str, object], node_count: int) -> list[str]:
    lines: list[str] = []
    control = round_record["control"]
    lines.append(_box_header(f"Round {round_record['round']}", "blue"))
    lines.append(
        "  "
        + f"time     start={format_duration_ns(round_record['start_time_ns'])} "
        + f"end={format_duration_ns(round_record['end_time_ns'])}"
    )
    lines.append(
        "  "
        + f"control  membership_epoch={control['membership_epoch']} "
        + f"membership={bitmap_text(control['members_bitmap'], node_count)} "
        + f"run_id={control['run_id']} "
        + f"node_states=[{_bitmap_membership_states(control['node_states'])}]"
    )
    cp_runtime = round_record.get("control_plane_runtime") or {}
    collection_deadline_ns = cp_runtime.get("collection_deadline_ns")
    episode_members_bitmap = cp_runtime.get("episode_members_bitmap")
    pending_future = cp_runtime.get("pending_future")
    lines.append(
        "  "
        + "cp_runtime  "
        + f"collecting_targets={_format_int_list_or_none(cp_runtime.get('collecting_targets'))}  "
        + f"episode_targets={_format_int_list_or_none(cp_runtime.get('episode_targets'))}  "
        + f"episode_members={_format_bitmap_or_none(episode_members_bitmap, node_count)}  "
        + f"collection_deadline={format_duration_ns(int(collection_deadline_ns)) if collection_deadline_ns is not None else 'none'}  "
        + f"pending={_format_pending_config(pending_future, node_count)}"
    )

    cp_writes = round_record.get("control_plane_writes") or []
    if cp_writes:
        lines.append(_section_header("Control-plane writes", "magenta"))
        for write in cp_writes:
            lines.append(
                "  "
                + f"node{write['node_id']} "
                + f"membership_state={write['membership_state']} "
                + f"membership_epoch={write['membership_epoch']} "
                + f"members={bitmap_text(write['members_bitmap'], node_count)} "
                + f"run_id={write['run_id']} "
                + f"pending={write['pending']} "
                + f"repair_log_len={write['repair_log_len']}"
            )

    lines.append(_section_header("Advance", "cyan"))
    for transition in round_record["transitions"]:
        node_state = next(node for node in round_record["node_end_state"] if node["node_id"] == transition["node_id"])
        boundary = node_state.get("last_round_boundary_evaluation")
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
        cp_details = transition.get("control_plane_details") or []
        if cp_details:
            lines.append("    cp_detail  " + " | ".join(cp_details))
        outbound = transition["outbound"]
        if outbound is None:
            lines.append("    tx        none")
        else:
            lines.append(
                "    tx        "
                + f"dst={tuple(outbound['destinations'])}  "
                + f"run_id={outbound['run_id']}  "
                + f"sound={bitmap_text(outbound['sound_bitmap'], node_count)}  "
                + f"payload={outbound['payload']}"
            )
        lines.append("    boundary  " + _boundary_summary(boundary, node_count))

    cp_events = round_record.get("control_plane_events") or []
    if cp_events:
        lines.append(_section_header("Control-plane events", "magenta"))
        for event in cp_events:
            lines.append("  " + _format_control_plane_event(event, node_count))

    lines.append(_section_header("Network", "yellow"))
    if round_record["network"]:
        send_count = sum(1 for entry in round_record["network"] if entry["kind"] == "send")
        delay_count = sum(1 for entry in round_record["network"] if entry["kind"] == "delay")
        deliver_count = sum(1 for entry in round_record["network"] if entry["kind"] == "deliver")
        drop_count = sum(1 for entry in round_record["network"] if entry["kind"] == "drop")
        lines.append(
            "  "
            + f"summary  send={send_count}  delay={delay_count}  deliver={deliver_count}  drop={drop_count}"
        )
        for entry in round_record["network"]:
            if entry["kind"] == "drop":
                reason = (
                    _paint(entry["reason"], "red", bold=True)
                    if _is_fault_reason(entry["reason"])
                    else entry["reason"]
                )
                lines.append(
                    _paint("  DROP  ", "red", bold=True)
                    + f"n{entry['src']}->{entry['dst']} "
                    + f"packet_round={entry['packet_round']} "
                    + f"run_id={entry['run_id']} "
                    + f"sound={bitmap_text(entry['sound_bitmap'], node_count)} "
                    + f"reason={reason}"
                )
            elif entry["kind"] in {"send", "delay"}:
                reason = (
                    _paint(entry["reason"], "red", bold=True)
                    if _is_fault_reason(entry["reason"])
                    else entry["reason"]
                )
                lines.append(
                    _paint("  " + ("DELAY" if entry["kind"] == "delay" else "SEND "), "yellow", bold=True)
                    + f" n{entry['src']}->{entry['dst']} "
                    + f"packet_round={entry['packet_round']} "
                    + f"deliver_round={entry['deliver_round']} "
                    + f"run_id={entry['run_id']} "
                    + f"sound={bitmap_text(entry['sound_bitmap'], node_count)} "
                    + f"reason={reason}"
                )
            else:
                lines.append(
                    _paint("  DELIVR", "green", bold=True)
                    + f" n{entry['src']}->{entry['dst']} "
                    + f"packet_round={entry['packet_round']} "
                    + f"run_id={entry['run_id']} "
                    + f"sound={bitmap_text(entry['sound_bitmap'], node_count)}"
                )
    else:
        lines.append("  summary  send=0  delay=0  deliver=0  drop=0")
        lines.append("  none")

    lines.append(_section_header("State", "magenta"))
    for node in round_record["node_end_state"]:
        status_text = _paint(node["status"], _status_color(node["status"]), bold=True)
        lines.append(
            "  "
            + f"node{node['node_id']} "
            + f"status={status_text} "
            + f"membership_state={node['membership_state']} "
            + f"installed={bitmap_text(node['installed_membership'], node_count)} "
            + f"current_sound_set={bitmap_text(node['current_sound_set'], node_count)} "
            + f"run_id={node['run_id']}"
        )
        lines.append("    " + f"pending_config  {_format_pending_config(node.get('pending_config'), node_count)}")
        lines.append("    " + f"committed_seq  {_format_committed_sequence(node['committed_rounds'], node_count)}")
        lines.append(_format_stage_line("current_stage", node["current_stage"], node_count))
        lines.append(_format_stage_line("evidence_stage", node["evidence_stage"], node_count))
        lines.append(_format_stage_line("commit_stage", node["commit_stage"], node_count))

    lines.append(_paint("━" * 58, "blue"))
    lines.append("")
    return lines


def _interesting_rounds(result: dict[str, object]) -> set[int]:
    interesting: set[int] = set()
    previous_nodes: dict[int, dict[str, object]] | None = None

    for round_record in result["round_trace"]:
        round_id = int(round_record["round"])
        cp_runtime = round_record.get("control_plane_runtime") or {}
        if (
            round_record.get("control_plane_writes")
            or round_record.get("control_plane_events")
            or cp_runtime.get("collecting_targets")
            or cp_runtime.get("episode_targets")
            or cp_runtime.get("episode_members_bitmap") is not None
            or cp_runtime.get("collection_deadline_ns") is not None
            or cp_runtime.get("pending_future") is not None
        ):
            interesting.add(round_id)
        if any(entry["kind"] in {"drop", "delay"} for entry in round_record.get("network", [])):
            interesting.add(round_id)

        current_nodes = {
            int(node["node_id"]): node
            for node in round_record["node_end_state"]
        }
        for transition in round_record["transitions"]:
            boundary = current_nodes[int(transition["node_id"])].get("last_round_boundary_evaluation") or {}
            if (
                transition.get("fault") is not None
                or transition.get("control_plane") != "none"
                or boundary.get("decision") == "HALT"
            ):
                interesting.add(round_id)
        if previous_nodes is not None:
            for node_id, node in current_nodes.items():
                previous = previous_nodes[node_id]
                if (
                    node["status"] != previous["status"]
                    or node["membership_state"] != previous["membership_state"]
                    or node["installed_membership"] != previous["installed_membership"]
                    or node["current_sound_set"] != previous["current_sound_set"]
                    or node["run_id"] != previous["run_id"]
                    or node.get("pending_config") != previous.get("pending_config")
                ):
                    interesting.add(round_id)
                    break
        previous_nodes = current_nodes

    return interesting


def _selected_rounds(result: dict[str, object], trace_mode: str, trace_context: int) -> list[int]:
    all_rounds = [int(round_record["round"]) for round_record in result["round_trace"]]
    if trace_mode == "full":
        return all_rounds
    interesting = _interesting_rounds(result)
    if trace_mode == "event":
        return sorted(interesting)
    if trace_mode == "windowed":
        selected: set[int] = set()
        max_round = max(all_rounds, default=-1)
        for round_id in interesting:
            start = max(0, round_id - trace_context)
            end = min(max_round, round_id + trace_context)
            selected.update(range(start, end + 1))
        return sorted(selected)
    raise ValueError(f"unknown trace mode {trace_mode!r}")


def round_trace_text(
    result: dict[str, object],
    *,
    trace_mode: str = "full",
    trace_context: int = 1,
) -> str:
    node_count = result["node_count"]
    selected_rounds = set(_selected_rounds(result, trace_mode, trace_context))
    lines: list[str] = []
    last_emitted_round: int | None = None

    for round_record in result["round_trace"]:
        round_id = int(round_record["round"])
        if round_id not in selected_rounds:
            continue
        if last_emitted_round is not None and round_id > last_emitted_round + 1:
            skipped = round_id - last_emitted_round - 1
            lines.append(
                _paint(
                    f"... skipped {skipped} round(s) with no selected trace events ...",
                    "gray",
                )
            )
            lines.append("")
        lines.extend(_render_round_record(round_record, node_count))
        last_emitted_round = round_id

    if not lines:
        return "(no rounds selected for trace output)"
    return "\n".join(lines).rstrip()


def text_summary(result: dict[str, object]) -> str:
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


def performance_summary_text(result: dict[str, object]) -> str:
    node_count = int(result["node_count"])
    rounds = int(result["rounds"])
    timing = result["timing"]
    simulated_time_ns = int(result["simulated_time_ns"])
    round_length_ns = int(timing["round_length_ns"])
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


def evaluate_expectation(result: dict[str, object], expectation: ScenarioExpectation) -> list[str]:
    return expectation.check(result)


def evaluate_expectation_for_round_budget(
    result: dict[str, object],
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

        # Nodes that are no longer running should not accumulate additional
        # committed rounds once the built-in expectation has been reached.
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

    parser = argparse.ArgumentParser(description="Reference simulator for Safe-ABSC.")
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
        help="Emit the full trace as JSON.",
    )
    parser.add_argument(
        "--show-events",
        action="store_true",
        help="Print round/event trace after the summary.",
    )
    parser.add_argument(
        "--trace-mode",
        choices=("full", "event", "windowed"),
        default="full",
        help=(
            "Trace rendering mode for --show-events: "
            "`full` prints every round, `event` prints only interesting rounds, "
            "and `windowed` prints interesting rounds plus nearby context."
        ),
    )
    parser.add_argument(
        "--trace-context",
        type=int,
        default=1,
        help="Context rounds to include on each side when --trace-mode=windowed.",
    )
    parser.add_argument(
        "--show-trace",
        action="store_true",
        help="Print per-node traces after the summary.",
    )
    parser.add_argument(
        "--recording-mode",
        choices=("debug", "eval"),
        default="debug",
        help=(
            "Artifact recording profile. `debug` preserves full round/event traces, "
            "while `eval` keeps only lightweight result state for long-running simulations."
        ),
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
        help="Delay between config installation and dataplane re-entry authorization.",
    )
    parser.add_argument(
        "--app-delivery-delay",
        type=duration_arg,
        default=parse_duration_ns("5us"),
        help="Delay from dataplane commit to application delivery.",
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
        recording_mode=args.recording_mode,
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

    if not args.json and args.recording_mode == "eval" and (args.show_events or args.show_trace):
        print(
            "Note: recording_mode=eval suppresses detailed round and node trace artifacts.",
            flush=True,
        )

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

    if args.show_events:
        print("\nRound trace:")
        print(
            round_trace_text(
                result,
                trace_mode=args.trace_mode,
                trace_context=args.trace_context,
            )
        )

    if args.perf_summary:
        print()
        print(performance_summary_text(result))

    if args.show_trace:
        for node in result["nodes"]:
            print(f"\nTrace for node {node['node_id']}:")
            for entry in node["trace"]:
                print(entry)

    return 1 if failures else 0
