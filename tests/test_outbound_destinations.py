from __future__ import annotations

from sim.protocol.node import Node
from sim.protocol.types import MembershipState


def test_advance_round_returns_explicit_outbound_destinations() -> None:
    node = Node(node_id=1, node_count=4)
    node.membership_state = MembershipState.ACTIVE
    node.installed_membership = 0b0111
    node.current_sound_set = 0b0111
    node.installed_membership_epoch = 0
    node.run_id = 7

    result0 = node.advance_round(0)
    assert result0.outbound is not None
    assert result0.outbound.destinations == (0, 2)
    assert result0.outbound.packet.run_id == 7
    assert not hasattr(result0.outbound.packet, "membership_epoch")

    result1 = node.advance_round(1)
    assert result1.outbound is not None
    assert result1.outbound.destinations == (0, 2)
