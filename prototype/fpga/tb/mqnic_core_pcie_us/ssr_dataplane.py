#!/usr/bin/env python3
"""
Cocotb driver model for the SSR Corundum application dataplane.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from dataclasses import dataclass
from enum import IntFlag, Enum, auto, IntEnum
from typing import Any

from matplotlib.pyplot import get

import cocotb
from cocotb.log import SimLog
from cocotb.triggers import Timer
from cocotb.utils import get_sim_time
from cocotb.queue import Queue

import mqnic


# ----------------------------------------------------------
# Application identity and address regions
# ----------------------------------------------------------

SSR_RB_TYPE     = 0x53535201
SSR_RB_VERSION  = 0x00000100
SSR_RB_FEATURES = 0x0000000F

RBB_COMMON          = 0x00000000
RBB_PROPOSAL_QUEUE  = 0x00001000
RBB_COMMIT_QUEUE    = 0x00002000
RBB_CONSENSUS_CORE  = 0x00003000


# ----------------------------------------------------------
#               Common register block
# ----------------------------------------------------------

COMMON_REG_TYPE         = RBB_COMMON + 0x000
COMMON_REG_VERSION      = RBB_COMMON + 0x004
COMMON_REG_NEXT_PTR     = RBB_COMMON + 0x008
COMMON_REG_FEATURES     = RBB_COMMON + 0x00C
COMMON_REG_CONTROL      = RBB_COMMON + 0x010
COMMON_REG_STATUS       = RBB_COMMON + 0x014
COMMON_REG_ERROR        = RBB_COMMON + 0x018
COMMON_REG_SCRATCH      = RBB_COMMON + 0x01C

COMMON_REG_CONFIG_REPLICA_ID    = RBB_COMMON + 0x020
COMMON_REG_CONFIG_REPLICA_NUM   = RBB_COMMON + 0x024
COMMON_REG_CONFIG_ROUND_LEN_NS  = RBB_COMMON + 0x028
COMMON_REG_CONFIG_ETH_TYPE      = RBB_COMMON + 0x02C

COMMON_REG_CONFIG_MACTABLE_ADDR_LO = RBB_COMMON + 0x100
COMMON_REG_CONFIG_MACTABLE_ADDR_HI = RBB_COMMON + 0x104
COMMON_MAC_ENTRY_STRIDE     = 8
COMMON_MAX_REPLICAS         = 7

# ----------------------------------------------------------
#            Proposal DMA queue
# ----------------------------------------------------------

PROPOSAL_MAGIC = 0x70726F71  # "proq"
PROPOSAL_VERSION = 0x00000100

REG_PROPOSAL_MAGIC          = RBB_PROPOSAL_QUEUE + 0x000
REG_PROPOSAL_VERSION        = RBB_PROPOSAL_QUEUE + 0x004
REG_PROPOSAL_FEATURES       = RBB_PROPOSAL_QUEUE + 0x008
REG_PROPOSAL_SLOT_BYTES     = RBB_PROPOSAL_QUEUE + 0x00C

REG_PROPOSAL_CONTROL         = RBB_PROPOSAL_QUEUE + 0x010
REG_PROPOSAL_STATUS          = RBB_PROPOSAL_QUEUE + 0x014
REG_PROPOSAL_ENTRY_COUNTER_LO     = RBB_PROPOSAL_QUEUE + 0x018
REG_PROPOSAL_ENTRY_COUNTER_HI     = RBB_PROPOSAL_QUEUE + 0x01C

REG_PROPOSAL_DMA_ADDR_LO        = RBB_PROPOSAL_QUEUE + 0x100
REG_PROPOSAL_DMA_ADDR_HI        = RBB_PROPOSAL_QUEUE + 0x104
REG_PROPOSAL_DMA_LEN            = RBB_PROPOSAL_QUEUE + 0x108
REG_PROPOSAL_DMA_STRIDE_LO      = RBB_PROPOSAL_QUEUE + 0x10C
REG_PROPOSAL_DMA_STRIDE_HI      = RBB_PROPOSAL_QUEUE + 0x110
REG_PROPOSAL_DMA_COUNT          = RBB_PROPOSAL_QUEUE + 0x114
REG_PROPOSAL_DMA_CONTROL        = RBB_PROPOSAL_QUEUE + 0x118
REG_PROPOSAL_DMA_STATUS         = RBB_PROPOSAL_QUEUE + 0x11C
REG_PROPOSAL_DMA_ACTIVE_INDEX   = RBB_PROPOSAL_QUEUE + 0x120
REG_PROPOSAL_DMA_STATE          = RBB_PROPOSAL_QUEUE + 0x124
REG_PROPOSAL_DMA_STATUS_TAG     = RBB_PROPOSAL_QUEUE + 0x128
REG_PROPOSAL_DMA_STATUS_ERROR   = RBB_PROPOSAL_QUEUE + 0x12C
REG_PROPOSAL_DMA_STATUS_VALID   = RBB_PROPOSAL_QUEUE + 0x130

# ----------------------------------------------------------
#                   Commit DMA writer     
# ----------------------------------------------------------
COMMIT_MAGIC    = 0x636F6D71  # "comq"
COMMIT_VERSION  = 0x00000100
COMMIT_FEATURES = 0x00000001

REG_COMMIT_MAGIC            = RBB_COMMIT_QUEUE + 0x000
REG_COMMIT_VERSION          = RBB_COMMIT_QUEUE + 0x004
REG_COMMIT_FEATURES         = RBB_COMMIT_QUEUE + 0x008
REG_COMMIT_CONTROL          = RBB_COMMIT_QUEUE + 0x00C
REG_COMMIT_STATUS           = RBB_COMMIT_QUEUE + 0x010
REG_COMMIT_STRIDE_LO        = RBB_COMMIT_QUEUE + 0x014
REG_COMMIT_STRIDE_HI        = RBB_COMMIT_QUEUE + 0x018
REG_COMMIT_ACTIVE_BUFFER    = RBB_COMMIT_QUEUE + 0x01C
REG_COMMIT_BUF_SLOT_LEN     = RBB_COMMIT_QUEUE + 0x020

# buffer 0
REG_COMMIT_DMA_BUF0_ADDR_LO         = RBB_COMMIT_QUEUE + 0x100
REG_COMMIT_DMA_BUF0_ADDR_HI         = RBB_COMMIT_QUEUE + 0x104
REG_COMMIT_DMA_BUF0_SLOT_CAPACITY   = RBB_COMMIT_QUEUE + 0x108
REG_COMMIT_DMA_BUF0_CONTROL         = RBB_COMMIT_QUEUE + 0x10C
REG_COMMIT_DMA_BUF0_STATUS          = RBB_COMMIT_QUEUE + 0x110
REG_COMMIT_DMA_BUF0_COMPLETED_COUNT = RBB_COMMIT_QUEUE + 0x114
REG_COMMIT_DMA_BUF0_ERROR_COUNT     = RBB_COMMIT_QUEUE + 0x118

# buffer 1
REG_COMMIT_DMA_BUF1_ADDR_LO         = RBB_COMMIT_QUEUE + 0x200
REG_COMMIT_DMA_BUF1_ADDR_HI         = RBB_COMMIT_QUEUE + 0x204
REG_COMMIT_DMA_BUF1_SLOT_CAPACITY   = RBB_COMMIT_QUEUE + 0x208
REG_COMMIT_DMA_BUF1_CONTROL         = RBB_COMMIT_QUEUE + 0x20C
REG_COMMIT_DMA_BUF1_STATUS          = RBB_COMMIT_QUEUE + 0x210
REG_COMMIT_DMA_BUF1_COMPLETED_COUNT = RBB_COMMIT_QUEUE + 0x214
REG_COMMIT_DMA_BUF1_ERROR_COUNT     = RBB_COMMIT_QUEUE + 0x218

# ----------------------------------------------------------
#                  Consensus core
# ----------------------------------------------------------
REG_CONSENSUS_HALT              = RBB_CONSENSUS_CORE + 0x000
REG_CONSENSUS_GLOBAL_ENABLE     = RBB_CONSENSUS_CORE + 0x004
REG_CONSENSUS_RUN_ID            = RBB_CONSENSUS_CORE + 0x008
REG_CONSENSUS_MEMBERSHIP        = RBB_CONSENSUS_CORE + 0x00C
REG_CONSENSUS_ACTIVATE          = RBB_CONSENSUS_CORE + 0x010
REG_CONSENSUS_REBOOT            = RBB_CONSENSUS_CORE + 0x014

# ----------------------------------------------------------
#           Helper functions
# ----------------------------------------------------------

def _validate_u32(value: int, name: str) -> None:
    if not (0 <= value <= 0xFFFFFFFF):
        raise ValueError(f"{name} must be a 32-bit unsigned integer, got {value}")

def _validate_u64(value: int, name: str) -> None:
    if not (0 <= value <= 0xFFFFFFFFFFFFFFFF):
        raise ValueError(f"{name} must be a 64-bit unsigned integer, got {value}")

async def poll_register(read_func: Callable[[], Any], condition_func: Callable[[Any], bool], *, timeout_polls: int = 10000, what: str = "register") -> Any:
    for poll_count in range(timeout_polls):
        value = await read_func()
        if condition_func(value):
            return value
        await Timer(100, units="ns")  # wait before next poll
    raise SSRTimeoutError(f"Timeout while polling {what} after {timeout_polls} polls")

# ----------------------------------------------------------
#                   Bit definitions
# ----------------------------------------------------------
class CommonStatus(IntFlag):
    """COMMON_REG_STATUS (0x014)"""
    CONFIG_VALID = 1 << 0
    CONTROL_BIT0 = 1 << 1
    CONTROL_BIT1 = 1 << 2

class ProposalControl(IntFlag):
    START       = 1 << 0
    CLEAR_DONE  = 1 << 1
    CLEAR_ERROR = 1 << 2

class ProposalStatus(IntFlag):
    RUNNING     = 1 << 0
    DONE        = 1 << 1
    ERROR       = 1 << 2

class CommitControl(IntFlag):
    START       = 1 << 0
    STOP        = 1 << 1

class CommitBufferControl(IntFlag):
    ARM        = 1 << 0
    CLEAR      = 1 << 1

class CommitBufferStatus(IntFlag):
    ARMED      = 1 << 0
    DONE       = 1 << 1
    ERROR      = 1 << 2

# ----------------------------------------------------------
#                   Data structures
# ----------------------------------------------------------
class SSRDeviceState(IntEnum):
    UNINITIALIZED = 0
    PROBED  = 1
    OPENED  = 2
    RUNNING = 3

@dataclass(frozen=True)
class SSRConfig():
    replica_id: int
    replica_num: int
    round_length_ns: int

@dataclass(frozen=True)
class CommitRecord:
    buffer_index: int
    slot_index: int
    data: bytes
    sim_time_ns: float = 0.0

# ----------------------------------------------------------
#           Error
# ----------------------------------------------------------
class SSRError(Exception):
    """SSR auxiliary driver error"""

class SSRStateError(SSRError):
    """SSR auxiliary driver state error"""

class SSRProbeError(SSRError):
    """SSR auxiliary driver probe error"""

class SSRTimeoutError(SSRError):
    """SSR auxiliary driver timeout error"""

class SSRHardwareError(SSRError):
    """SSR auxiliary driver hardware error"""

# ----------------------------------------------------------
#       Utility functions
# ----------------------------------------------------------

# -----------------------------------------------------------------------------
#                   Proposal queue
# -----------------------------------------------------------------------------
class ProposalHardwareState(IntEnum):
    IDLE        = 0
    ISSUE_DMA   = 1
    WAIT_DMA    = 2
    COMMIT_SLOT = 3
    DONE        = 4

@dataclass(frozen=True)
class ProposalBatch:
    region: Any
    count: int
    stride: int
    offset: int

@dataclass(frozen=True)
class ProposalQueueStatus:
    running: bool
    done: bool
    error: bool

@dataclass(frozen=True)
class ProposalBatchResult:
    requested_count: int
    completed_count: int

    entry_counter_before: int
    entry_counter_after: int

    last_dma_status_valid: bool

class ProposalQueue:
    def __init__(self, device: "SSRDevice") -> None:
        self.device = device
        self.log = SimLog("cocotb.ssr_dataplane.proposal_queue")

        self.rb = device._rb
        self._opened = False

        self._slot_len: int
        self._region: Any
        self._region_slots = 0

    def _require_open(self) -> None:
        if not self._opened:
            raise SSRStateError("ProposalQueue is not opened")


    @property
    def slot_len(self) -> int:
        self._require_open()
        assert self._slot_len is not None
        return self._slot_len

    @property
    def capacity_slots(self) -> int:
        self._require_open()
        assert self._region is not None
        return self._region_slots

    async def read_slot_length(self) -> int:
        return int(await self.rb.read_dword(REG_PROPOSAL_SLOT_BYTES))
    
    async def read_status(self) -> ProposalStatus:
        return ProposalStatus(int(await self.rb.read_dword(REG_PROPOSAL_STATUS)) & 0x7)

    async def read_hw_state(self) -> ProposalHardwareState:
        raw = int(await self.rb.read_dword(REG_PROPOSAL_DMA_STATE)) & 0x7
        try:
            return ProposalHardwareState(raw)
        except ValueError:
            raise RuntimeError(f"Invalid ProposalHardwareState value: {raw}")
    
    async def read_active_index(self) -> int:
        return int(await self.rb.read_dword(REG_PROPOSAL_DMA_ACTIVE_INDEX))

    async def read_entry_counter(self) -> int:
        lo = int(await self.rb.read_dword(REG_PROPOSAL_ENTRY_COUNTER_LO))
        hi = int(await self.rb.read_dword(REG_PROPOSAL_ENTRY_COUNTER_HI))
        return (hi << 32) | lo

    async def read_dma_status(self) -> tuple[int, int, bool]:
        tag = int(await self.rb.read_dword(REG_PROPOSAL_DMA_STATUS_TAG))
        error = int(await self.rb.read_dword(REG_PROPOSAL_DMA_STATUS_ERROR))
        valid = bool(int(await self.rb.read_dword(REG_PROPOSAL_DMA_STATUS_VALID)))
        return tag, error, valid

    async def _diagnose(self) -> str:
        state = await self.read_hw_state()
        status = await self.read_status()
        idx = await self.read_active_index()
        tag, error, valid = await self.read_dma_status()

        hint = ""
        if state is ProposalHardwareState.ISSUE_DMA:
            hint = " (Stop on ISSUE_DMA: proposal_buffer may be full, check commit queue)"
        elif state is ProposalHardwareState.WAIT_DMA:
            hint = " (Stop on WAIT_DMA: DMA engine may be stalled, check commit queue)"
        elif state is ProposalHardwareState.COMMIT_SLOT:
            hint = " (Stop on COMMIT_SLOT: proposal_buffer may be full, check commit queue)"

        return (f"ProposalQueue status: state={state.name}, status={status}, "
                f"active_index={idx}, dma_tag={tag}, dma_error={error}, dma_valid={valid}{hint}")

    async def open(self, *, capacity_slots: int = 8) -> None:
        self.log.info("Opening ProposalQueue")
        if self._opened:
            raise RuntimeError("ProposalQueue is already opened")

        if capacity_slots <= 0:
            raise ValueError("ProposalQueue capacity must be positive")

        # validate identity and capabilities
        magic = int(await self.rb.read_dword(REG_PROPOSAL_MAGIC))
        version = int(await self.rb.read_dword(REG_PROPOSAL_VERSION))
        if magic != PROPOSAL_MAGIC or version != PROPOSAL_VERSION:
            raise RuntimeError("ProposalQueue identity mismatch: "
                               f"expected magic=0x{PROPOSAL_MAGIC:08x}, version=0x{PROPOSAL_VERSION:08x}, "
                               f"got magic=0x{magic:08x}, version=0x{version:08x}")

        self._slot_len = await self.read_slot_length()
        if self._slot_len <= 0:
            raise RuntimeError(f"ProposalQueue slot length is invalid: {self._slot_len}")
        
        self._region_slots = capacity_slots
        self._region = self.device.alloc_dma_region(self._slot_len * self._region_slots, fill=0x00)

        await self.clear_flags()

        self._opened = True
        self.log.info("ProposalQueue opened: slot_len=%d, capacity_slots=%d", self._slot_len, self._region_slots)
    
    async def close(self) -> None:
        self._require_open()
        self._opened = False
        self._region = None
        self._region_slots = 0
    
    def _on_parent_reset(self) -> None:
        self._opened = False
        self._region = None
        self._region_slots = 0

    async def clear_flags(self) -> None:
        await self.rb.write_dword(REG_PROPOSAL_DMA_CONTROL, int(ProposalControl.CLEAR_DONE | ProposalControl.CLEAR_ERROR))

    async def submit(self, *, dma_addr: int, count: int, stride: int) -> None:
        """Start a DMA transfer of proposals to the hardware."""
        self._require_open()
        _validate_u64(dma_addr, "dma_addr")
        _validate_u32(count, "count")
        _validate_u64(stride, "stride")

        if count == 0:
            raise ValueError("ProposalQueue submit count must be positive")

        if stride != self._slot_len:
            raise ValueError(f"ProposalQueue submit stride ({stride}) does not match slot length ({self._slot_len})")

        status = await self.read_status()
        if status & ProposalStatus.RUNNING:
            raise SSRStateError("ProposalQueue is already running a DMA transfer")

        await self.rb.write_dword(REG_PROPOSAL_DMA_ADDR_LO, dma_addr & 0xFFFFFFFF)
        await self.rb.write_dword(REG_PROPOSAL_DMA_ADDR_HI, (dma_addr >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(REG_PROPOSAL_DMA_STRIDE_LO, stride & 0xFFFFFFFF)
        await self.rb.write_dword(REG_PROPOSAL_DMA_STRIDE_HI, (stride >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(REG_PROPOSAL_DMA_COUNT, count)
        await self.rb.write_dword(REG_PROPOSAL_DMA_CONTROL, int(ProposalControl.START))

    async def wait_done(self, *, timeout_polls: int = 10000, interval_ns: int = 100) -> ProposalStatus:
        """Wait for the DMA transfer to complete, with a timeout."""
        self._require_open()

        try:
            raw = await poll_register(lambda: self.rb.read_dword(REG_PROPOSAL_STATUS),
                                      lambda x: x & ProposalStatus.DONE,
                                      timeout_polls=timeout_polls,
                                      what="proposal DMA completion")
        except SSRTimeoutError as exc:
            raise SSRTimeoutError(f"ProposalQueue DMA transfer did not complete within {timeout_polls} polls") from exc

        status = ProposalStatus(raw & 0x7)
        if status & ProposalStatus.ERROR:
            raise SSRHardwareError(f"ProposalQueue DMA transfer completed with error: status={status}")

        return status

    # High-level API for submitting proposals
    async def propose(self, records: list[bytes], *,
                      wait: bool = True,
                      timeout_polls: int = 10000) -> ProposalBatchResult | None:
        self._require_open()
        if not records:
            raise ValueError("No records provided for proposal")

        if len(records) > self._region_slots:
            raise ValueError(f"Number of records ({len(records)}) exceeds ProposalQueue capacity ({self._region_slots})")

        for i, rec in enumerate(records):
            if len(rec) != self._slot_len:
                raise ValueError(f"Record {i} length ({len(rec)}) does not match ProposalQueue slot length ({self._slot_len})")

            off = i * int(self._slot_len)
            self._region[off:off + self._slot_len] = rec
        
        entry_before = await self.read_entry_counter()

        await self.submit(dma_addr=self._region.get_absolute_address(0), count=len(records)//self._slot_len, stride=self._slot_len)

        if not wait:
            return None

        await self.wait_done(timeout_polls=timeout_polls)

        entry_after = await self.read_entry_counter()
        active_index = await self.read_active_index()
        _, _, dma_valid = await self.read_dma_status()

        delivered = entry_after - entry_before
        if delivered != len(records):
            raise SSRHardwareError(f"ProposalQueue delivered {delivered} records, expected {len(records)}")

        return ProposalBatchResult(
            requested_count=len(records),
            completed_count=delivered,
            entry_counter_before=entry_before,
            entry_counter_after=entry_after,
            last_dma_status_valid=dma_valid
        )

# -----------------------------------------------------------------------------
#                   Commit Queue
# -----------------------------------------------------------------------------
class CommitBufferState(Enum):
    UNCONFIGURED = auto()
    SOFTWARE_OWNED = auto()
    HARDWARE_OWNED = auto()
    COMPLETED = auto()
    ERROR = auto()

class CommitBuffer:
    """
    One of the ping-pong buffers used by the CommitQueue to receive committed proposals from the hardware.

    Hardware semantics:
        - armed: the buffer is owned by the hardware and can be written to
        - completed_count >= slot_capacity: the buffer has been filled by the hardware and is ready to be read by software
        - clear command: the buffer is cleared and returned to software ownership
    """
    _REGS = {
        0: dict(addr_lo=REG_COMMIT_DMA_BUF0_ADDR_LO, 
                addr_hi=REG_COMMIT_DMA_BUF0_ADDR_HI,
                capacity=REG_COMMIT_DMA_BUF0_SLOT_CAPACITY,
                control=REG_COMMIT_DMA_BUF0_CONTROL,
                status=REG_COMMIT_DMA_BUF0_STATUS,
                completed=REG_COMMIT_DMA_BUF0_COMPLETED_COUNT,
                error=REG_COMMIT_DMA_BUF0_ERROR_COUNT),
        1: dict(addr_lo=REG_COMMIT_DMA_BUF1_ADDR_LO, addr_hi=REG_COMMIT_DMA_BUF1_ADDR_HI,
                capacity=REG_COMMIT_DMA_BUF1_SLOT_CAPACITY,
                control=REG_COMMIT_DMA_BUF1_CONTROL,
                status=REG_COMMIT_DMA_BUF1_STATUS,
                completed=REG_COMMIT_DMA_BUF1_COMPLETED_COUNT,
                error=REG_COMMIT_DMA_BUF1_ERROR_COUNT),
    }

    def __init__(self, parent: "CommitQueue", *, index: int) -> None:
        if index not in self._REGS:
            raise ValueError(f"Invalid CommitBuffer index: {index}")

        self.parent = parent
        self.index = index
        self.reg = self._REGS[index]
        self.log = SimLog(f"cocotb.ssr_dataplane.commit_queue.buffer{index}")

        self._region: Any | None = None
        self._capacity: int | None = None
        self._stride: int | None = None
    
    async def configure(self, region: Any, *, capacity: int, stride: int) -> None:
        addr = region.get_absolute_address(0)

        await self.parent.rb.write_dword(self.reg["addr_lo"], addr & 0xFFFFFFFF)
        await self.parent.rb.write_dword(self.reg["addr_hi"], (addr >> 32) & 0xFFFFFFFF)
        await self.parent.rb.write_dword(self.reg["capacity"], capacity)
        await self.parent.rb.write_dword(self.reg["stride_lo"], stride & 0xFFFFFFFF)
        await self.parent.rb.write_dword(self.reg["stride_hi"], (stride >> 32) & 0xFFFFFFFF)

        self._region = region
        self._capacity = capacity
        self._stride = stride
        self.log.info("CommitBuffer %d configured: region=%s, capacity=%d, stride=%d", self.index, region, capacity, stride)

    async def read_raw_status(self) -> CommitBufferStatus:
        raw = int(await self.parent.rb.read_dword(self.reg["status"])) & 0x7
        return CommitBufferStatus(raw)

    async def read_status(self) -> CommitBufferState:
        if self._region is None:
            return CommitBufferState.UNCONFIGURED

        raw = await self.read_raw_status()
        if raw & CommitBufferStatus.DONE:
            return CommitBufferState.COMPLETED
        if raw & CommitBufferStatus.ERROR:
            return CommitBufferState.ERROR
        if raw & CommitBufferStatus.ARMED:
            return CommitBufferState.HARDWARE_OWNED
        
        return CommitBufferState.SOFTWARE_OWNED

    async def read_completed_count(self) -> int:
        return int(await self.parent.rb.read_dword(self.reg["completed"]))

    async def read_error_count(self) -> int:
        return int(await self.parent.rb.read_dword(self.reg["error"]))

    async def arm(self) -> None:
        await self.parent.rb.write_dword(self.reg["control"], int(CommitBufferControl.ARM))

    async def clear(self) -> None:
        await self.parent.rb.write_dword(self.reg["control"], int(CommitBufferControl.CLEAR))
    
    async def release_and_rearm(self) -> None:
        await self.clear()
        await self.arm()

    def read_slot(self, slot_index: int) -> bytes:
        if self._region is None or self._stride is None or self._capacity is None:
            raise RuntimeError("CommitBuffer is not configured")
    
        if not 0 <= slot_index < self._capacity:
            raise ValueError(f"CommitBuffer slot_index {slot_index} out of range [0, {self._capacity})")

        offset = slot_index * self._stride
        return bytes(self._region[offset:offset + self._stride])

    
class CommitQueue:
    """
    NIC -> Host submission queue for committed proposals. The CommitQueue uses two ping-pong buffers to receive committed proposals from the hardware. The software can read completed slots from the buffers and re-arm them for further use.
    """
    def __init__(self, device: "SSRDevice") -> None:
        self.device = device
        self.log = SimLog("cocotb.ssr_dataplane.commit_queue")

        self.rb = device._rb

        self._buffer0 = CommitBuffer(self, index=0)
        self._buffer1 = CommitBuffer(self, index=1)
        self._buffers = (self._buffer0, self._buffer1)

        self._completed = Queue()
        self._slot_len: int | None = None
        self._slot_count: int = 0

        self._opened = False
        self._running = False
        self._poll_interval_ns = 200
        self._run_error: BaseException | None = None

    def _require_open(self) -> None:
        if not self._opened:
            raise SSRStateError("CommitQueue is not opened")

    @property
    def slot_len(self) -> int:
        self._require_open()
        assert self._slot_len is not None
        return self._slot_len

    async def open(self, buf_slot_count: int) -> None:
        if self._opened:
            raise RuntimeError("CommitQueue is already opened")

        if buf_slot_count <= 0:
            raise ValueError("CommitQueue buffer slot count must be positive")
        
        magic = int(await self.rb.read_dword(REG_COMMIT_MAGIC))
        version = int(await self.rb.read_dword(REG_COMMIT_VERSION))
        if magic != COMMIT_MAGIC or version != COMMIT_VERSION:
            raise RuntimeError("CommitQueue identity mismatch: "
                               f"expected magic=0x{COMMIT_MAGIC:08x}, version=0x{COMMIT_VERSION:08x}, "
                               f"got magic=0x{magic:08x}, version=0x{version:08x}")

        self._slot_len = int(await self.rb.read_dword(REG_COMMIT_BUF_SLOT_LEN))  # assuming slot length is set in the config
        if self._slot_len <= 0:
            raise RuntimeError(f"CommitQueue slot length is invalid: {self._slot_len}")
        self._slot_count = buf_slot_count

        await self.rb.write_dword(REG_COMMIT_STRIDE_LO, self._slot_len & 0xFFFFFFFF)
        await self.rb.write_dword(REG_COMMIT_STRIDE_HI, (self._slot_len >> 32) & 0xFFFFFFFF)

        for buf in self._buffers:
            region = self.device.alloc_dma_region(self._slot_len * self._slot_count, fill=0x00)
            await buf.configure(region, capacity=self._slot_count, stride=self._slot_len)
        
        self._opened = True
        self.log.info("CommitQueue opened: slot_len=%d, buffer_slot_count=%d", self._slot_len, self._slot_count)

    async def start(self) -> None:
        self._require_open()
        if self._running:
            raise RuntimeError("CommitQueue is already running")

        for buf in self._buffers:
            await buf.clear()
            await buf.arm()
        
        await self.rb.write_dword(REG_COMMIT_CONTROL, int(CommitControl.START))

        self._run_error = None
        self._running = True
        self.log.info("CommitQueue started")
    
    async def stop(self) -> None:
        if not self._running:
            return

        await self.rb.write_dword(REG_COMMIT_CONTROL, int(CommitControl.STOP))
        self._running = False
        await self._completed.put(None)  # unblock any waiting recv()
        self.log.info("CommitQueue stopped")
    
    async def close(self) -> None:
        self._require_open()
        if self._running:
            await self.stop()

        for buf in self._buffers:
            buf._region = None
            buf._capacity = None
            buf._stride = None
        
        self._opened = False
        self._slot_len = None
        self._slot_count = 0
        self.log.info("CommitQueue closed")
    
    def _on_parent_reset(self) -> None:
        self._opened = False
        self._running = False
        self._slot_len = None
        self._slot_count = 0
        for buf in self._buffers:
            buf._region = None
            buf._capacity = None
            buf._stride = None

    async def read_global_status(self) -> CommitStatus:
        return CommitStatus(int(await self.rb.read_dword(REG_COMMIT_STATUS)) & 0x7)
    
    async def read_active_buffer(self) -> int:
        return int(await self.rb.read_dword(REG_COMMIT_ACTIVE_BUFFER)) & 0x1
    
    async def _diagnose(self) -> str:
        gs = await self.read_global_status()
        active = await self.read_active_buffer()
        parts = [f"global={gs!r} active_buffer={active}"]
        for buf in self._buffers:
            parts.append(f"buffer{buf.index}={await buf.read_status()!r}")
        return "CommitQueue status: " + ", ".join(parts)

    async def run(self) -> None:
        if not self._running:
            raise RuntimeError("CommitQueue is not running")

        self.log.info("CommitQueue run loop started")

        try:
            while self._running:
                progessed = False

                for buf in self._buffers:
                    raw = await buf.read_raw_status()

                    if not (raw & CommitBufferStatus.DONE):
                        continue

                    progessed = True

                    n = await buf.read_completed_count()
                    err = await buf.read_error_count()
                    if err > 0:
                        self.log.warning("buffer %d reports error_count=%d", buf.index, err)

                    now = get_sim_time("ns")
                    for slot_index in range(n):
                        await self._completed.put(CommitRecord(buffer_index=buf.index, slot_index=slot_index, data=buf.read_slot(slot_index), sim_time_ns=now))
                        
                    self.log.info("buffer %d: %d completed slots read and queued for processing", buf.index, n)

                    await buf.release_and_rearm()

                if not progessed:
                    await Timer(self._poll_interval_ns, units="ns")
        except Exception as e:
            self._run_error = e
            self._running = False
            self.log.error("CommitQueue run loop encountered an error: %s", e)
        finally:
            self.log.info("CommitQueue run loop exited")
        
    async def recv(self) -> CommitRecord:
        if self._run_error is not None:
            raise SSRHardwareError(f"CommitQueue run loop encountered an error: {self._run_error}") from self._run_error
    
        if not self._running:
            raise RuntimeError("CommitQueue is not running")
            
        record = await self._completed.get()
        if record is None:
            if self._run_error is not None:
                raise SSRHardwareError(f"CommitQueue run loop encountered an error: {self._run_error}") from self._run_error
            raise RuntimeError("CommitQueue has been stopped")
        return record

    async def recv_batch(self, count: int, *, timeout_ns: int = 1_000_000) -> list[CommitRecord]:
        out: list[CommitRecord] = []
        deadline = get_sim_time("ns") + timeout_ns

        while len(out) < count:
            if get_sim_time("ns") > deadline:
                raise SSRTimeoutError(f"Timeout while waiting for {count} commit records, got {len(out)}")

            if self._completed.empty():
                await Timer(100, units="ns")
                continue
        
            out.append(await self.recv())
        
        return out

# -----------------------------------------------------------------------------
#            Consensus core
# -----------------------------------------------------------------------------
class ConsensusCore:
    def __init__(self, device: "SSRDevice") -> None:
        self.device = device
        self.log = SimLog("cocotb.ssr_dataplane.consensus_core")

        self.rb = device._rb

    async def set_enabled(self, enabled: bool) -> None:
        await self.rb.write_dword(REG_CONSENSUS_GLOBAL_ENABLE, 1 if enabled else 0)

    async def is_enabled(self) -> bool:
        return bool(int(await self.rb.read_dword(REG_CONSENSUS_GLOBAL_ENABLE)) & 0x1)

    async def read_run_id(self) -> int:
        return int(await self.rb.read_dword(REG_CONSENSUS_RUN_ID))

    async def read_activate(self) -> bool:
        return bool(int(await self.rb.read_dword(REG_CONSENSUS_ACTIVATE)) & 0x1)
    
    async def read_halt(self) -> bool:
        return bool(int(await self.rb.read_dword(REG_CONSENSUS_HALT)) & 0x1)

    async def install_config(self, *, run_id: int, membership: int) -> None:
        _validate_u32(run_id, "run_id")
        _validate_u32(membership, "membership")

        await self.rb.write_dword(REG_CONSENSUS_RUN_ID, run_id)
        await self.rb.write_dword(REG_CONSENSUS_MEMBERSHIP, membership)
        await self.rb.write_dword(REG_CONSENSUS_ACTIVATE, 1)

    async def activate(self, *, run_id: int, membership: int, verify: bool = True) -> None:
        await self.install_config(run_id=run_id, membership=membership)

        if verify:
            actual_run_id = await self.read_run_id()
            actual_membership = int(await self.rb.read_dword(REG_CONSENSUS_MEMBERSHIP))
            if actual_run_id != run_id or actual_membership != membership:
                raise SSRHardwareError(f"ConsensusCore activation failed: expected run_id={run_id}, membership={membership}, got run_id={actual_run_id}, membership={actual_membership}")

        await self.rb.write_dword(REG_CONSENSUS_ACTIVATE, 1)

        self.log.info("ConsensusCore activated: run_id=%d, membership=%d", run_id, membership)

    async def deactivate(self) -> None:
        await self.rb.write_dword(REG_CONSENSUS_ACTIVATE, 0)
        self.log.info("ConsensusCore deactivated")
    
    async def reboot(self) -> None:
        await self.rb.write_dword(REG_CONSENSUS_REBOOT, 1)
        await self.rb.write_dword(REG_CONSENSUS_REBOOT, 0)

    # ---- Wait Halt ----
    async def wait_halt(self, *, timeout_polls: int = 10000) -> bool:
        try:
            await poll_register(lambda: self.rb.read_dword(REG_CONSENSUS_HALT),
                                lambda x: x & 0x1,
                                timeout_polls=timeout_polls,
                                what="consensus halt")
            return True
        except SSRTimeoutError:
            return False

    async def assert_not_halted(self) -> None:
        halted = await self.read_halt()
        if halted:
            raise SSRHardwareError("ConsensusCore is halted")

    async def _diagnose(self) -> str:
        return (f"ConsensusCore status: enabled={await self.is_enabled()}, "
                f"run_id={await self.read_run_id()}, "
                f"membership={int(await self.rb.read_dword(REG_CONSENSUS_MEMBERSHIP))}, "
                f"activate={await self.read_activate()}, "
                f"halt={await self.read_halt()}")
    
# -----------------------------------------------------------------------------
#               Top-level SSR auxiliary-driver model
# -----------------------------------------------------------------------------

class SSRDevice:
    """
    Cocotb model of the SSR auxiliary application driver.
    """

    def __init__(self) -> None:
        self.log = SimLog("cocotb.ssr_dataplane")

        self._state = SSRDeviceState.UNINITIALIZED

        # Resources borrowed from the already initialized parent MQNIC driver.
        self.mdev: Any = None
        self.mem_pool: Any = None
        self.app_hw_regs: Any = None
        self._reg_blks: Any = None

        # SSR child objects created by probe().
        self._proposal: ProposalQueue | None = None
        self._commit: CommitQueue | None = None

        self._bound = False
        self._consensus: ConsensusCore | None = None
        self._commit_task = None

    @property
    def state(self) -> SSRDeviceState:
        return self._state

    @property
    def proposal(self) -> ProposalQueue:
        if self._proposal is None:
            raise RuntimeError("ProposalQueue is not initialized")
        return self._proposal

    @property
    def commit(self) -> CommitQueue:
        if self._commit is None:
            raise RuntimeError("CommitQueue is not initialized")
        return self._commit
    
    @property
    def consensus(self) -> ConsensusCore:
        if self._consensus is None:
            raise RuntimeError("ConsensusCore is not initialized")
        return self._consensus

    def _require_state(self, *allowed_states: SSRDeviceState) -> None:
        if self._state not in allowed_states:
            raise RuntimeError(
                f"SSR auxiliary driver is in state {self._state.name}, "
                f"but one of {[s.name for s in allowed_states]} is required"
            )

    async def probe(self, mqnic_driver: Any) -> None:
        """
        Probe the SSR auxiliary device and bind it to the parent MQNIC driver.
            1. Bind to the parent MQNIC device
            2. Enumerate the register blocks in the application BAR
            3. Validate the SSR identity and features
            4. Create the ProposalQueue, CommitQueue, and SSRTestControl objects
        """
        self.log.info("Probing SSR auxiliary device")
        self._require_state(SSRDeviceState.UNINITIALIZED)

        assert mqnic_driver is not None, "parent mqnic driver is required"
        assert mqnic_driver.initialized, "parent mqnic driver must be initialized"
        assert mqnic_driver.app_hw_regs is not None, "parent mqnic driver must expose an application BAR"

        self._mdev = mqnic_driver
        self._mem_pool = mqnic_driver.rc.mem_pool
        self._app_hw_regs = mqnic_driver.app_hw_regs
        self.log.info("SSR auxiliary driver bound successfully")

        # enumerate the register blocks in the application BAR
        self.log.info("Enumerating SSR application register blocks")
        self._reg_blks = mqnic.RegBlockList()
        await self._reg_blks.enumerate_reg_blocks(self._app_hw_regs)

        # find the SSR register block and validate its identity
        self._rb = self._reg_blks.find(SSR_RB_TYPE, SSR_RB_VERSION)
        if self._rb is None:
            raise RuntimeError(
                f"SSR register block not found in application BAR; "
                f"expected type=0x{SSR_RB_TYPE:08x}, version=0x{SSR_RB_VERSION:08x}"
            )

        # create the ProposalQueue, CommitQueue, and SSRTestControl objects
        self._proposal = ProposalQueue(self)
        self._commit = CommitQueue(self)
        self._consensus = ConsensusCore(self)

        self._state = SSRDeviceState.PROBED

    async def open(self) -> None:
        """
        Open the SSR auxiliary device:
            1. Acquire control of the proposal and commit DMA engines
            2. Allocate DMA buffers
            3. Configure the proposal and commit DMA engines
            4. Initialize the producer/consumer index
            5. Make sure the hardware is ready to accept proposals and generate commits
        """
        self.log.info("Opening SSR auxiliary device")
        self._require_state(SSRDeviceState.PROBED)

        # open the proposal and commit queues
        await self._proposal.open()
        await self._commit.open(buf_slot_count=16)  # example slot count 

        self._state = SSRDeviceState.OPENED

    async def reset(self) -> None:
        """
        Reset the SSR auxiliary device:
            1. Stop the proposal and commit DMA engines
            2. Release DMA buffers
            3. Release control of the proposal and commit DMA engines
            4. Re-acquire control of the proposal and commit DMA engines
            5. Re-allocate DMA buffers
            6. Re-configure the proposal and commit DMA engines
            7. Re-initialize the producer/consumer index
            8. Make sure the hardware is ready to accept proposals and generate commits
        """
        self._require_state(SSRDeviceState.OPENED,
                            SSRDeviceState.PROBED,
                            SSRDeviceState.RUNNING,
                            SSRDeviceState.UNINITIALIZED)


        self._state = SSRDeviceState.UNINITIALIZED

    async def start(self) -> None:
        self._require_state(SSRDeviceState.OPENED)
        await self._commit.start()
        self._commit_task = cocotb.start_soon(self._commit.run())

        self._state = SSRDeviceState.RUNNING

    async def stop(self) -> None:
        self._require_state(SSRDeviceState.RUNNING)
        await self._commit.stop()
        if self._commit_task is not None:
            self._commit_task.cancel()
            self._commit_task = None
        self._state = SSRDeviceState.OPENED

    async def close(self) -> None:
        """
        Close the SSR auxiliary device:
            1. Stop the proposal and commit DMA engines
            2. Release DMA buffers
            3. Release control of the proposal and commit DMA engines
        """
        self._require_state(SSRDeviceState.OPENED)
        self._state = SSRDeviceState.PROBED

    async def remove(self) -> None:
        """
        Remove the SSR auxiliary device:
            1. Stop the proposal and commit DMA engines
            2. Release DMA buffers
            3. Release control of the proposal and commit DMA engines
            4. Unbind from the parent MQNIC driver
        """
        self._require_state(SSRDeviceState.PROBED)


        self._state = SSRDeviceState.UNINITIALIZED

    async def configure_replica(
        self,
        *,
        replica_id: int,
        replica_num: int,
        round_length_ns: int,
        ethernet_type: int,
    ) -> None:

        if replica_num == 0 or replica_num > COMMON_MAX_REPLICAS:
            raise ValueError(
                f"replica_num must be in [1, {COMMON_MAX_REPLICAS}]"
            )
        if replica_id >= replica_num:
            raise ValueError("replica_id must be smaller than replica_num")
        if round_length_ns == 0:
            raise ValueError("round_length_ns must be positive")

        await self._rb.write_dword(
            COMMON_REG_CONFIG_REPLICA_ID, replica_id
        )
        await self._rb.write_dword(
            COMMON_REG_CONFIG_REPLICA_NUM, replica_num
        )
        await self._rb.write_dword(
            COMMON_REG_CONFIG_ROUND_LEN_NS, round_length_ns
        )
        await self._rb.write_dword(
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
        await self._rb.write_dword(
            COMMON_REG_CONFIG_MACTABLE_ADDR_LO + offset,
            value & 0xFFFFFFFF,
        )
        await self._rb.write_dword(
            COMMON_REG_CONFIG_MACTABLE_ADDR_HI + offset,
            (value >> 32) & 0xFFFF,
        )

    async def read_mac_address(self, index: int) -> int:
        if index < 0 or index >= COMMON_MAX_REPLICAS:
            raise ValueError(f"MAC-table index must be in [0, {COMMON_MAX_REPLICAS - 1}]")

        offset = index * COMMON_MAC_ENTRY_STRIDE
        lo = int(
            await self._rb.read_dword(
                COMMON_REG_CONFIG_MACTABLE_ADDR_LO + offset
            )
        )
        hi = int(
            await self._rb.read_dword(
                COMMON_REG_CONFIG_MACTABLE_ADDR_HI + offset
            )
        )
        return ((hi & 0xFFFF) << 32) | lo
    
    def alloc_dma_region(self, size: int, fill: int = 0x00) -> Any:
        """
        Allocate a DMA region of the given size and fill it with the specified byte value.
        """
        if self._mem_pool is None:
            raise RuntimeError("DMA pool is not initialized")

        region = self._mem_pool.alloc_region(size)
        if region is None:
            raise RuntimeError("Failed to allocate DMA region")

        region[:] = bytes([fill] * size)
        return region
