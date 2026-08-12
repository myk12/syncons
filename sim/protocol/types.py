from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, TypeAlias


JsonDict: TypeAlias = dict[str, Any]


def parse_duration_ns(text: str) -> int:
    value = text.strip().lower()
    units = (
        ("ns", 1),
        ("us", 1_000),
        ("ms", 1_000_000),
        ("s", 1_000_000_000),
    )
    for suffix, scale in units:
        if value.endswith(suffix):
            magnitude = value[: -len(suffix)].strip()
            if not magnitude:
                raise ValueError(f"missing magnitude in duration {text!r}")
            return int(round(float(magnitude) * scale))
    raise ValueError(f"unsupported duration {text!r}; expected suffix ns/us/ms/s")


def format_duration_ns(value_ns: int) -> str:
    if value_ns == 0:
        return "0ns"
    if value_ns % 1_000_000_000 == 0:
        return f"{value_ns / 1_000_000_000:g}s"
    if value_ns % 1_000_000 == 0:
        return f"{value_ns / 1_000_000:g}ms"
    if value_ns % 1_000 == 0:
        return f"{value_ns / 1_000:g}us"
    return f"{value_ns}ns"


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


class PendingConfigStatus(str, Enum):
    PREPARED = "PREPARED"
    COMMITTED = "COMMITTED"


@dataclass(frozen=True)
class SimulationTiming:
    round_length_ns: int = 4_000
    halt_report_delay_ns: int = 10_000      # time for a node to observe a failed round and interru
    cp_collection_delay_ns: int = 20_000    # recovery episode formation	
    cp_decision_delay_ns: int = 15_000
    repair_delay_ns: int = 50_000
    install_delay_ns: int = 20_000
    reentry_delay_ns: int = 10_000
    app_delivery_delay_ns: int = 5_000


@dataclass(frozen=True)
class Packet:
    round_id: int
    src_id: int
    run_id: int
    sound_bitmap: int
    payload: str


@dataclass(frozen=True)
class OutboundPacket:
    packet: Packet
    destinations: tuple[int, ...]


@dataclass
class RoundStage:
    round_id: int
    membership_epoch: int = 0
    installed_membership: int = 0
    sound_bitmap: int = 0
    proposals: dict[int, str] = field(default_factory=dict)
    sound_matrix: dict[int, int] = field(default_factory=dict)


@dataclass(frozen=True)
class CommittedRound:
    round: int
    membership_epoch: int
    commit_set: int
    proposals: dict[int, str]

    def digest_projection(self) -> JsonDict:
        return {
            "round": self.round,
            "membership_epoch": self.membership_epoch,
            "commit_set": self.commit_set,
            "proposals": dict(self.proposals),
        }


@dataclass(frozen=True)
class CommittedRoundRecord:
    round: int
    membership_epoch: int
    commit_set: int
    proposals: dict[int, str]
    commit_time_ns: int | None = None
    app_delivery_time_ns: int | None = None

    def digest_projection(self) -> JsonDict:
        return {
            "round": self.round,
            "membership_epoch": self.membership_epoch,
            "commit_set": self.commit_set,
            "proposals": dict(self.proposals),
        }

    def to_snapshot(self) -> JsonDict:
        return {
            "round": self.round,
            "membership_epoch": self.membership_epoch,
            "commit_set": self.commit_set,
            "proposals": dict(self.proposals),
            **(
                {}
                if self.commit_time_ns is None
                else {"commit_time_ns": self.commit_time_ns}
            ),
            **(
                {}
                if self.app_delivery_time_ns is None
                else {"app_delivery_time_ns": self.app_delivery_time_ns}
            ),
        }

    @classmethod
    def from_snapshot(cls, snapshot: JsonDict) -> "CommittedRoundRecord":
        return cls(
            round=int(snapshot["round"]),
            membership_epoch=int(snapshot["membership_epoch"]),
            commit_set=int(snapshot["commit_set"]),
            proposals={int(k): str(v) for k, v in dict(snapshot["proposals"]).items()},
            commit_time_ns=None if "commit_time_ns" not in snapshot else int(snapshot["commit_time_ns"]),
            app_delivery_time_ns=None if "app_delivery_time_ns" not in snapshot else int(snapshot["app_delivery_time_ns"]),
        )

    def with_timing(
        self,
        *,
        commit_time_ns: int | None = None,
        app_delivery_time_ns: int | None = None,
    ) -> "CommittedRoundRecord":
        return CommittedRoundRecord(
            round=self.round,
            membership_epoch=self.membership_epoch,
            commit_set=self.commit_set,
            proposals=dict(self.proposals),
            commit_time_ns=self.commit_time_ns if commit_time_ns is None else commit_time_ns,
            app_delivery_time_ns=self.app_delivery_time_ns if app_delivery_time_ns is None else app_delivery_time_ns,
        )

    @classmethod
    def from_committed_round(
        cls,
        committed: CommittedRound,
        *,
        commit_time_ns: int | None = None,
        app_delivery_time_ns: int | None = None,
    ) -> "CommittedRoundRecord":
        return cls(
            round=committed.round,
            membership_epoch=committed.membership_epoch,
            commit_set=committed.commit_set,
            proposals=dict(committed.proposals),
            commit_time_ns=commit_time_ns,
            app_delivery_time_ns=app_delivery_time_ns,
        )

@dataclass(frozen=True)
class NodeRoundResult:
    outbound: OutboundPacket | None
    new_commits: tuple[CommittedRound, ...]

@dataclass(frozen=True)
class RepairLog:
    entries: tuple[CommittedRoundRecord, ...] = ()

    def __len__(self) -> int:
        return len(self.entries)

    def to_snapshot(self) -> tuple[JsonDict, ...]:
        return tuple(entry.to_snapshot() for entry in self.entries)


@dataclass(frozen=True)
class RepairSnapshot:
    node_id: int
    committed_rounds: tuple[CommittedRoundRecord, ...]


@dataclass(frozen=True)
class HaltRecord:
    failed_round: int
    membership_epoch: int
    installed_membership_epoch: int
    run_id: int
    installed_membership: int
    quorum: int
    observation_rows: dict[int, int]
    self_row: int
    committed_frontier: int | None
    sound_set_lineage: int | None
    log_digest: str
    halt_reason: str

    def to_snapshot(self) -> JsonDict:
        return {
            "failed_round": self.failed_round,
            "membership_epoch": self.membership_epoch,
            "installed_membership_epoch": self.installed_membership_epoch,
            "run_id": self.run_id,
            "installed_membership": self.installed_membership,
            "quorum": self.quorum,
            "observation_rows": dict(self.observation_rows),
            "self_row": self.self_row,
            "committed_frontier": self.committed_frontier,
            "sound_set_lineage": self.sound_set_lineage,
            "log_digest": self.log_digest,
            "halt_reason": self.halt_reason,
        }


# Delivery is the medium through which the fault model can control packet delivery.
# By setting deliver_round, the fault model can specify when a packet should be
# delivered. 
# By setting reason, it can annotate the delivery as normal, dropped,
# delayed, or otherwise perturbed. 
# The override fields can mutate the packet's round id, run id, sound bitmap, 
# and payload for testing purposes. The extra_deliver_rounds field can request 
# duplicate deliveries in later rounds.
@dataclass
class DeliveryCopy:
    deliver_round: int
    reason: str = "duplicate deliver"
    packet_round_override: int | None = None
    run_id_override: int | None = None
    sound_override: int | None = None
    payload_override: str | None = None


@dataclass
class Delivery:
    deliver_round: int | None
    reason: str = "deliver"
    packet_round_override: int | None = None
    run_id_override: int | None = None
    sound_override: int | None = None
    payload_override: str | None = None
    extra_deliver_rounds: tuple[int, ...] = ()
    extra_copies: tuple[DeliveryCopy, ...] = ()


NetworkFaultModel = Callable[[Packet, int], Delivery]
PayloadFactory = Callable[[int, int], str]
NodeFaultModel = Callable[[int, int], bool]


@dataclass(frozen=True)
class InstalledConfig:
    membership_epoch: int
    members_bitmap: int
    run_id: int = 0


@dataclass(frozen=True)
class PendingConfig:
    membership_epoch: int
    members_bitmap: int
    effective_round: int
    run_id: int = 0
    status: PendingConfigStatus = PendingConfigStatus.PREPARED


@dataclass(frozen=True)
class ControlPlaneState:
    installed_config: InstalledConfig
    node_states: dict[int, MembershipState]
    pending_config: PendingConfig | None = None
    repair_logs: dict[int, RepairLog] = field(default_factory=dict)

    @property
    def membership_epoch(self) -> int:
        return self.installed_config.membership_epoch

    @property
    def installed_membership(self) -> int:
        return self.installed_config.members_bitmap

    @property
    def run_id(self) -> int:
        return self.installed_config.run_id


@dataclass(frozen=True)
class ControlPlaneUpdate:
    installed_config: InstalledConfig
    membership_state: MembershipState
    pending_config: PendingConfig | None = None
    repair_log: RepairLog | None = None


@dataclass(frozen=True)
class ScenarioExpectation:
    statuses: tuple[str, ...]
    committed_rounds: tuple[tuple[int, ...], ...]
    halted_rounds: tuple[int | None, ...]

    def check(self, result: JsonDict) -> list[str]:
        failures: list[str] = []
        nodes = result["nodes"]

        actual_statuses = tuple(node["status"] for node in nodes)
        if actual_statuses != self.statuses:
            failures.append(f"status mismatch: expected {self.statuses}, got {actual_statuses}")

        actual_commits = tuple(
            tuple(entry["round"] for entry in node["committed_rounds"])
            for node in nodes
        )
        if actual_commits != self.committed_rounds:
            failures.append(f"commit mismatch: expected {self.committed_rounds}, got {actual_commits}")

        actual_halts = tuple(node["halted_round"] for node in nodes)
        if actual_halts != self.halted_rounds:
            failures.append(f"halted_round mismatch: expected {self.halted_rounds}, got {actual_halts}")

        return failures


@dataclass(frozen=True)
class ScenarioSpec:
    network_fault_model: NetworkFaultModel
    node_fault_model: NodeFaultModel
    rounds: int
    description: str
    expectation: ScenarioExpectation
