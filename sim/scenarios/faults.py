from __future__ import annotations

from ..protocol.types import Delivery, Packet


def network_perfect(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_asymmetric_loss(packet: Packet, dst: int) -> Delivery:
    if packet.round_id == 0 and packet.src_id == 1 and dst == 2:
        return Delivery(deliver_round=None, reason="asymmetric drop: node 2 misses node 1 in round 0")
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_bridge_partition(packet: Packet, dst: int) -> Delivery:
    if packet.round_id == 0 and ((packet.src_id == 1 and dst == 2) or (packet.src_id == 2 and dst == 1)):
        return Delivery(
            deliver_round=None,
            reason="bridge partition: nodes 1 and 2 do not see each other in round 0",
        )
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_one_round_delay(packet: Packet, dst: int) -> Delivery:
    if packet.round_id == 1 and packet.src_id == 2 and dst == 0:
        return Delivery(deliver_round=2, reason="one-round delay from node 2 to node 0")
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_quorum_loss(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_future_round_skew(packet: Packet, dst: int) -> Delivery:
    if packet.round_id == 0 and packet.src_id == 2 and dst in (0, 1):
        return Delivery(
            deliver_round=0,
            packet_round_override=1,
            reason="clock skew: node 2 labels its round-0 packet as round 1",
        )
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_sound_bitmap_corruption(packet: Packet, dst: int) -> Delivery:
    if packet.round_id == 1 and packet.src_id == 1 and dst == 2:
        return Delivery(
            deliver_round=1,
            sound_override=0b011,
            reason="boundary fault: node 2 receives a corrupted sound bitmap from node 1 in round 1",
        )
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def all_nodes_active(_: int, __: int) -> bool:
    return True


def node2_crashes_after_round0(node_id: int, round_id: int) -> bool:
    return not (node_id == 2 and round_id >= 1)


def nodes1and2_crash_after_round0(node_id: int, round_id: int) -> bool:
    return not (node_id in (1, 2) and round_id >= 1)


def node2_reboots_under_control_plane(node_id: int, round_id: int) -> bool:
    return not (node_id == 2 and round_id == 1)
