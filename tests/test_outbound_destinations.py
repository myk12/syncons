from __future__ import annotations

from sim.core.node import Node
from sim.core.types import MembershipState


def test_advance_epoch_returns_explicit_outbound_destinations() -> None:
    node = Node(node_id=1, node_count=4)
    node.membership_state = MembershipState.ACTIVE
    node.installed_membership = 0b0111
    node.fast_path_bitmap = 0b0111
    node.installed_membership_epoch = 0
    node.run_id = 7

    outbound0 = node.advance_epoch(0)
    assert outbound0 is not None
    assert outbound0.destinations == (0, 2)
    assert outbound0.packet.run_id == 7
    assert not hasattr(outbound0.packet, "membership_epoch")

    outbound1 = node.advance_epoch(1)
    assert outbound1 is not None
    assert outbound1.destinations == (0, 2)
