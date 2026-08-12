from __future__ import annotations

from collections.abc import Callable

from ..protocol.types import Delivery, Packet


def network_perfect(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_asymmetric_loss(packet: Packet, dst: int) -> Delivery:
    if packet.round_id == 0 and packet.src_id == 1 and dst == 2:
        return Delivery(deliver_round=None, reason="asymmetric drop: node 2 misses node 1 in round 0")
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_asymmetric_loss_at(fault_round: int) -> Callable[[Packet, int], Delivery]:
    def model(packet: Packet, dst: int) -> Delivery:
        if packet.round_id == fault_round and packet.src_id == 1 and dst == 2:
            return Delivery(
                deliver_round=None,
                reason=f"asymmetric drop: node 2 misses node 1 in round {fault_round}",
            )
        return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")

    return model


def network_bridge_partition(packet: Packet, dst: int) -> Delivery:
    if packet.round_id == 0 and ((packet.src_id == 1 and dst == 2) or (packet.src_id == 2 and dst == 1)):
        return Delivery(
            deliver_round=None,
            reason="partial split: nodes 1 and 2 do not see each other in round 0",
        )
    return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")


def network_bridge_partition_at(
    fault_round: int,
    *,
    left_partition: tuple[int, ...] = (0, 1),
    right_partition: tuple[int, ...] = (3, 4),
) -> Callable[[Packet, int], Delivery]:
    left = set(left_partition)
    right = set(right_partition)

    def model(packet: Packet, dst: int) -> Delivery:
        if packet.round_id == fault_round and (
            (packet.src_id in left and dst in right)
            or (packet.src_id in right and dst in left)
        ):
            return Delivery(
                deliver_round=None,
                reason=(
                    "partial split: left and right partitions lose direct visibility "
                    f"in round {fault_round}"
                ),
            )
        return Delivery(deliver_round=packet.round_id, reason=f"same-round delivery to node {dst}")

    return model


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


def node2_reboots_under_control_plane_at(crash_round: int) -> Callable[[int, int], bool]:
    def model(node_id: int, round_id: int) -> bool:
        return not (node_id == 2 and round_id == crash_round)

    return model


def staggered_recoverable_crashes(
    crash_schedule: tuple[tuple[int, int], ...] = ((4, 20), (3, 24)),
) -> Callable[[int, int], bool]:
    crash_round_by_node = {node_id: crash_round for node_id, crash_round in crash_schedule}

    def model(node_id: int, round_id: int) -> bool:
        crash_round = crash_round_by_node.get(node_id)
        return crash_round is None or round_id != crash_round

    return model
