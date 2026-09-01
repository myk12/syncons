from __future__ import annotations

import copy
from dataclasses import dataclass, field

from ..control.control_plane import OnlineRejoinControlPlane
from ..protocol.node import Node, default_payload
from ..protocol.types import CommittedRoundRecord, ControlPlaneState, ControlPlaneUpdate, Delivery, DeliveryCopy, JsonDict, MembershipState, NetworkFaultModel, NodeFaultModel, OutboundPacket, Packet, PayloadFactory, RepairSnapshot, SimulationTiming
from ..runtime.metrics import MetricsSink, NoOpMetricsSink, RoundSummary


def all_nodes_active(_: int, __: int) -> bool:
    return True


def immediate_delivery(packet: Packet, _: int) -> Delivery:
    return Delivery(deliver_round=packet.round_id)

@dataclass
class ClusterRun:
    # Simulation parameters.
    node_count: int
    rounds: int
    timing: SimulationTiming = field(default_factory=SimulationTiming)  # timing parameters for the control plane and network
    payload_factory: PayloadFactory = default_payload

    # Fault models for the network and nodes.
    network_fault_model: NetworkFaultModel = immediate_delivery
    node_fault_model: NodeFaultModel = all_nodes_active

    # Sink for observing round completions.
    metrics_sink: MetricsSink = field(default_factory=NoOpMetricsSink)

    def __post_init__(self) -> None:
        # Control plane
        self.control_plane = copy.deepcopy(OnlineRejoinControlPlane())

        self.nodes = [
            Node(
                node_id=i,
                node_count=self.node_count,
                payload_factory=self.payload_factory,
            )
            for i in range(self.node_count)
        ]

        self.scheduled_deliveries: dict[int, list[JsonDict]] = {}
        self.control_plane_events: list[JsonDict] = []
        self.commit_history_by_node: dict[int, list[CommittedRoundRecord]] = {
            node_id: [] for node_id in range(self.node_count)
        }
        self._last_control_plane_updates: dict[int, ControlPlaneUpdate] = {}
        self.control_plane.set_timing(self.timing)
        self.control_plane.set_repair_snapshot_source(self._repair_log_snapshots)

    def _repair_log_snapshots(self) -> list[RepairSnapshot]:
        return [
            RepairSnapshot(
                node_id=node_id,
                committed_rounds=tuple(
                    entry.with_timing(commit_time_ns=None, app_delivery_time_ns=None)
                    for entry in self.commit_history_by_node[node_id]
                ),
            )
            for node_id in sorted(self.commit_history_by_node)
        ]

    def _submit_control_plane_event(self, event: JsonDict) -> None:
        self.control_plane_events.append(event)
        self.control_plane.observe_event(event)

    def _pull_node_control_plane_events(self, node: Node, round_id: int, round_start_ns: int) -> None:
        # Nodes emit logical control-plane events into a local outbox. ClusterRun
        # is the only component allowed to timestamp and forward them to the
        # control-plane actor.
        for event in node.pull_control_plane_events():
            forwarded = dict(event)
            forwarded.setdefault("node_id", node.node_id)
            forwarded["round"] = round_id
            if forwarded["kind"] in {"NodeHalted", "NodeCrashed"}:
                forwarded["available_at_ns"] = round_start_ns + self.timing.halt_report_delay_ns
            else:
                forwarded["available_at_ns"] = round_start_ns
            self._submit_control_plane_event(forwarded)

    def _build_control_plane_update(
        self,
        node_id: int,
        control_state: ControlPlaneState,
    ) -> ControlPlaneUpdate:
        # Build the per-node control-plane view as an aggregated update rather
        # than a lower-level register-by-register command encoding.
        return ControlPlaneUpdate(
            installed_config=control_state.installed_config,
            membership_state=control_state.node_states.get(node_id, MembershipState.FAILED),
            pending_config=control_state.pending_config,
            repair_log=control_state.repair_logs.get(node_id),
        )

    def _push_control_plane_updates(
        self,
        control_state: ControlPlaneState,
    ) -> None:
        # Only push the per-node control-plane update when it actually changes.
        # Nodes then pull and apply that update at round start via a logical IRQ.
        for node in self.nodes:
            update = self._build_control_plane_update(node.node_id, control_state)
            if self._last_control_plane_updates.get(node.node_id) == update:
                continue
            if update.repair_log is not None:
                self.commit_history_by_node[node.node_id] = list(update.repair_log.entries)
            node.push_control_plane_update(update)
            self._last_control_plane_updates[node.node_id] = update

    def _schedule_packet_delivery(
        self,
        deliver_round: int,
        dst: int,
        packet: Packet,
        fault_applied: bool,
    ) -> None:
        self.scheduled_deliveries.setdefault(deliver_round, []).append(
            {
                "dst": dst,
                "packet": packet,
                "fault_applied": fault_applied,
            }
        )

    def _materialize_packet(self, packet: Packet, delivery: Delivery | DeliveryCopy) -> Packet:
        return Packet(
            round_id=packet.round_id if delivery.packet_round_override is None else delivery.packet_round_override,
            src_id=packet.src_id,
            run_id=packet.run_id if delivery.run_id_override is None else delivery.run_id_override,
            row=packet.row if delivery.row_override is None else delivery.row_override,
            payload=packet.payload if delivery.payload_override is None else delivery.payload_override,
        )

    def _schedule_outbound_packet(self, outbound: OutboundPacket) -> None:
        packet = outbound.packet
        for dst in outbound.destinations:
            self._schedule_packet_delivery(
                deliver_round=packet.round_id,
                dst=dst,
                packet=packet,
                fault_applied=False,
            )

    def _advance_network(self, round_id: int) -> None:
        deliveries = self.scheduled_deliveries.pop(round_id, [])
        idx = 0
        while idx < len(deliveries):
            item = deliveries[idx]
            idx += 1
            dst = int(item["dst"])
            packet = item["packet"]
            fault_applied = bool(item["fault_applied"])

            if not fault_applied:
                # Apply the network fault model to determine if and when the packet should be delivered.
                delivery = self.network_fault_model(packet, dst)
                if delivery.deliver_round is None:
                    continue

                materialized = self._materialize_packet(packet, delivery)
                target_round = int(delivery.deliver_round)

                if target_round > round_id:
                    self._schedule_packet_delivery(
                        deliver_round=target_round,
                        dst=dst,
                        packet=materialized,
                        fault_applied=True,
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
                    self._schedule_packet_delivery(
                        deliver_round=extra_round,
                        dst=dst,
                        packet=materialized,
                        fault_applied=True,
                    )
                for extra_copy in delivery.extra_copies:
                    copied = self._materialize_packet(packet, extra_copy)
                    extra_round = int(extra_copy.deliver_round)
                    if extra_round > round_id:
                        self._schedule_packet_delivery(
                            deliver_round=extra_round,
                            dst=dst,
                            packet=copied,
                            fault_applied=True,
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

            self.nodes[dst].receive(packet)

    ###############################################################################
    ##                  S I M U L A T I O N   R U N   L O G I C                  ##
    ###############################################################################
    def run(self) -> JsonDict:
        for round_id in range(self.rounds):
            round_start_ns = round_id * self.timing.round_length_ns
            committed_commands_this_round: set[str] = set()

            self.control_plane.advance_to_time(round_start_ns, self.node_count)
            control_state = self.control_plane(round_id, self.node_count)
            self._push_control_plane_updates(control_state)

            # Advance each node and collect their emitted control-plane events and new commits.
            for node in self.nodes:
                # Apply node fault model
                if not self.node_fault_model(node.node_id, round_id):
                    node.crash(round_id)

                # Advance the node's state machine
                round_result = node.advance_round(round_id)
                if round_result.new_commits:
                    timed_entries = tuple(
                        CommittedRoundRecord.from_committed_round(
                            entry,
                            commit_time_ns=round_start_ns,
                            app_delivery_time_ns=round_start_ns + self.timing.app_delivery_delay_ns,
                        )
                        for entry in round_result.new_commits
                    )
                    self.commit_history_by_node[node.node_id].extend(timed_entries)
                    for entry in timed_entries:
                        committed_commands_this_round.update(entry.proposals.values())

                # Forward any control-plane events emitted by the node during its round advancement.
                self._pull_node_control_plane_events(node, round_id, round_start_ns)

                # Enqueue any outbound packets emitted by the node during its round advancement
                if round_result.outbound is not None:
                    self._schedule_outbound_packet(round_result.outbound)

            # After processing all nodes for this round, advance the network to materialize any 
            # in-flight packets that are due for delivery.
            self._advance_network(round_id)

            # Record round summary for metrics collection.
            self.metrics_sink.on_round_complete(
                RoundSummary(
                    round_id=round_id,
                    start_time_ns=round_start_ns,
                    end_time_ns=round_start_ns + self.timing.round_length_ns,
                    committed_txns=len(committed_commands_this_round),
                )
            )

        # Final snapshot of the cluster state after the run completes.
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
            "control_plane_events": self.control_plane_events,
            "control_plane_runtime": self.control_plane.debug_snapshot(),
            "nodes": [
                {
                    **node.snapshot(),
                    "committed_rounds": [
                        entry.to_snapshot()
                        for entry in self.commit_history_by_node[node.node_id]
                    ],
                }
                for node in self.nodes
            ],
        }
