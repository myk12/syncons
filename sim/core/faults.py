from __future__ import annotations

from .types import ControlPlaneState, Delivery, MembershipState, Packet, bitmap_set


def scenario_perfect(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_node2_crash_after_epoch0(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_asymmetric_loss(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 0 and packet.src_id == 1 and dst == 2:
        return Delivery(deliver_epoch=None, reason="asymmetric drop: node 2 misses node 1 in epoch 0")
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_one_epoch_delay(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 1 and packet.src_id == 2 and dst == 0:
        return Delivery(deliver_epoch=2, reason="one-epoch delay from node 2 to node 0")
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_quorum_loss(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_stale_replay(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 0 and packet.src_id == 1 and dst == 0:
        return Delivery(
            deliver_epoch=0,
            extra_deliver_epochs=(2,),
            reason="same-epoch delivery with stale replay at epoch 2",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_duplicate_same_epoch(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 1 and packet.src_id == 0 and dst == 2:
        return Delivery(
            deliver_epoch=1,
            extra_deliver_epochs=(1,),
            reason="duplicate same-epoch delivery from node 0 to node 2",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_future_epoch_skew(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 0 and packet.src_id == 2 and dst in (0, 1):
        return Delivery(
            deliver_epoch=0,
            packet_epoch_override=1,
            reason="clock skew: node 2 labels its epoch-0 packet as epoch 1",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def scenario_ack_bitmap_corruption(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 1 and packet.src_id == 1 and dst == 2:
        return Delivery(
            deliver_epoch=1,
            ack_override=0b011,
            reason="boundary fault: node 2 receives a corrupted ACK bitmap from node 1 in epoch 1",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def all_nodes_active(_: int, __: int) -> bool:
    return True


def node2_crashes_after_epoch0(node_id: int, epoch_id: int) -> bool:
    return not (node_id == 2 and epoch_id >= 1)


def nodes1and2_crash_after_epoch0(node_id: int, epoch_id: int) -> bool:
    return not (node_id in (1, 2) and epoch_id >= 1)


def node2_reboots_under_control_plane(node_id: int, epoch_id: int) -> bool:
    return not (node_id == 2 and epoch_id == 1)


def control_plane_all_active(epoch_id: int, node_count: int) -> ControlPlaneState:
    _ = epoch_id
    active_membership = bitmap_set(node_count, *range(node_count))
    return ControlPlaneState(
        membership_epoch=0,
        active_membership=active_membership,
        node_states={node_id: MembershipState.ACTIVE for node_id in range(node_count)},
    )


def control_plane_node2_removed(epoch_id: int, node_count: int) -> ControlPlaneState:
    if epoch_id == 0:
        return control_plane_all_active(epoch_id, node_count)
    active_membership = bitmap_set(node_count, *[node_id for node_id in range(node_count) if node_id != 2])
    return ControlPlaneState(
        membership_epoch=1,
        active_membership=active_membership,
        node_states={
            0: MembershipState.ACTIVE,
            1: MembershipState.ACTIVE,
            2: MembershipState.FAILED,
        },
    )


def control_plane_quorum_loss(epoch_id: int, node_count: int) -> ControlPlaneState:
    if epoch_id == 0:
        return control_plane_all_active(epoch_id, node_count)
    return ControlPlaneState(
        membership_epoch=0,
        active_membership=bitmap_set(node_count, 0, 1, 2),
        node_states={
            0: MembershipState.ACTIVE,
            1: MembershipState.FAILED,
            2: MembershipState.FAILED,
        },
    )


def control_plane_node2_rejoin(epoch_id: int, node_count: int) -> ControlPlaneState:
    if epoch_id == 0:
        return control_plane_all_active(epoch_id, node_count)
    if epoch_id == 1:
        return ControlPlaneState(
            membership_epoch=1,
            active_membership=bitmap_set(node_count, 0, 1),
            node_states={
                0: MembershipState.ACTIVE,
                1: MembershipState.ACTIVE,
                2: MembershipState.FAILED,
            },
        )
    if epoch_id == 2:
        return ControlPlaneState(
            membership_epoch=1,
            active_membership=bitmap_set(node_count, 0, 1),
            node_states={
                0: MembershipState.ACTIVE,
                1: MembershipState.ACTIVE,
                2: MembershipState.RECOVERING,
            },
        )
    if epoch_id == 3:
        return ControlPlaneState(
            membership_epoch=1,
            active_membership=bitmap_set(node_count, 0, 1),
            node_states={
                0: MembershipState.ACTIVE,
                1: MembershipState.ACTIVE,
                2: MembershipState.REJOIN_PENDING,
            },
        )
    return ControlPlaneState(
        membership_epoch=2,
        active_membership=bitmap_set(node_count, 0, 1, 2),
        node_states={
            0: MembershipState.ACTIVE,
            1: MembershipState.ACTIVE,
            2: MembershipState.ACTIVE,
        },
    )
