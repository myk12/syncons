from __future__ import annotations

import copy
from dataclasses import dataclass, field

from ..control.control_plane import OnlineRejoinControlPlane
from ..protocol.node import Node, default_payload
from ..protocol.types import ControlPlaneState, ControlPlaneTransaction, Delivery, DeliveryCopy, MembershipState, NetworkFaultModel, NodeFaultModel, OutboundPacket, Packet, PayloadFactory, RepairSnapshot, SimulationTiming, bitmap_text


def all_nodes_active(_: int, __: int) -> bool:
    return True


def immediate_delivery(packet: Packet, _: int) -> Delivery:
    return Delivery(deliver_round=packet.round_id)

@dataclass
class ClusterRun:
    node_count: int
    rounds: int
    network_fault_model: NetworkFaultModel = immediate_delivery
    payload_factory: PayloadFactory = default_payload
    node_fault_model: NodeFaultModel = all_nodes_active
    timing: SimulationTiming = field(default_factory=SimulationTiming)
    recording_mode: str = "debug"
    record_event_log: bool | None = None
    record_membership_history: bool | None = None
    record_round_trace: bool | None = None
    include_node_traces_in_result: bool | None = None

    def __post_init__(self) -> None:
        profiles = {
            "debug": {
                "record_event_log": True,
                "record_membership_history": True,
                "record_round_trace": True,
                "include_node_traces_in_result": True,
            },
            "eval": {
                "record_event_log": False,
                "record_membership_history": False,
                "record_round_trace": False,
                "include_node_traces_in_result": False,
            },
        }
        if self.recording_mode not in profiles:
            raise ValueError(f"unknown recording_mode: {self.recording_mode}")
        profile = profiles[self.recording_mode]
        if self.record_event_log is None:
            self.record_event_log = profile["record_event_log"]
        if self.record_membership_history is None:
            self.record_membership_history = profile["record_membership_history"]
        if self.record_round_trace is None:
            self.record_round_trace = profile["record_round_trace"]
        if self.include_node_traces_in_result is None:
            self.include_node_traces_in_result = profile["include_node_traces_in_result"]
        self.control_plane = copy.deepcopy(OnlineRejoinControlPlane())
        self.nodes = [Node(node_id=i, node_count=self.node_count, payload_factory=self.payload_factory) for i in range(self.node_count)]
        self.pending: dict[int, list[dict[str, object]]] = {}
        self.event_log: list[str] = []
        self.membership_history: list[dict[str, object]] = []
        self.round_trace: list[dict[str, object]] = []
        self.control_plane_events: list[dict[str, object]] = []
        self._last_control_plane_transactions: dict[int, ControlPlaneTransaction] = {}
        self.control_plane.set_timing(self.timing)
        self.control_plane.set_repair_log_provider(self._repair_log_snapshots)

    def _record_event(self, message: str) -> None:
        if self.record_event_log:
            self.event_log.append(message)

    def _repair_log_snapshots(self) -> list[RepairSnapshot]:
        return [
            RepairSnapshot(
                node_id=node.node_id,
                committed_rounds=tuple(
                    entry.with_timing(commit_time_ns=None, app_delivery_time_ns=None)
                    for entry in node.committed_rounds
                ),
            )
            for node in self.nodes
        ]

    def _record_control_plane_event(self, event: dict[str, object]) -> None:
        self.control_plane_events.append(event)
        self.control_plane.observe_event(event)
        details = ""
        if event["kind"] == "NodeHalted":
            details = f" halt_reason={event['halt_record']['halt_reason']}"
        self._record_event(
            "control-plane event "
            + f"{event['kind']} node={event['node_id']} "
            + f"available_at_ns={event['available_at_ns']}"
            + details
        )

    def _forward_node_control_plane_events(self, node: Node, round_id: int, round_start_ns: int) -> None:
        # Nodes emit logical control-plane events into a local outbox. ClusterRun
        # is the only component allowed to timestamp and forward them to the
        # control-plane actor.
        forwarded_events: list[dict[str, object]] = []
        for event in node.drain_control_plane_events():
            forwarded = dict(event)
            forwarded.setdefault("node_id", node.node_id)
            forwarded["round"] = round_id
            if forwarded["kind"] in {"NodeHalted", "NodeCrashed"}:
                forwarded["available_at_ns"] = round_start_ns + self.timing.halt_report_delay_ns
            else:
                forwarded["available_at_ns"] = round_start_ns
            self._record_control_plane_event(forwarded)
            forwarded_events.append(forwarded)
        return forwarded_events

    def _build_control_plane_transaction(
        self,
        node_id: int,
        control_state: ControlPlaneState,
    ) -> ControlPlaneTransaction:
        # Build the per-node mailbox view. This is intentionally an aggregated
        # transaction snapshot for the preliminary prototype, not a lower-level
        # register-by-register command encoding.
        return ControlPlaneTransaction(
            installed_config=control_state.installed_config,
            membership_state=control_state.node_states.get(node_id, MembershipState.FAILED),
            pending_config=control_state.pending_config,
            repair_log=control_state.repair_logs.get(node_id),
        )

    def _write_control_plane_transactions(
        self,
        round_id: int,
        control_state: ControlPlaneState,
    ) -> None:
        # Only write the mailbox when the per-node transaction actually changes.
        # Nodes then consume that write at round start via a control-plane IRQ.
        for node in self.nodes:
            transaction = self._build_control_plane_transaction(node.node_id, control_state)
            if self._last_control_plane_transactions.get(node.node_id) == transaction:
                continue
            node.write_control_plane_transaction(transaction)
            self._last_control_plane_transactions[node.node_id] = transaction
            pending_status = "none"
            if transaction.pending_config is not None:
                pending_status = (
                    f"{transaction.pending_config.status.value}"
                    f"@{transaction.pending_config.effective_round}"
                )
            write_record = {
                "node_id": node.node_id,
                "membership_state": transaction.membership_state.value,
                "membership_epoch": transaction.installed_config.membership_epoch,
                "members_bitmap": transaction.installed_config.members_bitmap,
                "run_id": transaction.installed_config.run_id,
                "pending": pending_status,
                "repair_log_len": 0 if transaction.repair_log is None else len(transaction.repair_log),
            }
            self._record_event(
                "control-plane write "
                + f"round {round_id} node={node.node_id} "
                + f"membership_state={transaction.membership_state.value} "
                + f"members={bitmap_text(transaction.installed_config.members_bitmap, self.node_count)} "
                + f"run_id={transaction.installed_config.run_id} "
                + f"pending={pending_status}"
            )
            if self.record_round_trace and round_id < len(self.round_trace):
                self.round_trace[round_id]["control_plane_writes"].append(write_record)

    def _queue_pending_packet(
        self,
        *,
        trace_round: int,
        deliver_round: int,
        dst: int,
        packet: Packet,
        reason: str,
        fault_applied: bool,
        kind: str,
    ) -> None:
        self.pending.setdefault(deliver_round, []).append(
            {
                "dst": dst,
                "packet": packet,
                "fault_applied": fault_applied,
            }
        )
        self._record_event(
            f"{kind} packet round {packet.round_id} node {packet.src_id}->{dst} for round {deliver_round}: {reason}"
        )
        if self.record_round_trace and trace_round < len(self.round_trace):
            self.round_trace[trace_round]["network"].append(
                {
                    "kind": kind,
                    "src": packet.src_id,
                    "dst": dst,
                    "packet_round": packet.round_id,
                    "deliver_round": deliver_round,
                    "run_id": packet.run_id,
                    "sound_bitmap": packet.sound_bitmap,
                    "reason": reason,
                }
            )

    def _materialize_packet(self, packet: Packet, delivery: Delivery | DeliveryCopy) -> Packet:
        return Packet(
            round_id=packet.round_id if delivery.packet_round_override is None else delivery.packet_round_override,
            src_id=packet.src_id,
            run_id=packet.run_id if delivery.run_id_override is None else delivery.run_id_override,
            sound_bitmap=packet.sound_bitmap if delivery.sound_override is None else delivery.sound_override,
            payload=packet.payload if delivery.payload_override is None else delivery.payload_override,
        )

    def _enqueue_outbound_packet(self, outbound: OutboundPacket) -> None:
        packet = outbound.packet
        trace_round = packet.round_id
        for dst in outbound.destinations:
            self._queue_pending_packet(
                trace_round=trace_round,
                deliver_round=packet.round_id,
                dst=dst,
                packet=packet,
                reason="sender enqueued packet",
                fault_applied=False,
                kind="send",
            )

    def _process_round_deliveries(self, round_id: int, round_record: dict[str, object]) -> None:
        deliveries = self.pending.pop(round_id, [])
        idx = 0
        while idx < len(deliveries):
            item = deliveries[idx]
            idx += 1
            dst = int(item["dst"])
            packet = item["packet"]
            fault_applied = bool(item["fault_applied"])

            if not fault_applied:
                delivery = self.network_fault_model(packet, dst)
                if delivery.deliver_round is None:
                    self._record_event(
                        f"drop packet round {packet.round_id} node {packet.src_id}->{dst}: {delivery.reason}"
                    )
                    round_record["network"].append(
                        {
                            "kind": "drop",
                            "src": packet.src_id,
                            "dst": dst,
                            "packet_round": packet.round_id,
                            "deliver_round": None,
                            "run_id": packet.run_id,
                            "sound_bitmap": packet.sound_bitmap,
                            "reason": delivery.reason,
                        }
                    )
                    continue

                materialized = self._materialize_packet(packet, delivery)
                target_round = int(delivery.deliver_round)

                if target_round > round_id:
                    self._queue_pending_packet(
                        trace_round=round_id,
                        deliver_round=target_round,
                        dst=dst,
                        packet=materialized,
                        reason=delivery.reason,
                        fault_applied=True,
                        kind="delay",
                    )
                else:
                    deliveries.append(
                        {
                            "dst": dst,
                            "packet": materialized,
                            "fault_applied": True,
                        }
                    )

                for extra_round in delivery.extra_deliver_rounds:
                    self._queue_pending_packet(
                        trace_round=round_id,
                        deliver_round=extra_round,
                        dst=dst,
                        packet=materialized,
                        reason=f"{delivery.reason} [duplicate]",
                        fault_applied=True,
                        kind="delay" if extra_round > round_id else "send",
                    )
                for extra_copy in delivery.extra_copies:
                    copied = self._materialize_packet(packet, extra_copy)
                    extra_round = int(extra_copy.deliver_round)
                    if extra_round > round_id:
                        self._queue_pending_packet(
                            trace_round=round_id,
                            deliver_round=extra_round,
                            dst=dst,
                            packet=copied,
                            reason=extra_copy.reason,
                            fault_applied=True,
                            kind="delay",
                        )
                    else:
                        deliveries.append(
                            {
                                "dst": dst,
                                "packet": copied,
                                "fault_applied": True,
                            }
                        )
                continue

            self._record_event(
                f"deliver packet round {packet.round_id} node {packet.src_id}->{dst} for round {round_id}"
            )
            round_record["network"].append(
                {
                    "kind": "deliver",
                    "src": packet.src_id,
                    "dst": dst,
                    "packet_round": packet.round_id,
                    "deliver_round": round_id,
                    "run_id": packet.run_id,
                    "sound_bitmap": packet.sound_bitmap,
                    "reason": "deliver",
                }
            )
            self.nodes[dst].receive(packet)
    ###############################################################################
    ##                  S I M U L A T I O N   R U N   L O G I C                  ##
    ###############################################################################
    def run(self) -> dict[str, object]:
        self._record_event(f"=== starting cluster run with {self.node_count} nodes and {self.rounds} rounds ===")
        for round_id in range(self.rounds):
            self._record_event(f"=== round {round_id} starts ===")

            # Compute round start and end time for control plane and event logging purposes
            round_start_ns = round_id * self.timing.round_length_ns
            round_end_ns = round_start_ns + self.timing.round_length_ns

            # Advance control plane and record state
            self.control_plane.advance_to_time(round_start_ns, self.node_count)
            control_state = self.control_plane(round_id, self.node_count)
            round_record = {
                "round": round_id,
                "start_time_ns": round_start_ns,
                "end_time_ns": round_end_ns,
                "control": {
                    "membership_epoch": control_state.membership_epoch,
                    "members_bitmap": control_state.installed_membership,
                    "run_id": control_state.run_id,
                    "node_states": {node_id: state.value for node_id, state in control_state.node_states.items()},
                },
                "control_plane_runtime": {},
                "control_plane_writes": [],
                "control_plane_events": [],
                "transitions": [],
                "network": [],
                "node_end_state": [],
            }
            if self.record_round_trace:
                self.round_trace.append(round_record)
            self._write_control_plane_transactions(round_id, control_state)
            cp_debug = self.control_plane.debug_snapshot()
            if self.record_round_trace:
                round_record["control_plane_runtime"] = {
                    "collection_deadline_ns": cp_debug.get("collection_deadline_ns"),
                    "collecting_targets": list(cp_debug.get("collecting_targets", [])),
                    "episode_targets": list(cp_debug.get("episode_targets", [])),
                    "episode_members_bitmap": cp_debug.get("episode_members_bitmap"),
                    "pending_future": cp_debug.get("pending_future"),
                }
            if self.record_membership_history:
                self.membership_history.append({
                    "round_id": round_id,
                    "membership_epoch": control_state.membership_epoch,
                    "members_bitmap": control_state.installed_config.members_bitmap,
                    "run_id": control_state.installed_config.run_id,
                })

            # Process each node's round transition
            self._record_event(f"--- round {round_id} transitions ---")
            for node in self.nodes:
                self._record_event(f"--- node {node.node_id} round {round_id} transition ---")
                transition: dict[str, object] = {
                    "node_id": node.node_id,
                    "status_before": node.status.value,
                    "membership_state_before": node.membership_state.value,
                }
                committed_before = len(node.committed_rounds)

                # 2. Apply node faults
                if not self.node_fault_model(node.node_id, round_id):
                    node.crash(round_id)
                    transition["fault"] = "crash"
                else:
                    transition["fault"] = None

                # 3. Advance the node using the round-start control-plane
                # mailbox snapshot already written for this round.
                outbound = node.advance_round(round_id)
                transition["control_plane"] = node.last_control_plane_action
                transition["control_plane_details"] = list(node.last_control_plane_details)
                transition["status_after"] = node.status.value
                transition["membership_state_after"] = node.membership_state.value
                if len(node.committed_rounds) > committed_before:
                    for index in range(committed_before, len(node.committed_rounds)):
                        entry = node.committed_rounds[index]
                        node.committed_rounds[index] = entry.with_timing(
                            commit_time_ns=round_start_ns,
                            app_delivery_time_ns=round_start_ns + self.timing.app_delivery_delay_ns,
                        )

                round_record["control_plane_events"].extend(
                    self._forward_node_control_plane_events(node, round_id, round_start_ns)
                )

                # 4. Schedule packet for delivery if it exists
                if outbound is not None:
                    self._record_event(
                        f"round {round_id}: node {node.node_id} intends tx to {outbound.destinations}"
                    )
                    transition["outbound"] = {
                        "destinations": list(outbound.destinations),
                        "run_id": outbound.packet.run_id,
                        "sound_bitmap": outbound.packet.sound_bitmap,
                        "payload": outbound.packet.payload,
                    }
                    self._enqueue_outbound_packet(outbound)
                else:
                    transition["outbound"] = None
                if self.record_round_trace:
                    round_record["transitions"].append(transition)

            # Second: Deliver packets scheduled for this round
            self._record_event(f"--- round {round_id} deliveries ---")
            self._process_round_deliveries(round_id, round_record)

            if self.record_round_trace:
                round_record["node_end_state"] = [
                    node.round_debug_snapshot()
                    for node in self.nodes
                ]

            self._record_event(f"=== round {round_id} ends ===")

        self._record_event(f"=== cluster run ends ===")

        return {
            "node_count": self.node_count,
            "rounds": self.rounds,
            "simulated_time_ns": self.rounds * self.timing.round_length_ns,
            "timing": {
                "round_length_ns": self.timing.round_length_ns,
                "halt_report_delay_ns": self.timing.halt_report_delay_ns,
                "cp_collection_delay_ns": self.timing.cp_collection_delay_ns,
                "cp_decision_delay_ns": self.timing.cp_decision_delay_ns,
                "repair_delay_ns": self.timing.repair_delay_ns,
                "install_delay_ns": self.timing.install_delay_ns,
                "reentry_delay_ns": self.timing.reentry_delay_ns,
                "app_delivery_delay_ns": self.timing.app_delivery_delay_ns,
            },
            "event_log": self.event_log,
            "control_plane_events": self.control_plane_events,
            "control_plane_runtime": self.control_plane.debug_snapshot(),
            "round_trace": self.round_trace,
            "membership_history": self.membership_history,
            "nodes": [
                node.snapshot(include_trace=self.include_node_traces_in_result)
                for node in self.nodes
            ],
        }
