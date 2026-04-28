from __future__ import annotations

from dataclasses import dataclass, field

from .node import Node, default_payload
from .types import ControlPlaneModel, ControlPlaneState, Delivery, DeliveryCopy, InstalledConfig, MembershipState, NetworkFaultModel, NodeFaultModel, OutboundPacket, Packet, PayloadFactory


def all_nodes_active(_: int, __: int) -> bool:
    return True


def immediate_delivery(packet: Packet, _: int) -> Delivery:
    return Delivery(deliver_epoch=packet.epoch_id)


def default_control_plane_model(epoch_id: int, node_count: int) -> ControlPlaneState:
    _ = epoch_id
    installed_bitmap = (1 << node_count) - 1
    return ControlPlaneState(
        installed_config=InstalledConfig(
            membership_epoch=0,
            members_bitmap=installed_bitmap,
            run_id=0,
        ),
        node_states={node_id: MembershipState.ACTIVE for node_id in range(node_count)},
    )


@dataclass
class ClusterRun:
    node_count: int
    epochs: int
    network_fault_model: NetworkFaultModel = immediate_delivery
    payload_factory: PayloadFactory = default_payload
    node_fault_model: NodeFaultModel = all_nodes_active
    control_plane_model: ControlPlaneModel = default_control_plane_model

    def __post_init__(self) -> None:
        self.nodes = [Node(node_id=i, node_count=self.node_count, payload_factory=self.payload_factory) for i in range(self.node_count)]
        self.pending: dict[int, list[tuple[int, Packet]]] = {}
        self.event_log: list[str] = []
        self.membership_history: list[dict[str, object]] = []
        self.epoch_trace: list[dict[str, object]] = []

    def _queue_delivery(self, trace_epoch: int, deliver_epoch: int, dst: int, packet: Packet, reason: str) -> None:
        self.pending.setdefault(deliver_epoch, []).append((dst, packet))
        self.event_log.append(
            f"queue packet epoch {packet.epoch_id} node {packet.src_id}->{dst} for epoch {deliver_epoch}: {reason}"
        )
        self.epoch_trace[trace_epoch]["network"].append(
            {
                "kind": "queue",
                "src": packet.src_id,
                "dst": dst,
                "packet_epoch": packet.epoch_id,
                "deliver_epoch": deliver_epoch,
                "run_id": packet.run_id,
                "ack_bitmap": packet.ack_bitmap,
                "reason": reason,
            }
        )

    def _materialize_packet(self, packet: Packet, delivery: Delivery | DeliveryCopy) -> Packet:
        return Packet(
            epoch_id=packet.epoch_id if delivery.packet_epoch_override is None else delivery.packet_epoch_override,
            src_id=packet.src_id,
            run_id=packet.run_id if delivery.run_id_override is None else delivery.run_id_override,
            ack_bitmap=packet.ack_bitmap if delivery.ack_override is None else delivery.ack_override,
            payload=packet.payload if delivery.payload_override is None else delivery.payload_override,
        )

    def schedule_packet(self, outbound: OutboundPacket) -> None:
        packet = outbound.packet
        trace_epoch = packet.epoch_id
        for dst in outbound.destinations:
            delivery = self.network_fault_model(packet, dst)
            if delivery.deliver_epoch is None:
                self.event_log.append(
                    f"drop packet epoch {packet.epoch_id} node {packet.src_id}->{dst}: {delivery.reason}"
                )
                self.epoch_trace[trace_epoch]["network"].append(
                    {
                        "kind": "drop",
                        "src": packet.src_id,
                        "dst": dst,
                        "packet_epoch": packet.epoch_id,
                        "deliver_epoch": None,
                        "run_id": packet.run_id,
                        "ack_bitmap": packet.ack_bitmap,
                        "reason": delivery.reason,
                    }
                )
                continue

            queued = self._materialize_packet(packet, delivery)
            self._queue_delivery(trace_epoch, delivery.deliver_epoch, dst, queued, delivery.reason)
            for extra_epoch in delivery.extra_deliver_epochs:
                self._queue_delivery(trace_epoch, extra_epoch, dst, queued, f"{delivery.reason} [duplicate]")
            for extra_copy in delivery.extra_copies:
                self._queue_delivery(
                    trace_epoch,
                    extra_copy.deliver_epoch,
                    dst,
                    self._materialize_packet(packet, extra_copy),
                    extra_copy.reason,
                )

    def run(self) -> dict[str, object]:
        self.event_log.append(f"=== starting cluster run with {self.node_count} nodes and {self.epochs} epochs ===")
        for epoch_id in range(self.epochs):
            self.event_log.append(f"=== epoch {epoch_id} starts ===")
            control_state = self.control_plane_model(epoch_id, self.node_count)
            epoch_record = {
                "epoch": epoch_id,
                "control": {
                    "membership_epoch": control_state.membership_epoch,
                    "members_bitmap": control_state.installed_membership,
                    "run_id": control_state.run_id,
                    "node_states": {node_id: state.value for node_id, state in control_state.node_states.items()},
                },
                "transitions": [],
                "network": [],
                "node_end_state": [],
            }
            self.epoch_trace.append(epoch_record)
            self.membership_history.append({
                "epoch_id": epoch_id,
                "membership_epoch": control_state.membership_epoch,
                "members_bitmap": control_state.installed_config.members_bitmap,
                "run_id": control_state.installed_config.run_id,
            })

            # First: Process each node's epoch transition
            self.event_log.append(f"--- epoch {epoch_id} transitions ---")
            for node in self.nodes:
                self.event_log.append(f"--- node {node.node_id} epoch {epoch_id} transition ---")
                transition: dict[str, object] = {
                    "node_id": node.node_id,
                    "status_before": node.status.value,
                    "membership_state_before": node.membership_state.value,
                }
                # 1. Poll the control plane. Only explicit transactions mutate node state.
                if node.poll_control_plane(epoch_id=epoch_id, control_state=control_state):
                    self.event_log.append(
                        f"epoch {epoch_id}: node {node.node_id} applied control-plane transaction"
                    )
                    transition["control_plane"] = "applied"
                else:
                    self.event_log.append(
                        f"epoch {epoch_id}: node {node.node_id} observed no control-plane transaction"
                    )
                    transition["control_plane"] = "none"

                # 2. Apply node faults
                if not self.node_fault_model(node.node_id, epoch_id):
                    node.crash(epoch_id)
                    transition["fault"] = "crash"
                else:
                    transition["fault"] = None

                # 3. Advance epoch and schedule packets
                outbound = node.advance_epoch(epoch_id)
                transition["status_after"] = node.status.value
                transition["membership_state_after"] = node.membership_state.value

                # 4. Schedule packet for delivery if it exists
                if outbound is not None:
                    self.event_log.append(
                        f"epoch {epoch_id}: node {node.node_id} intends tx to {outbound.destinations}"
                    )
                    transition["outbound"] = {
                        "destinations": list(outbound.destinations),
                        "run_id": outbound.packet.run_id,
                        "ack_bitmap": outbound.packet.ack_bitmap,
                        "payload": outbound.packet.payload,
                    }
                    self.schedule_packet(outbound)
                else:
                    transition["outbound"] = None
                epoch_record["transitions"].append(transition)

            # Second: Deliver packets scheduled for this epoch
            self.event_log.append(f"--- epoch {epoch_id} deliveries ---")
            deliveries = self.pending.get(epoch_id, [])
            for dst, packet in deliveries:
                self.event_log.append(
                    f"deliver packet epoch {packet.epoch_id} node {packet.src_id}->{dst} for epoch {epoch_id}"
                )
                epoch_record["network"].append(
                    {
                        "kind": "deliver",
                        "src": packet.src_id,
                        "dst": dst,
                        "packet_epoch": packet.epoch_id,
                        "deliver_epoch": epoch_id,
                        "run_id": packet.run_id,
                        "ack_bitmap": packet.ack_bitmap,
                        "reason": "deliver",
                    }
                )
                self.nodes[dst].receive(packet)

            epoch_record["node_end_state"] = [
                node.epoch_debug_snapshot()
                for node in self.nodes
            ]

            self.event_log.append(f"=== epoch {epoch_id} ends ===")

        self.event_log.append(f"=== cluster run ends ===")

        return {
            "node_count": self.node_count,
            "epochs": self.epochs,
            "event_log": self.event_log,
            "epoch_trace": self.epoch_trace,
            "membership_history": self.membership_history,
            "nodes": [node.snapshot() for node in self.nodes],
        }
