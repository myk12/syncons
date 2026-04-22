from __future__ import annotations

from dataclasses import dataclass, field

from .node import Node, default_payload
from .types import ControlPlaneModel, ControlPlaneState, Delivery, DeliveryCopy, InstalledConfig, MembershipState, NetworkFaultModel, NodeFaultModel, Packet, PayloadFactory


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
            approved_incarnations={node_id: 0 for node_id in range(node_count)},
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

    def _queue_delivery(self, deliver_epoch: int, dst: int, packet: Packet, reason: str) -> None:
        self.pending.setdefault(deliver_epoch, []).append((dst, packet))
        self.event_log.append(
            f"queue packet epoch {packet.epoch_id} node {packet.src_id}->{dst} for epoch {deliver_epoch}: {reason}"
        )

    def _materialize_packet(self, packet: Packet, delivery: Delivery | DeliveryCopy) -> Packet:
        return Packet(
            epoch_id=packet.epoch_id if delivery.packet_epoch_override is None else delivery.packet_epoch_override,
            src_id=packet.src_id,
            incarnation_id=packet.incarnation_id if delivery.incarnation_id_override is None else delivery.incarnation_id_override,
            membership_epoch=packet.membership_epoch if delivery.membership_epoch_override is None else delivery.membership_epoch_override,
            ack_bitmap=packet.ack_bitmap if delivery.ack_override is None else delivery.ack_override,
            payload=packet.payload if delivery.payload_override is None else delivery.payload_override,
        )

    def schedule_packet(self, packet: Packet) -> None:
        for dst in range(self.node_count):
            if dst == packet.src_id:
                continue

            delivery = self.network_fault_model(packet, dst)
            if delivery.deliver_epoch is None:
                self.event_log.append(
                    f"drop packet epoch {packet.epoch_id} node {packet.src_id}->{dst}: {delivery.reason}"
                )
                continue

            queued = self._materialize_packet(packet, delivery)
            self._queue_delivery(delivery.deliver_epoch, dst, queued, delivery.reason)
            for extra_epoch in delivery.extra_deliver_epochs:
                self._queue_delivery(extra_epoch, dst, queued, f"{delivery.reason} [duplicate]")
            for extra_copy in delivery.extra_copies:
                self._queue_delivery(
                    extra_copy.deliver_epoch,
                    dst,
                    self._materialize_packet(packet, extra_copy),
                    extra_copy.reason,
                )

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
                    "installed_membership": control_state.installed_membership,
                    "active_membership": control_state.installed_membership,
                    "pending_config": None
                    if control_state.pending_config is None
                    else {
                        "membership_epoch": control_state.pending_config.membership_epoch,
                        "members_bitmap": control_state.pending_config.members_bitmap,
                        "effective_epoch": control_state.pending_config.effective_epoch,
                        "approved_incarnations": dict(sorted(control_state.pending_config.approved_incarnations.items())),
                    },
                    "approved_incarnations": dict(sorted(control_state.approved_incarnations.items())),
                    "node_states": {node_id: state.value for node_id, state in control_state.node_states.items()},
                }
            )
            self.event_log.append(
                f"=== epoch {epoch_id} boundary membership_epoch={control_state.membership_epoch} installed={control_state.installed_membership:0{self.node_count}b} ==="
            )
            for node in self.nodes:
                node.apply_control_plane(epoch_id=epoch_id, control_state=control_state)
                if not self.node_fault_model(node.node_id, epoch_id):
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
