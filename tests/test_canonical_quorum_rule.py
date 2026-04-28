from __future__ import annotations

import pytest

from sim.core.node import Node
from sim.core.types import EpochStage


def stage(rows: dict[int, int], *, node_count: int = 3) -> EpochStage:
    return EpochStage(
        epoch_id=0,
        membership_epoch=0,
        membership_bitmap=(1 << node_count) - 1,
        my_bitmap=1,
        ack_matrix=rows,
    )


def full_membership(node_count: int) -> int:
    return (1 << node_count) - 1


@pytest.mark.parametrize(
    ("node_id", "rows", "expected"),
    [
        (0, {0: 0b111, 1: 0b111, 2: 0b111}, 0b111),
        (0, {0: 0b011, 1: 0b011, 2: 0b000}, 0b011),
        (0, {0: 0b101, 1: 0b000, 2: 0b101}, 0b101),
        (1, {0: 0b000, 1: 0b110, 2: 0b110}, 0b110),
    ],
)
def test_three_node_canonical_clean_shapes(
    node_id: int,
    rows: dict[int, int],
    expected: int,
) -> None:
    node = Node(node_id=node_id, node_count=3)

    assert node._candidate_quorum(stage(rows)) == expected


@pytest.mark.parametrize(
    ("node_id", "rows"),
    [
        (0, {0: 0b111, 1: 0b110, 2: 0b000}),
        (0, {0: 0b111, 1: 0b110, 2: 0b101}),
        (1, {0: 0b111, 1: 0b011, 2: 0b011}),
        (2, {0: 0b110, 1: 0b110, 2: 0b000}),
    ],
)
def test_three_node_non_canonical_shapes_halt(
    node_id: int,
    rows: dict[int, int],
) -> None:
    node = Node(node_id=node_id, node_count=3)

    assert node._candidate_quorum(stage(rows)) is None


def test_witness_core_can_differ_from_certified_row_bits() -> None:
    node = Node(node_id=0, node_count=3)

    assert node._candidate_quorum(stage({0: 0b111, 1: 0b000, 2: 0b111})) == 0b101


def test_nonzero_row_must_self_include() -> None:
    node = Node(node_id=0, node_count=3)

    assert node._candidate_quorum(stage({0: 0b111, 1: 0b101, 2: 0b111})) is None


def test_five_node_full_membership_canonical_shape() -> None:
    node = Node(node_id=3, node_count=5)
    rows = {idx: full_membership(5) for idx in range(5)}

    assert node._candidate_quorum(stage(rows, node_count=5)) == 0b11111


def test_five_node_degraded_canonical_shape() -> None:
    node = Node(node_id=1, node_count=5)
    rows = {
        0: 0b01011,
        1: 0b01011,
        2: 0b00000,
        3: 0b01011,
        4: 0b00000,
    }

    assert node._candidate_quorum(stage(rows, node_count=5)) == 0b01011


def test_five_node_degraded_shape_must_include_local_node() -> None:
    node = Node(node_id=2, node_count=5)
    rows = {
        0: 0b01011,
        1: 0b01011,
        2: 0b00000,
        3: 0b01011,
        4: 0b00000,
    }

    assert node._candidate_quorum(stage(rows, node_count=5)) is None


def test_five_node_degraded_shape_requires_exact_rows() -> None:
    node = Node(node_id=1, node_count=5)
    rows = {
        0: 0b11011,
        1: 0b01011,
        2: 0b00000,
        3: 0b01011,
        4: 0b00000,
    }

    assert node._candidate_quorum(stage(rows, node_count=5)) is None


def test_five_node_witness_core_ignores_external_nonzero_rows() -> None:
    node = Node(node_id=1, node_count=5)
    rows = {
        0: 0b01011,
        1: 0b01011,
        2: 0b00100,
        3: 0b01011,
        4: 0b00000,
    }

    assert node._candidate_quorum(stage(rows, node_count=5)) == 0b01011
