from __future__ import annotations

from dataclasses import dataclass, field

from .node import Node, default_payload
from .types import ActivityModel, ControlPlaneModel, ControlPlaneState, Delivery, FaultModel, MembershipState, Packet, PayloadFactory


def all_nodes_active(_: int, __: int) -> bool:
    return True


def immediate_delivery(packet: Packet, _: int) -> Delivery:
    return Delivery(deliver_epoch=packet.epoch_id)


def default_control_plane_model(epoch_id: int, node_count: int) -> ControlPlaneState:
    _ = epoch_id
    active_bitmap = (1 << node_count) - 1
    return ControlPlaneState(
        membership_epoch=0,
        active_membership=active_bitmap,
        node_states={node_id: MembershipState.ACTIVE for node_id in range(node_count)},
    )


@dataclass
class ClusterRun:
    node_count: int
    epochs: int
    fault_model: FaultModel = immediate_delivery
    payload_factory: PayloadFactory = default_payload
    activity_model: ActivityModel = all_nodes_active
    control_plane_model: ControlPlaneModel = default_control_plane_model

    def __post_init__(self) -> None:
        self.nodes = [Node(node_id=i, node_count=self.node_count, payload_factory=self.payload_factory) for i in range(self.node_count)]
        self.pending: dict[int, list[tuple[int, Packet]]] = {}
        self.event_log: list[str] = []
        self.membership_history: list[dict[str, object]] = []

    def _queue_delivery(self, deliver_epoch: int, dst: int, packet: Packet, reason: str) -> None:
        self.pending.setdefault(deliver_epoch, []).append((dst, packet))
        self.event_log.append(
            f"queue packet epoch {packet.epoch_id} node {packet.src_id}->{dst} for epoch {deliver_epoch}: {reason}"
        )

    def schedule_packet(self, packet: Packet) -> None:
        for dst in range(self.node_count):
            if dst == packet.src_id:
                continue

            delivery = self.fault_model(packet, dst)
            if delivery.deliver_epoch is None:
                self.event_log.append(
                    f"drop packet epoch {packet.epoch_id} node {packet.src_id}->{dst}: {delivery.reason}"
                )
                continue

            queued = Packet(
                epoch_id=packet.epoch_id if delivery.packet_epoch_override is None else delivery.packet_epoch_override,
                src_id=packet.src_id,
                membership_epoch=packet.membership_epoch if delivery.membership_epoch_override is None else delivery.membership_epoch_override,
                ack_bitmap=packet.ack_bitmap if delivery.ack_override is None else delivery.ack_override,
                payload=packet.payload if delivery.payload_override is None else delivery.payload_override,
            )
            self._queue_delivery(delivery.deliver_epoch, dst, queued, delivery.reason)
            for extra_epoch in delivery.extra_deliver_epochs:
                self._queue_delivery(extra_epoch, dst, queued, f"{delivery.reason} [duplicate]")

    def deliver_epoch_packets(self, epoch_id: int) -> None:
        deliveries = self.pending.pop(epoch_id, [])
        for dst, packet in deliveries:
            self.nodes[dst].receive(packet)

    def run(self) -> dict[str, object]:
        for epoch_id in range(self.epochs):
            control_state = self.control_plane_model(epoch_id, self.node_count)
            self.membership_history.append(
                {
                    "epoch": epoch_id,
                    "membership_epoch": control_state.membership_epoch,
                    "active_membership": control_state.active_membership,
                    "node_states": {node_id: state.value for node_id, state in control_state.node_states.items()},
                }
            )
            self.event_log.append(
                f"=== epoch {epoch_id} boundary membership_epoch={control_state.membership_epoch} active={control_state.active_membership:0{self.node_count}b} ==="
            )
            for node in self.nodes:
                node.apply_control_plane(
                    epoch_id=epoch_id,
                    membership_epoch=control_state.membership_epoch,
                    active_membership=control_state.active_membership,
                    membership_state=control_state.node_states.get(node.node_id, MembershipState.FAILED),
                )
                if not self.activity_model(node.node_id, epoch_id):
                    node.crash(epoch_id)
                packet = node.advance_epoch(epoch_id)
                if packet is not None:
                    self.schedule_packet(packet)
            self.deliver_epoch_packets(epoch_id)

        return {
            "node_count": self.node_count,
            "epochs": self.epochs,
            "event_log": self.event_log,
            "membership_history": self.membership_history,
            "nodes": [node.snapshot() for node in self.nodes],
        }
