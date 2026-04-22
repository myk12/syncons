from __future__ import annotations

from .types import ControlPlaneState, Delivery, DeliveryCopy, InstalledConfig, MembershipState, Packet, bitmap_set


def _approved_incarnations(node_count: int, overrides: dict[int, int] | None = None) -> dict[int, int]:
    approved = {node_id: 0 for node_id in range(node_count)}
    if overrides is not None:
        approved.update(overrides)
    return approved


def network_perfect(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_asymmetric_loss(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 0 and packet.src_id == 1 and dst == 2:
        return Delivery(deliver_epoch=None, reason="asymmetric drop: node 2 misses node 1 in epoch 0")
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_one_epoch_delay(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 1 and packet.src_id == 2 and dst == 0:
        return Delivery(deliver_epoch=2, reason="one-epoch delay from node 2 to node 0")
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_quorum_loss(packet: Packet, dst: int) -> Delivery:
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_stale_replay(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 0 and packet.src_id == 1 and dst == 0:
        return Delivery(
            deliver_epoch=0,
            extra_deliver_epochs=(2,),
            reason="same-epoch delivery with stale replay at epoch 2",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_duplicate_same_epoch(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 1 and packet.src_id == 0 and dst == 2:
        return Delivery(
            deliver_epoch=1,
            extra_deliver_epochs=(1,),
            reason="duplicate same-epoch delivery from node 0 to node 2",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_future_epoch_skew(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 0 and packet.src_id == 2 and dst in (0, 1):
        return Delivery(
            deliver_epoch=0,
            packet_epoch_override=1,
            reason="clock skew: node 2 labels its epoch-0 packet as epoch 1",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_ack_bitmap_corruption(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 1 and packet.src_id == 1 and dst == 2:
        return Delivery(
            deliver_epoch=1,
            ack_override=0b011,
            reason="boundary fault: node 2 receives a corrupted ACK bitmap from node 1 in epoch 1",
        )
    return Delivery(deliver_epoch=packet.epoch_id, reason=f"same-epoch delivery to node {dst}")


def network_stale_incarnation_replay(packet: Packet, dst: int) -> Delivery:
    if packet.epoch_id == 5 and packet.src_id == 2 and packet.incarnation_id == 1 and dst == 0:
        return Delivery(
            deliver_epoch=packet.epoch_id,
            reason=f"same-epoch delivery to node {dst}",
            extra_copies=(
                DeliveryCopy(
                    deliver_epoch=5,
                    incarnation_id_override=0,
                    reason="replay old-incarnation packet from node 2 after rejoin",
                ),
            ),
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
    installed_membership = bitmap_set(node_count, *range(node_count))
    return ControlPlaneState(
        installed_config=InstalledConfig(
            membership_epoch=0,
            members_bitmap=installed_membership,
            approved_incarnations=_approved_incarnations(node_count),
        ),
        node_states={node_id: MembershipState.ACTIVE for node_id in range(node_count)},
    )


def control_plane_node2_removed(epoch_id: int, node_count: int) -> ControlPlaneState:
    if epoch_id == 0:
        return control_plane_all_active(epoch_id, node_count)
    installed_membership = bitmap_set(node_count, *[node_id for node_id in range(node_count) if node_id != 2])
    return ControlPlaneState(
        installed_config=InstalledConfig(
            membership_epoch=1,
            members_bitmap=installed_membership,
            approved_incarnations=_approved_incarnations(node_count),
        ),
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
        installed_config=InstalledConfig(
            membership_epoch=0,
            members_bitmap=bitmap_set(node_count, 0, 1, 2),
            approved_incarnations=_approved_incarnations(node_count),
        ),
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
            installed_config=InstalledConfig(
                membership_epoch=1,
                members_bitmap=bitmap_set(node_count, 0, 1),
                approved_incarnations=_approved_incarnations(node_count),
            ),
            node_states={
                0: MembershipState.ACTIVE,
                1: MembershipState.ACTIVE,
                2: MembershipState.FAILED,
            },
        )
    if epoch_id == 2:
        return ControlPlaneState(
            installed_config=InstalledConfig(
                membership_epoch=1,
                members_bitmap=bitmap_set(node_count, 0, 1),
                approved_incarnations=_approved_incarnations(node_count),
            ),
            node_states={
                0: MembershipState.ACTIVE,
                1: MembershipState.ACTIVE,
                2: MembershipState.RECOVERING,
            },
        )
    if epoch_id == 3:
        return ControlPlaneState(
            installed_config=InstalledConfig(
                membership_epoch=1,
                members_bitmap=bitmap_set(node_count, 0, 1),
                approved_incarnations=_approved_incarnations(node_count),
            ),
            node_states={
                0: MembershipState.ACTIVE,
                1: MembershipState.ACTIVE,
                2: MembershipState.REJOIN_PENDING,
            },
        )
    return ControlPlaneState(
        installed_config=InstalledConfig(
            membership_epoch=2,
            members_bitmap=bitmap_set(node_count, 0, 1, 2),
            approved_incarnations=_approved_incarnations(node_count, overrides={2: 1}),
        ),
        node_states={
            0: MembershipState.ACTIVE,
            1: MembershipState.ACTIVE,
            2: MembershipState.ACTIVE,
        },
    )
