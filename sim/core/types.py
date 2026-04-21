from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Callable


def bitmap_set(node_count: int, *members: int) -> int:
    value = 0
    for member in members:
        if not 0 <= member < node_count:
            raise ValueError(f"member {member} is outside node_count={node_count}")
        value |= 1 << member
    return value


def bitmap_members(bitmap: int, node_count: int) -> list[int]:
    return [idx for idx in range(node_count) if bitmap & (1 << idx)]


def bitmap_text(bitmap: int, node_count: int) -> str:
    return "".join("1" if bitmap & (1 << idx) else "0" for idx in range(node_count - 1, -1, -1))


class NodeStatus(str, Enum):
    RUNNING = "RUNNING"
    HALTED = "HALTED"
    CRASHED = "CRASHED"


class MembershipState(str, Enum):
    ACTIVE = "ACTIVE"
    FAILED = "FAILED"
    RECOVERING = "RECOVERING"
    REJOIN_PENDING = "REJOIN_PENDING"


@dataclass(frozen=True)
class Packet:
    epoch_id: int
    src_id: int
    membership_epoch: int
    ack_bitmap: int
    payload: str


@dataclass
class EpochStage:
    epoch_id: int
    membership_epoch: int = 0
    membership_bitmap: int = 0
    my_bitmap: int = 0
    proposals: dict[int, str] = field(default_factory=dict)
    ack_matrix: dict[int, int] = field(default_factory=dict)


@dataclass
class Delivery:
    deliver_epoch: int | None
    reason: str = "deliver"
    packet_epoch_override: int | None = None
    membership_epoch_override: int | None = None
    ack_override: int | None = None
    payload_override: str | None = None
    extra_deliver_epochs: tuple[int, ...] = ()


FaultModel = Callable[[Packet, int], Delivery]
PayloadFactory = Callable[[int, int], str]
ActivityModel = Callable[[int, int], bool]


@dataclass(frozen=True)
class ControlPlaneState:
    membership_epoch: int
    active_membership: int
    node_states: dict[int, MembershipState]


ControlPlaneModel = Callable[[int, int], ControlPlaneState]


@dataclass(frozen=True)
class ScenarioExpectation:
    statuses: tuple[str, ...]
    committed_epochs: tuple[tuple[int, ...], ...]
    halted_epochs: tuple[int | None, ...]

    def check(self, result: dict[str, object]) -> list[str]:
        failures: list[str] = []
        nodes = result["nodes"]

        actual_statuses = tuple(node["status"] for node in nodes)
        if actual_statuses != self.statuses:
            failures.append(f"status mismatch: expected {self.statuses}, got {actual_statuses}")

        actual_commits = tuple(
            tuple(entry["epoch"] for entry in node["committed_epochs"])
            for node in nodes
        )
        if actual_commits != self.committed_epochs:
            failures.append(f"commit mismatch: expected {self.committed_epochs}, got {actual_commits}")

        actual_halts = tuple(node["halted_epoch"] for node in nodes)
        if actual_halts != self.halted_epochs:
            failures.append(f"halted_epoch mismatch: expected {self.halted_epochs}, got {actual_halts}")

        return failures


@dataclass(frozen=True)
class ScenarioSpec:
    fault_model: FaultModel
    activity_model: ActivityModel
    control_plane_model: ControlPlaneModel
    epochs: int
    description: str
    expectation: ScenarioExpectation
