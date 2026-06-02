"""Host-side register map for the consensus/SSR Corundum app.

This file is intentionally simple and bring-up oriented:

- register offsets are the source of truth for MMIO access
- small dataclasses provide a typed view of active/pending config and status
- helper functions encode/decode common control/status bitfields

The goal is to make early control-plane scripts readable before we commit to a
full runtime library.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum, IntFlag


class RegOffset(IntEnum):
    # 0x000-0x03f: identity and liveness
    APP_ID = 0x000
    APP_VERSION = 0x004
    APP_STATUS = 0x008
    APP_CONTROL = 0x00C
    HEARTBEAT_LO = 0x010
    HEARTBEAT_HI = 0x014
    LOCAL_TIME_LO = 0x018
    LOCAL_TIME_HI = 0x01C

    # 0x040-0x09f: active configuration
    ACTIVE_RUN_ID = 0x040
    ACTIVE_EPOCH = 0x044
    ACTIVE_MEMBERSHIP_LO = 0x048
    ACTIVE_MEMBERSHIP_HI = 0x04C
    ROUND_LENGTH_NS = 0x050
    NODE_ID = 0x054
    CLUSTER_SIZE = 0x058

    # 0x0a0-0x0ff: pending configuration
    PENDING_RUN_ID = 0x0A0
    PENDING_EPOCH = 0x0A4
    PENDING_MEMBERSHIP_LO = 0x0A8
    PENDING_MEMBERSHIP_HI = 0x0AC
    ACTIVATION_ROUND_LO = 0x0B0
    ACTIVATION_ROUND_HI = 0x0B4
    PENDING_FLAGS = 0x0B8

    # 0x100-0x15f: fast-path progress and halt state
    CURRENT_ROUND_LO = 0x100
    CURRENT_ROUND_HI = 0x104
    LAST_COMMIT_ROUND_LO = 0x108
    LAST_COMMIT_ROUND_HI = 0x10C
    LAST_COMMIT_INDEX_LO = 0x110
    LAST_COMMIT_INDEX_HI = 0x114
    HALT_REASON = 0x118
    HALT_ROUND_LO = 0x11C
    HALT_ROUND_HI = 0x120
    HALT_INFO = 0x124

    # 0x160-0x1bf: event / interrupt status
    EVENT_STATUS = 0x160
    EVENT_ENABLE = 0x164
    EVENT_ACK = 0x168
    INTERRUPT_COUNT = 0x16C

    # 0x200-0x27f: DMA ingress (host -> app)
    CMD_DMA_BASE_LO = 0x200
    CMD_DMA_BASE_HI = 0x204
    CMD_RING_SIZE = 0x208
    CMD_HEAD = 0x20C
    CMD_TAIL = 0x210
    CMD_CONTROL = 0x214
    CMD_STATUS = 0x218
    CMD_ERROR = 0x21C

    # 0x280-0x2ff: DMA egress (app -> host)
    CPL_DMA_BASE_LO = 0x280
    CPL_DMA_BASE_HI = 0x284
    CPL_RING_SIZE = 0x288
    CPL_HEAD = 0x28C
    CPL_TAIL = 0x290
    CPL_CONTROL = 0x294
    CPL_STATUS = 0x298
    CPL_ERROR = 0x29C


class AppStatus(IntFlag):
    APP_ENABLED = 1 << 0
    APP_ACTIVE = 1 << 1
    HALT_VALID = 1 << 2
    PENDING_CFG_VALID = 1 << 3
    PENDING_CFG_COMMITTED = 1 << 4
    ACTIVATION_ARMED = 1 << 5


class AppControl(IntFlag):
    ENABLE_APP = 1 << 0
    SOFT_RESET = 1 << 1
    CLEAR_HALT = 1 << 2
    COMMIT_PENDING_CFG = 1 << 3
    ARM_ACTIVATION = 1 << 4


class EventBits(IntFlag):
    HALT = 1 << 0
    COMMIT = 1 << 1
    CMD_RING_UPDATE = 1 << 2
    CPL_RING_UPDATE = 1 << 3


class DmaRingControl(IntFlag):
    ENABLE = 1 << 0
    DOORBELL = 1 << 1
    RESET = 1 << 2


class HaltReason(IntEnum):
    NONE = 0
    QUORUM_FAILURE = 1
    SHRINKAGE_VIOLATION = 2
    SELF_EXCLUSION = 3
    PAYLOAD_UNAVAILABLE = 4
    INVALID_MESSAGE = 5
    SOFTWARE_FORCED = 6
    INTERNAL_ERROR = 7


@dataclass(frozen=True)
class ActiveConfig:
    run_id: int
    epoch: int
    membership: int
    round_length_ns: int
    node_id: int
    cluster_size: int


@dataclass(frozen=True)
class PendingConfig:
    run_id: int
    epoch: int
    membership: int
    activation_round: int
    flags: int


@dataclass(frozen=True)
class FastPathStatus:
    app_status: AppStatus
    current_round: int
    last_commit_round: int
    last_commit_index: int
    halt_reason: HaltReason
    halt_round: int
    halt_info: int

    @property
    def halted(self) -> bool:
        return bool(self.app_status & AppStatus.HALT_VALID)


def split_u64(value: int) -> tuple[int, int]:
    """Return (lo, hi) 32-bit words for a 64-bit value."""
    return value & 0xFFFF_FFFF, (value >> 32) & 0xFFFF_FFFF


def join_u64(lo: int, hi: int) -> int:
    """Combine low/high 32-bit words into a Python integer."""
    return (hi & 0xFFFF_FFFF) << 32 | (lo & 0xFFFF_FFFF)


def encode_active_config(cfg: ActiveConfig) -> dict[RegOffset, int]:
    membership_lo, membership_hi = split_u64(cfg.membership)
    return {
        RegOffset.ACTIVE_RUN_ID: cfg.run_id,
        RegOffset.ACTIVE_EPOCH: cfg.epoch,
        RegOffset.ACTIVE_MEMBERSHIP_LO: membership_lo,
        RegOffset.ACTIVE_MEMBERSHIP_HI: membership_hi,
        RegOffset.ROUND_LENGTH_NS: cfg.round_length_ns,
        RegOffset.NODE_ID: cfg.node_id,
        RegOffset.CLUSTER_SIZE: cfg.cluster_size,
    }


def encode_pending_config(cfg: PendingConfig) -> dict[RegOffset, int]:
    membership_lo, membership_hi = split_u64(cfg.membership)
    activation_lo, activation_hi = split_u64(cfg.activation_round)
    return {
        RegOffset.PENDING_RUN_ID: cfg.run_id,
        RegOffset.PENDING_EPOCH: cfg.epoch,
        RegOffset.PENDING_MEMBERSHIP_LO: membership_lo,
        RegOffset.PENDING_MEMBERSHIP_HI: membership_hi,
        RegOffset.ACTIVATION_ROUND_LO: activation_lo,
        RegOffset.ACTIVATION_ROUND_HI: activation_hi,
        RegOffset.PENDING_FLAGS: cfg.flags,
    }


def decode_fast_path_status(regs: dict[RegOffset, int]) -> FastPathStatus:
    app_status = AppStatus(regs[RegOffset.APP_STATUS])

    reason_raw = regs[RegOffset.HALT_REASON]
    try:
        halt_reason = HaltReason(reason_raw)
    except ValueError:
        halt_reason = HaltReason.INTERNAL_ERROR

    return FastPathStatus(
        app_status=app_status,
        current_round=join_u64(
            regs[RegOffset.CURRENT_ROUND_LO],
            regs[RegOffset.CURRENT_ROUND_HI],
        ),
        last_commit_round=join_u64(
            regs[RegOffset.LAST_COMMIT_ROUND_LO],
            regs[RegOffset.LAST_COMMIT_ROUND_HI],
        ),
        last_commit_index=join_u64(
            regs[RegOffset.LAST_COMMIT_INDEX_LO],
            regs[RegOffset.LAST_COMMIT_INDEX_HI],
        ),
        halt_reason=halt_reason,
        halt_round=join_u64(
            regs[RegOffset.HALT_ROUND_LO],
            regs[RegOffset.HALT_ROUND_HI],
        ),
        halt_info=regs[RegOffset.HALT_INFO],
    )

