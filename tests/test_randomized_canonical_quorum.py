from __future__ import annotations

import random
from sim.core.node import Node
from sim.core.types import EpochStage


def make_stage(rows: dict[int, int], *, node_count: int) -> EpochStage:
    return EpochStage(
        epoch_id=0,
        membership_epoch=0,
        membership_bitmap=(1 << node_count) - 1,
        my_bitmap=1,
        ack_matrix=rows,
    )


def bitmap_for(members: tuple[int, ...]) -> int:
    value = 0
    for member in members:
        value |= 1 << member
    return value


def reference_candidate(
    rows: dict[int, int],
    *,
    node_id: int,
    node_count: int,
) -> int | None:
    members = tuple(range(node_count))
    quorum = node_count // 2 + 1

    for src, row in rows.items():
        if row != 0 and not (row & (1 << src)):
            return None

    local_row = rows[node_id]
    if local_row == 0:
        return None

    witnesses = tuple(member for member in members if rows[member] == local_row)
    if len(witnesses) < quorum:
        return None
    return bitmap_for(witnesses)


def test_random_observation_matrices_match_reference_checker() -> None:
    rng = random.Random(20260425)

    for node_count in (3, 4, 5, 6):
        all_rows = range(1 << node_count)
        for node_id in range(node_count):
            node = Node(node_id=node_id, node_count=node_count)
            for _ in range(200):
                rows = {member: rng.choice(all_rows) for member in range(node_count)}
                stage = make_stage(rows, node_count=node_count)

                assert node._candidate_quorum(stage) == reference_candidate(
                    rows,
                    node_id=node_id,
                    node_count=node_count,
                )
