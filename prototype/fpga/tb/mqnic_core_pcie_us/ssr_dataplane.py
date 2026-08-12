#!/usr/bin/env python3
"""
Cocotb driver model for the SSR Corundum application dataplane.
"""

from __future__ import annotations

from collections.abc import Callable
from enum import IntFlag
from typing import Any

from cocotb.log import SimLog

import mqnic


# -----------------------------------------------------------------------------
# Application identity and address regions
# -----------------------------------------------------------------------------

SSR_RB_TYPE = 0x53535201
SSR_RB_VERSION = 0x00000100
SSR_RB_FEATURES = 0x0000000F

RBB_COMMON = 0x00000000
RBB_PROPOSAL_QUEUE = 0x00001000
RBB_COMMIT_QUEUE = 0x00002000


# -----------------------------------------------------------------------------
# Common register block
# -----------------------------------------------------------------------------

COMMON_REG_TYPE = RBB_COMMON + 0x000
COMMON_REG_VERSION = RBB_COMMON + 0x004
COMMON_REG_NEXT_PTR = RBB_COMMON + 0x008
COMMON_REG_FEATURES = RBB_COMMON + 0x00C
COMMON_REG_CONTROL = RBB_COMMON + 0x010
COMMON_REG_STATUS = RBB_COMMON + 0x014
COMMON_REG_ERROR = RBB_COMMON + 0x018
COMMON_REG_SCRATCH = RBB_COMMON + 0x01C

COMMON_REG_CONFIG_REPLICA_ID = RBB_COMMON + 0x020
COMMON_REG_CONFIG_REPLICA_NUM = RBB_COMMON + 0x024
COMMON_REG_CONFIG_ROUND_LEN_NS = RBB_COMMON + 0x028
COMMON_REG_CONFIG_ETH_TYPE = RBB_COMMON + 0x02C

COMMON_REG_CONFIG_MACTABLE_ADDR_LO = RBB_COMMON + 0x100
COMMON_REG_CONFIG_MACTABLE_ADDR_HI = RBB_COMMON + 0x104
COMMON_MAC_ENTRY_STRIDE = 8
COMMON_MAX_REPLICAS = 7

# Test-only proposal sink
COMMON_REG_PROPOSAL_SINK_CONTROL = RBB_COMMON + 0x230
COMMON_REG_PROPOSAL_SINK_SLOT_COUNT = RBB_COMMON + 0x234
COMMON_REG_PROPOSAL_SINK_BEAT_COUNT = RBB_COMMON + 0x238
COMMON_REG_PROPOSAL_SINK_ERROR_COUNT = RBB_COMMON + 0x23C

# Test-only commit generator
COMMON_REG_COMMIT_GEN_COUNT = RBB_COMMON + 0x240
COMMON_REG_COMMIT_GEN_CONTROL = RBB_COMMON + 0x244
COMMON_REG_COMMIT_GEN_STATUS = RBB_COMMON + 0x248
COMMON_REG_COMMIT_GEN_GENERATED_SLOT_COUNT = RBB_COMMON + 0x24C
COMMON_REG_COMMIT_GEN_GENERATED_BEAT_COUNT = RBB_COMMON + 0x250


# -----------------------------------------------------------------------------
# Proposal DMA queue
# -----------------------------------------------------------------------------

PROP_DMA_MAGIC = 0x70726F71  # "proq"
PROP_DMA_VERSION = 0x00000100
PROP_DMA_FEATURES = 0x00000001

PROP_DMA_REG_MAGIC = RBB_PROPOSAL_QUEUE + 0x000
PROP_DMA_REG_VERSION = RBB_PROPOSAL_QUEUE + 0x004
PROP_DMA_REG_FEATURES = RBB_PROPOSAL_QUEUE + 0x008
PROP_DMA_REG_GLOBAL_CONTROL = RBB_PROPOSAL_QUEUE + 0x00C
PROP_DMA_REG_GLOBAL_STATUS = RBB_PROPOSAL_QUEUE + 0x010
PROP_DMA_REG_SCRATCH = RBB_PROPOSAL_QUEUE + 0x014
PROP_DMA_REG_ENTRY_COUNTER = RBB_PROPOSAL_QUEUE + 0x018

PROP_DMA_REG_BATCH_ADDR_LO = RBB_PROPOSAL_QUEUE + 0x100
PROP_DMA_REG_BATCH_ADDR_HI = RBB_PROPOSAL_QUEUE + 0x104
PROP_DMA_REG_BATCH_SLOT_LEN = RBB_PROPOSAL_QUEUE + 0x108
PROP_DMA_REG_BATCH_STRIDE_LO = RBB_PROPOSAL_QUEUE + 0x10C
PROP_DMA_REG_BATCH_STRIDE_HI = RBB_PROPOSAL_QUEUE + 0x110
PROP_DMA_REG_BATCH_COUNT = RBB_PROPOSAL_QUEUE + 0x114
PROP_DMA_REG_BATCH_CONTROL = RBB_PROPOSAL_QUEUE + 0x118
PROP_DMA_REG_BATCH_STATUS = RBB_PROPOSAL_QUEUE + 0x11C
PROP_DMA_REG_BATCH_ACTIVE_INDEX = RBB_PROPOSAL_QUEUE + 0x120
PROP_DMA_REG_BATCH_STATE = RBB_PROPOSAL_QUEUE + 0x124
PROP_DMA_REG_STATUS_TAG = RBB_PROPOSAL_QUEUE + 0x128
PROP_DMA_REG_STATUS_ERROR = RBB_PROPOSAL_QUEUE + 0x12C
PROP_DMA_REG_STATUS_VALID = RBB_PROPOSAL_QUEUE + 0x130

# -----------------------------------------------------------------------------
# Commit DMA writer (matches the current commit_dma_writer RTL)
# -----------------------------------------------------------------------------

COMMIT_DMA_REG_STRIDE_LO = RBB_COMMIT_QUEUE + 0x000
COMMIT_DMA_REG_STRIDE_HI = RBB_COMMIT_QUEUE + 0x004
COMMIT_DMA_REG_CONTROL = RBB_COMMIT_QUEUE + 0x008
COMMIT_DMA_REG_STATUS = RBB_COMMIT_QUEUE + 0x00C
COMMIT_DMA_REG_ACTIVE_BUFFER = RBB_COMMIT_QUEUE + 0x010

COMMIT_DMA_REG_BUF0_ADDR_LO = RBB_COMMIT_QUEUE + 0x100
COMMIT_DMA_REG_BUF0_ADDR_HI = RBB_COMMIT_QUEUE + 0x104
COMMIT_DMA_REG_BUF0_SLOT_CAPACITY = RBB_COMMIT_QUEUE + 0x108
COMMIT_DMA_REG_BUF0_CONTROL = RBB_COMMIT_QUEUE + 0x12C
COMMIT_DMA_REG_BUF0_STATUS = RBB_COMMIT_QUEUE + 0x130
COMMIT_DMA_REG_BUF0_COMPLETED_COUNT = RBB_COMMIT_QUEUE + 0x134
COMMIT_DMA_REG_BUF0_ERROR_COUNT = RBB_COMMIT_QUEUE + 0x138

COMMIT_DMA_REG_BUF1_ADDR_LO = RBB_COMMIT_QUEUE + 0x200
COMMIT_DMA_REG_BUF1_ADDR_HI = RBB_COMMIT_QUEUE + 0x204
COMMIT_DMA_REG_BUF1_SLOT_CAPACITY = RBB_COMMIT_QUEUE + 0x208
COMMIT_DMA_REG_BUF1_CONTROL = RBB_COMMIT_QUEUE + 0x22C
COMMIT_DMA_REG_BUF1_STATUS = RBB_COMMIT_QUEUE + 0x230
COMMIT_DMA_REG_BUF1_COMPLETED_COUNT = RBB_COMMIT_QUEUE + 0x234
COMMIT_DMA_REG_BUF1_ERROR_COUNT = RBB_COMMIT_QUEUE + 0x238


# -----------------------------------------------------------------------------
# Bit definitions
# -----------------------------------------------------------------------------

class CommonStatus(IntFlag):
    CONFIG_VALID = 1 << 0
    CONTROL_BIT_0 = 1 << 1
    CONTROL_BIT_1 = 1 << 2


class ProposalControl(IntFlag):
    START = 1 << 0
    CLEAR_DONE = 1 << 1
    CLEAR_ERROR = 1 << 2


class ProposalStatus(IntFlag):
    RUNNING = 1 << 0
    DONE = 1 << 1
    ERROR = 1 << 2


class CommitGlobalControl(IntFlag):
    START = 1 << 0
    STOP = 1 << 1


class CommitGlobalStatus(IntFlag):
    BUSY = 1 << 0
    WAITING_SLOT = 1 << 1
    WAITING_ARMED_BUFFER = 1 << 2


class CommitBufferControl(IntFlag):
    ARM = 1 << 0
    CLEAR_STATUS = 1 << 1


class CommitBufferStatus(IntFlag):
    ARMED = 1 << 0
    DONE = 1 << 1
    ERROR = 1 << 2


class ProposalSinkControl(IntFlag):
    ENABLE = 1 << 0
    CLEAR = 1 << 1


class CommitGeneratorControl(IntFlag):
    START = 1 << 0
    STOP = 1 << 1
    CLEAR = 1 << 2


class CommitGeneratorStatus(IntFlag):
    BUSY = 1 << 0
    DONE = 1 << 1


# -----------------------------------------------------------------------------
# Exceptions and generic helpers
# -----------------------------------------------------------------------------

class SSRDriverError(RuntimeError):
    """Base exception for the SSR dataplane driver model."""


class SSRDriverProbeError(SSRDriverError):
    """Raised when the SSR application cannot be discovered or validated."""


class SSRDriverTimeoutError(SSRDriverError):
    """Raised when hardware does not reach a requested state in time."""


class SSRDeviceBusyError(SSRDriverError):
    """Raised when software attempts an operation on a busy resource."""


class SSRHardwareError(SSRDriverError):
    """Raised when the dataplane reports a hardware or DMA error."""


def _validate_u64(value: int, name: str) -> None:
    if not isinstance(value, int):
        raise TypeError(f"{name} must be an integer")
    if value < 0 or value > 0xFFFFFFFFFFFFFFFF:
        raise ValueError(f"{name} must fit in 64 bits")


def _validate_u32(value: int, name: str) -> None:
    if not isinstance(value, int):
        raise TypeError(f"{name} must be an integer")
    if value < 0 or value > 0xFFFFFFFF:
        raise ValueError(f"{name} must fit in 32 bits")

async def poll_register(
    rb: Any,
    address: int,
    predicate: Callable[[int], bool],
    *,
    timeout_polls: int = 2000,
    description: str = "register condition",
) -> int:
    """Poll one 32-bit CSR until predicate(value) returns True."""
    if timeout_polls <= 0:
        raise ValueError("timeout_polls must be positive")

    last_value = 0

    for _ in range(timeout_polls):
        last_value = int(await rb.read_dword(address)) & 0xFFFFFFFF

        if predicate(last_value):
            return last_value

    raise SSRDriverTimeoutError(
        f"Timeout waiting for {description}; "
        f"address=0x{address:08x}, last_value=0x{last_value:08x}"
    )

# -----------------------------------------------------------------------------
# Proposal queue
# -----------------------------------------------------------------------------

class ProposalQueue:
    """Driver-side control of the host-to-FPGA proposal DMA queue."""

    def __init__(self, driver: "Driver") -> None:
        self.driver = driver
        self.rb = driver.rb

    async def validate_identity(self) -> None:
        magic = int(await self.rb.read_dword(PROP_DMA_REG_MAGIC))
        version = int(await self.rb.read_dword(PROP_DMA_REG_VERSION))
        features = int(await self.rb.read_dword(PROP_DMA_REG_FEATURES))

        if magic != PROP_DMA_MAGIC:
            raise SSRDriverProbeError(
                f"Unexpected proposal queue magic: expected "
                f"0x{PROP_DMA_MAGIC:08x}, got 0x{magic:08x}"
            )
        if version != PROP_DMA_VERSION:
            raise SSRDriverProbeError(
                f"Unexpected proposal queue version: expected "
                f"0x{PROP_DMA_VERSION:08x}, got 0x{version:08x}"
            )
        if features & PROP_DMA_FEATURES != PROP_DMA_FEATURES:
            raise SSRDriverProbeError(
                f"Proposal queue lacks required features: required "
                f"0x{PROP_DMA_FEATURES:08x}, got 0x{features:08x}"
            )

    async def read_status(self) -> ProposalStatus:
        value = await self.rb.read_dword(PROP_DMA_REG_BATCH_STATUS)
        return ProposalStatus(int(value))

    async def read_active_index(self) -> int:
        return int(await self.rb.read_dword(PROP_DMA_REG_BATCH_ACTIVE_INDEX))

    async def read_entry_counter(self) -> int:
        return int(await self.rb.read_dword(PROP_DMA_REG_ENTRY_COUNTER))

    async def read_slot_length(self) -> int:
        return int(await self.rb.read_dword(PROP_DMA_REG_BATCH_SLOT_LEN))

    async def read_state(self) -> int:
        return int(await self.rb.read_dword(PROP_DMA_REG_BATCH_STATE))

    async def clear_status(self) -> None:
        await self.rb.write_dword(
            PROP_DMA_REG_BATCH_CONTROL,
            int(ProposalControl.CLEAR_DONE | ProposalControl.CLEAR_ERROR),
        )

    async def submit(self, dma_addr: int, count: int, stride: int) -> None:
        """Configure and start one proposal DMA batch.

        FPGA-internal proposal-buffer fullness is handled by RTL backpressure
        through tail_slot_valid.  The host only protects the active batch
        configuration from being overwritten while RUNNING is asserted.
        """
        _validate_u64(dma_addr, "dma_addr")
        _validate_u64(stride, "stride")
        _validate_u32(count, "count")

        assert count != 0 and stride != 0, "count and stride must be positive"

        status = await self.read_status()
        if status & ProposalStatus.RUNNING:
            raise SSRDeviceBusyError("Proposal DMA engine is already running")

        await self.clear_status()
        await self.rb.write_dword(PROP_DMA_REG_BATCH_ADDR_LO, dma_addr & 0xFFFFFFFF)
        await self.rb.write_dword(PROP_DMA_REG_BATCH_ADDR_HI, (dma_addr >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(PROP_DMA_REG_BATCH_STRIDE_LO, stride & 0xFFFFFFFF)
        await self.rb.write_dword(PROP_DMA_REG_BATCH_STRIDE_HI, (stride >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(PROP_DMA_REG_BATCH_COUNT, count)
        await self.rb.write_dword(PROP_DMA_REG_BATCH_CONTROL, int(ProposalControl.START))

    async def wait_done(self, *, timeout_polls: int = 2000) -> ProposalStatus:
        value = await poll_register(
            self.rb,
            PROP_DMA_REG_BATCH_STATUS,
            lambda status: bool(
                status & int(ProposalStatus.DONE | ProposalStatus.ERROR)
            ),
            timeout_polls=timeout_polls,
            description="proposal DMA batch completion",
        )

        status = ProposalStatus(value)
        if status & ProposalStatus.ERROR:
            dma_error = int(
                await self.rb.read_dword(PROP_DMA_REG_STATUS_ERROR)
            )
            dma_tag = int(await self.rb.read_dword(PROP_DMA_REG_STATUS_TAG))
            raise SSRHardwareError(
                f"Proposal DMA failed: status=0x{value:08x}, "
                f"dma_error=0x{dma_error:08x}, dma_tag=0x{dma_tag:08x}"
            )

        return status

    async def wait_idle(self, *, timeout_polls: int = 2000) -> ProposalStatus:
        value = await poll_register(
            self.rb,
            PROP_DMA_REG_BATCH_STATUS,
            lambda status: not bool(status & int(ProposalStatus.RUNNING)),
            timeout_polls=timeout_polls,
            description="proposal DMA engine idle",
        )
        return ProposalStatus(value)


# -----------------------------------------------------------------------------
# Commit queue and double buffers
# -----------------------------------------------------------------------------

class CommitBuffer:
    """One host-owned buffer in the strict commit ping-pong pair."""

    def __init__(
        self,
        queue: "CommitQueue",
        index: int,
        *,
        addr_lo_reg: int,
        addr_hi_reg: int,
        capacity_reg: int,
        control_reg: int,
        status_reg: int,
        completed_reg: int,
        error_reg: int,
    ) -> None:
        self.queue = queue
        self.driver = queue.driver
        self.rb = queue.rb

        self.index = index
        self.addr_lo_reg = addr_lo_reg
        self.addr_hi_reg = addr_hi_reg
        self.capacity_reg = capacity_reg
        self.control_reg = control_reg
        self.status_reg = status_reg
        self.completed_reg = completed_reg
        self.error_reg = error_reg

        self.dma_addr: int | None = None
        self.slot_capacity = 0
        self.region: Any | None = None

    async def read_status(self) -> CommitBufferStatus:
        value = await self.rb.read_dword(self.status_reg)
        return CommitBufferStatus(int(value))

    async def completed_count(self) -> int:
        return int(await self.rb.read_dword(self.completed_reg))

    async def error_count(self) -> int:
        return int(await self.rb.read_dword(self.error_reg))

    async def configure(self, dma_addr: int, slot_capacity: int, *, region: Any | None = None) -> None:
        _validate_u64(dma_addr, "dma_addr")
        _validate_u32(slot_capacity, "slot_capacity")
        if slot_capacity == 0:
            raise ValueError("slot_capacity must be positive")

        await self.queue.assert_buffer_configurable(self.index)
        status = await self.read_status()

        if status & CommitBufferStatus.ARMED:
            raise SSRDeviceBusyError(f"Commit buffer {self.index} is armed")
        if status & (CommitBufferStatus.DONE | CommitBufferStatus.ERROR):
            raise SSRDeviceBusyError(f"Commit buffer {self.index} has uncleared completion status")

        await self.rb.write_dword(self.addr_lo_reg, dma_addr & 0xFFFFFFFF)
        await self.rb.write_dword(self.addr_hi_reg, (dma_addr >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(self.capacity_reg, slot_capacity)

        self.dma_addr = dma_addr
        self.slot_capacity = slot_capacity
        self.region = region

    async def arm(self) -> None:
        await self.queue.assert_buffer_configurable(self.index)
        status = await self.read_status()

        if status & CommitBufferStatus.ARMED:
            raise SSRDeviceBusyError(f"Commit buffer {self.index} is already armed")

        if status & (CommitBufferStatus.DONE | CommitBufferStatus.ERROR):
            raise SSRDeviceBusyError(f"Commit buffer {self.index} has uncleared status")

        await self.rb.write_dword(self.control_reg, int(CommitBufferControl.ARM))

    async def clear_status(self) -> None:
        await self.queue.assert_buffer_configurable(self.index)
        status = await self.read_status()

        if status & CommitBufferStatus.ARMED:
            raise SSRDeviceBusyError(f"Commit buffer {self.index} is armed; status cannot be cleared safely")

        await self.rb.write_dword(self.control_reg, int(CommitBufferControl.CLEAR_STATUS))

    async def wait_done(self, *, timeout_polls: int = 2000) -> int:
        value = await poll_register(
            self.rb,
            self.status_reg,
            lambda status: bool(
                status
                & int(CommitBufferStatus.DONE | CommitBufferStatus.ERROR)
            ),
            timeout_polls=timeout_polls,
            description=f"commit buffer {self.index} completion",
        )

        status = CommitBufferStatus(value)
        if status & CommitBufferStatus.ERROR:
            error_count = await self.error_count()
            raise SSRHardwareError(
                f"Commit buffer {self.index} DMA failed: "
                f"status=0x{value:08x}, error_count={error_count}"
            )

        return await self.completed_count()

    async def release_and_rearm(self) -> None:
        """Release a consumed DONE buffer and arm it for its next turn."""
        status = await self.read_status()
        if not status & CommitBufferStatus.DONE:
            raise SSRDeviceBusyError(
                f"Commit buffer {self.index} is not DONE"
            )

        await self.clear_status()
        await self.arm()


class CommitQueue:
    """Driver-side control of the FPGA-to-host commit DMA writer."""

    def __init__(self, driver: "Driver") -> None:
        self.driver = driver
        self.rb = driver.rb

        self.buffers = (
            CommitBuffer(
                self,
                0,
                addr_lo_reg=COMMIT_DMA_REG_BUF0_ADDR_LO,
                addr_hi_reg=COMMIT_DMA_REG_BUF0_ADDR_HI,
                capacity_reg=COMMIT_DMA_REG_BUF0_SLOT_CAPACITY,
                control_reg=COMMIT_DMA_REG_BUF0_CONTROL,
                status_reg=COMMIT_DMA_REG_BUF0_STATUS,
                completed_reg=COMMIT_DMA_REG_BUF0_COMPLETED_COUNT,
                error_reg=COMMIT_DMA_REG_BUF0_ERROR_COUNT,
            ),
            CommitBuffer(
                self,
                1,
                addr_lo_reg=COMMIT_DMA_REG_BUF1_ADDR_LO,
                addr_hi_reg=COMMIT_DMA_REG_BUF1_ADDR_HI,
                capacity_reg=COMMIT_DMA_REG_BUF1_SLOT_CAPACITY,
                control_reg=COMMIT_DMA_REG_BUF1_CONTROL,
                status_reg=COMMIT_DMA_REG_BUF1_STATUS,
                completed_reg=COMMIT_DMA_REG_BUF1_COMPLETED_COUNT,
                error_reg=COMMIT_DMA_REG_BUF1_ERROR_COUNT,
            ),
        )

    def buffer(self, index: int) -> CommitBuffer:
        if index not in (0, 1):
            raise ValueError("commit buffer index must be 0 or 1")
        return self.buffers[index]

    async def read_status(self) -> CommitGlobalStatus:
        value = await self.rb.read_dword(COMMIT_DMA_REG_STATUS)
        return CommitGlobalStatus(int(value))

    async def active_buffer(self) -> int:
        value = await self.rb.read_dword(COMMIT_DMA_REG_ACTIVE_BUFFER)
        return int(value) & 0x1

    async def assert_buffer_configurable(self, buffer_index: int) -> None:
        """Enforce the software/FPGA ownership contract.

        An inactive buffer can be configured while the writer is busy.  The
        active buffer can also be configured or armed while the writer is
        explicitly WAITING_ARMED_BUFFER.  Otherwise the active buffer belongs
        to the FPGA and software must not modify it.
        """
        self.buffer(buffer_index)
        status = await self.read_status()

        if not status & CommitGlobalStatus.BUSY:
            return

        active = await self.active_buffer()
        if active != buffer_index:
            return

        if status & CommitGlobalStatus.WAITING_ARMED_BUFFER:
            return

        raise SSRDeviceBusyError(
            f"Commit buffer {buffer_index} is active and owned by the FPGA"
        )

    async def configure_stride(self, stride: int) -> None:
        _validate_u64(stride, "stride")
        if stride == 0:
            raise ValueError("stride must be positive")

        status = await self.read_status()
        if status & CommitGlobalStatus.BUSY:
            raise SSRDeviceBusyError(
                "Commit writer is busy; stride cannot be changed"
            )

        await self.rb.write_dword(
            COMMIT_DMA_REG_STRIDE_LO, stride & 0xFFFFFFFF
        )
        await self.rb.write_dword(
            COMMIT_DMA_REG_STRIDE_HI, (stride >> 32) & 0xFFFFFFFF
        )

    async def start(self) -> None:
        status = await self.read_status()
        if status & CommitGlobalStatus.BUSY:
            raise SSRDeviceBusyError(
                "Commit DMA writer is already running"
            )

        await self.rb.write_dword(
            COMMIT_DMA_REG_CONTROL, int(CommitGlobalControl.START)
        )

    async def stop(
        self,
        *,
        wait: bool = True,
        timeout_polls: int = 2000,
    ) -> None:
        await self.rb.write_dword(
            COMMIT_DMA_REG_CONTROL, int(CommitGlobalControl.STOP)
        )
        if wait:
            await self.wait_idle(
                timeout_polls=timeout_polls,
            )

    async def wait_idle(
        self,
        *,
        timeout_polls: int = 2000,
    ) -> CommitGlobalStatus:
        value = await poll_register(
            self.rb,
            COMMIT_DMA_REG_STATUS,
            lambda status: not bool(
                status & int(CommitGlobalStatus.BUSY)
            ),
            timeout_polls=timeout_polls,
            description="commit DMA writer idle",
        )
        return CommitGlobalStatus(value)

    async def wait_for_armed_buffer(
        self,
        *,
        timeout_polls: int = 2000,
    ) -> CommitGlobalStatus:
        value = await poll_register(
            self.rb,
            COMMIT_DMA_REG_STATUS,
            lambda status: bool(
                status & int(CommitGlobalStatus.WAITING_ARMED_BUFFER)
            ),
            timeout_polls=timeout_polls,
            description="commit writer waiting for an armed buffer",
        )
        return CommitGlobalStatus(value)


# -----------------------------------------------------------------------------
# Test-only shadow-dataplane controls
# -----------------------------------------------------------------------------

class SSRTestControl:
    """Access to proposal_buffer_sink and commit_generator test registers.

    These controls are kept separate because they do not belong to the future
    production auxiliary driver.
    """

    def __init__(self, driver: "Driver") -> None:
        self.driver = driver
        self.rb = driver.rb
        self._proposal_sink_enabled = False

    async def set_proposal_sink_enabled(self, enabled: bool) -> None:
        self._proposal_sink_enabled = bool(enabled)
        value = (
            int(ProposalSinkControl.ENABLE)
            if self._proposal_sink_enabled
            else 0
        )
        await self.rb.write_dword(COMMON_REG_PROPOSAL_SINK_CONTROL, value)

    async def clear_proposal_sink(self) -> None:
        base = (
            int(ProposalSinkControl.ENABLE)
            if self._proposal_sink_enabled
            else 0
        )
        await self.rb.write_dword(
            COMMON_REG_PROPOSAL_SINK_CONTROL,
            base | int(ProposalSinkControl.CLEAR),
        )
        await self.rb.write_dword(COMMON_REG_PROPOSAL_SINK_CONTROL, base)

    async def proposal_sink_counts(self) -> tuple[int, int, int]:
        slots = int(
            await self.rb.read_dword(COMMON_REG_PROPOSAL_SINK_SLOT_COUNT)
        )
        beats = int(
            await self.rb.read_dword(COMMON_REG_PROPOSAL_SINK_BEAT_COUNT)
        )
        errors = int(
            await self.rb.read_dword(COMMON_REG_PROPOSAL_SINK_ERROR_COUNT)
        )
        return slots, beats, errors

    async def wait_proposal_sink_slots(
        self,
        expected_slots: int,
        *,
        timeout_polls: int = 2000,
    ) -> int:
        _validate_u32(expected_slots, "expected_slots")
        return await poll_register(
            self.rb,
            COMMON_REG_PROPOSAL_SINK_SLOT_COUNT,
            lambda count: count >= expected_slots,
            timeout_polls=timeout_polls,
            description=f"proposal sink to receive {expected_slots} slots",
        )

    async def clear_commit_generator(self) -> None:
        await self.rb.write_dword(
            COMMON_REG_COMMIT_GEN_CONTROL,
            int(CommitGeneratorControl.CLEAR),
        )
        await self.rb.write_dword(COMMON_REG_COMMIT_GEN_CONTROL, 0)

    async def start_commit_generator(
        self,
        count: int,
        *,
        clear_first: bool = True,
    ) -> None:
        _validate_u32(count, "count")
        if count == 0:
            raise ValueError("count must be positive")

        status = CommitGeneratorStatus(
            int(await self.rb.read_dword(COMMON_REG_COMMIT_GEN_STATUS))
        )
        if status & CommitGeneratorStatus.BUSY:
            raise SSRDeviceBusyError("Commit generator is already running")

        if clear_first:
            await self.clear_commit_generator()

        await self.rb.write_dword(COMMON_REG_COMMIT_GEN_COUNT, count)
        await self.rb.write_dword(
            COMMON_REG_COMMIT_GEN_CONTROL,
            int(CommitGeneratorControl.START),
        )

    async def stop_commit_generator(self) -> None:
        await self.rb.write_dword(
            COMMON_REG_COMMIT_GEN_CONTROL,
            int(CommitGeneratorControl.STOP),
        )

    async def wait_commit_generator_done(
        self,
        *,
        timeout_polls: int = 2000,
    ) -> CommitGeneratorStatus:
        value = await poll_register(
            self.rb,
            COMMON_REG_COMMIT_GEN_STATUS,
            lambda status: bool(
                status & int(CommitGeneratorStatus.DONE)
            ),
            timeout_polls=timeout_polls,
            description="commit generator completion",
        )
        return CommitGeneratorStatus(value)

    async def commit_generator_counts(self) -> tuple[int, int]:
        slots = int(
            await self.rb.read_dword(
                COMMON_REG_COMMIT_GEN_GENERATED_SLOT_COUNT
            )
        )
        beats = int(
            await self.rb.read_dword(
                COMMON_REG_COMMIT_GEN_GENERATED_BEAT_COUNT
            )
        )
        return slots, beats


# -----------------------------------------------------------------------------
#               Top-level SSR auxiliary-driver model
# -----------------------------------------------------------------------------

class Driver:
    """
    Cocotb model of the SSR auxiliary application driver.
    """

    def __init__(self) -> None:
        self.log = SimLog("cocotb.ssr_dataplane")

        # Resources borrowed from the already initialized parent MQNIC driver.
        self.mdev: Any = None
        self.pool: Any = None
        self.app_hw_regs: Any = None

        # SSR state created by probe().
        self.reg_blocks = mqnic.RegBlockList()
        self.ssr_rb: Any = None
        self.rb: Any = None
        self._proposal: ProposalQueue | None = None
        self._commit: CommitQueue | None = None
        self._test: SSRTestControl | None = None

        self.bound = False

    @property
    def proposal(self) -> ProposalQueue:
        if self._proposal is None:
            raise SSRDriverError("SSR auxiliary driver is not bound")
        return self._proposal

    @property
    def commit(self) -> CommitQueue:
        if self._commit is None:
            raise SSRDriverError("SSR auxiliary driver is not bound")
        return self._commit

    @property
    def test(self) -> SSRTestControl:
        if self._test is None:
            raise SSRDriverError("SSR auxiliary driver is not bound")
        return self._test

    async def probe(self, mqnic_driver: Any, *, run_self_test: bool = True) -> None:
        """
        Bind to an already initialized parent :class:`mqnic.Driver`.
        """
        self.log.info("Probing SSR auxiliary driver")
        assert not self.bound, "SSR auxiliary driver is already bound"
        assert mqnic_driver is not None, "parent mqnic driver is required"
        assert mqnic_driver.initialized, "parent mqnic driver must be initialized"
        assert mqnic_driver.app_hw_regs is not None, "parent mqnic driver must expose an application BAR"

        self.mdev = mqnic_driver
        self.pool = mqnic_driver.pool
        self.app_hw_regs = mqnic_driver.app_hw_regs

        try:
            await self._probe_common(run_self_test=run_self_test)
        except Exception:
            self._clear_binding()
            raise

        self.bound = True
        self.log.info("SSR auxiliary driver bound successfully")

    async def _probe_common(self, *, run_self_test: bool) -> None:
        """Enumerate the application BAR and create SSR child objects."""
        self.log.info("Enumerating SSR application register blocks")
        self.reg_blocks = mqnic.RegBlockList()
        await self.reg_blocks.enumerate_reg_blocks(self.app_hw_regs)

        self.ssr_rb = self.reg_blocks.find(SSR_RB_TYPE, SSR_RB_VERSION)
        if self.ssr_rb is None:
            raise SSRDriverProbeError("SSR application register block was not found")

        self.rb = self.ssr_rb
        self._proposal = ProposalQueue(self)
        self._commit = CommitQueue(self)
        self._test = SSRTestControl(self)

        await self.validate_identity()
        self.log.info("Validating proposal queue identity")
        await self._proposal.validate_identity()

        if run_self_test:
            await self.self_test()

    async def remove(self) -> None:
        """Detach the SSR auxiliary driver from its parent MQNIC device."""
        if not self.bound:
            return

        self._clear_binding()
        self.log.info("SSR auxiliary driver removed")

    def _clear_binding(self) -> None:
        self._test = None
        self._commit = None
        self._proposal = None

        self.rb = None
        self.ssr_rb = None
        self.reg_blocks = mqnic.RegBlockList()

        self.app_hw_regs = None
        self.pool = None
        self.mdev = None
        self.bound = False

    async def validate_identity(self) -> None:
        rb_type = int(await self.rb.read_dword(COMMON_REG_TYPE))
        rb_version = int(await self.rb.read_dword(COMMON_REG_VERSION))
        rb_features = int(await self.rb.read_dword(COMMON_REG_FEATURES))

        if rb_type != SSR_RB_TYPE:
            raise SSRDriverProbeError(
                f"SSR type mismatch: expected 0x{SSR_RB_TYPE:08x}, "
                f"got 0x{rb_type:08x}"
            )
        if rb_version != SSR_RB_VERSION:
            raise SSRDriverProbeError(
                f"SSR version mismatch: expected 0x{SSR_RB_VERSION:08x}, "
                f"got 0x{rb_version:08x}"
            )
        if rb_features & SSR_RB_FEATURES != SSR_RB_FEATURES:
            raise SSRDriverProbeError(
                f"SSR feature mismatch: required 0x{SSR_RB_FEATURES:08x}, "
                f"got 0x{rb_features:08x}"
            )

    async def self_test(self, pattern: int = 0x12345678) -> None:
        _validate_u32(pattern, "pattern")

        old_value = int(await self.rb.read_dword(COMMON_REG_SCRATCH))
        await self.rb.write_dword(COMMON_REG_SCRATCH, pattern)
        readback = int(await self.rb.read_dword(COMMON_REG_SCRATCH))
        await self.rb.write_dword(COMMON_REG_SCRATCH, old_value)

        if readback != pattern:
            raise SSRDriverProbeError(
                f"SSR scratch self-test failed: wrote 0x{pattern:08x}, "
                f"read 0x{readback:08x}"
            )

    async def read_common_status(self) -> CommonStatus:
        value = await self.rb.read_dword(COMMON_REG_STATUS)
        return CommonStatus(int(value))

    async def configure_replica(
        self,
        *,
        replica_id: int,
        replica_num: int,
        round_length_ns: int,
        ethernet_type: int,
    ) -> None:
        _validate_u32(replica_id, "replica_id")
        _validate_u32(replica_num, "replica_num")
        _validate_u32(round_length_ns, "round_length_ns")
        _validate_u32(ethernet_type, "ethernet_type")

        if replica_num == 0 or replica_num > COMMON_MAX_REPLICAS:
            raise ValueError(
                f"replica_num must be in [1, {COMMON_MAX_REPLICAS}]"
            )
        if replica_id >= replica_num:
            raise ValueError("replica_id must be smaller than replica_num")
        if round_length_ns == 0:
            raise ValueError("round_length_ns must be positive")

        await self.rb.write_dword(
            COMMON_REG_CONFIG_REPLICA_ID, replica_id
        )
        await self.rb.write_dword(
            COMMON_REG_CONFIG_REPLICA_NUM, replica_num
        )
        await self.rb.write_dword(
            COMMON_REG_CONFIG_ROUND_LEN_NS, round_length_ns
        )
        await self.rb.write_dword(
            COMMON_REG_CONFIG_ETH_TYPE, ethernet_type
        )

    @staticmethod
    def _mac_to_int(
        mac: int | bytes | bytearray | list[int] | tuple[int, ...],
    ) -> int:
        if isinstance(mac, int):
            if mac < 0 or mac > 0xFFFFFFFFFFFF:
                raise ValueError("MAC integer must fit in 48 bits")
            return mac

        raw = bytes(mac)
        if len(raw) != 6:
            raise ValueError("MAC address must contain exactly 6 bytes")
        return int.from_bytes(raw, byteorder="big")

    async def write_mac_address(self, index: int, mac: int | bytes | bytearray | list[int] | tuple[int, ...]) -> None:
        if index < 0 or index >= COMMON_MAX_REPLICAS:
            raise ValueError(f"MAC-table index must be in [0, {COMMON_MAX_REPLICAS - 1}]")

        value = self._mac_to_int(mac)
        offset = index * COMMON_MAC_ENTRY_STRIDE
        await self.rb.write_dword(
            COMMON_REG_CONFIG_MACTABLE_ADDR_LO + offset,
            value & 0xFFFFFFFF,
        )
        await self.rb.write_dword(
            COMMON_REG_CONFIG_MACTABLE_ADDR_HI + offset,
            (value >> 32) & 0xFFFF,
        )

    async def read_mac_address(self, index: int) -> int:
        if index < 0 or index >= COMMON_MAX_REPLICAS:
            raise ValueError(f"MAC-table index must be in [0, {COMMON_MAX_REPLICAS - 1}]")

        offset = index * COMMON_MAC_ENTRY_STRIDE
        lo = int(
            await self.rb.read_dword(
                COMMON_REG_CONFIG_MACTABLE_ADDR_LO + offset
            )
        )
        hi = int(
            await self.rb.read_dword(
                COMMON_REG_CONFIG_MACTABLE_ADDR_HI + offset
            )
        )
        return ((hi & 0xFFFF) << 32) | lo

    def alloc_dma_region(self, size: int, *, fill: int | None = None) -> Any:
        assert self.bound and self.pool is not None, "SSR auxiliary driver must be bound to a DMA-capable parent"
        assert size > 0, "size must be positive"

        region = self.pool.alloc_region(size)
        if fill is not None:
            if fill < 0 or fill > 0xFF:
                raise ValueError("fill must be an 8-bit value")
            region[:] = bytes([fill]) * size
        return region

    @staticmethod
    def dma_address(region: Any, offset: int = 0) -> int:
        if offset < 0:
            raise ValueError("offset must be non-negative")
        return int(region.get_absolute_address(offset))


__all__ = [
    "Driver",
    "ProposalQueue",
    "CommitQueue",
    "CommitBuffer",
    "SSRTestControl",
    "SSRDriverError",
    "SSRDriverProbeError",
    "SSRDriverTimeoutError",
    "SSRDeviceBusyError",
    "SSRHardwareError",
    "CommonStatus",
    "ProposalControl",
    "ProposalStatus",
    "CommitGlobalControl",
    "CommitGlobalStatus",
    "CommitBufferControl",
    "CommitBufferStatus",
    "ProposalSinkControl",
    "CommitGeneratorControl",
    "CommitGeneratorStatus",
    "poll_register",
]
