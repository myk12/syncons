from __future__ import annotations

import struct

import ssr_packet
from typing import Any, Sequence
from dataclasses import dataclass

from scapy.layers.l2 import Ether
from scapy.packet import Raw

import cocotb
from cocotb.log import SimLog
from cocotb.queue import Queue
from cocotb.triggers import RisingEdge, ReadOnly, Timer
from sim.protocol.types import Packet

# -----------------------------
#     SSR Packet format
# -----------------------------
# Ethernet header: 14 bytes
#   Destination MAC:    6 bytes
#   Source MAC:         6 bytes
#   Ethertype:          2 bytes
# SSR custom header:
#   Run ID:             4 bytes
#   Round ID:           8 bytes
#   Node ID:            1 bytes
#   Sound set:          1 byte

@dataclass
class SSRFrame:
    """
    Represents a single SSR frame.
    """
    dst_mac: str
    src_mac: str
    eth_type: int

    run_id: int
    round_id: int
    node_id: int
    row: int

    payload: bytes

class SSRPacketCodec:
    """Thin wrapper over ssr_packet, which mirrors rtl/ssr_packet.vh.

    The layout is not defined here - it is defined once in ssr_packet.py and
    once in the .vh, and those two name each other.
    """

    ETH_HEADER_BYTES = ssr_packet.ETH_HEADER_BYTES
    SSR_HEADER_BYTES = ssr_packet.CONSENSUS_HEADER_BYTES

    # Payload that keeps the whole frame inside one 512-bit beat.
    PAYLOAD_BYTES = ssr_packet.SINGLE_BEAT_PAYLOAD_BYTES

    @classmethod
    def encode(cls, *, dst_mac:str, src_mac:str, eth_type:int, run_id:int, round_id:int, node_id:int, row:int, payload:bytes) -> bytes:
        eth_header = Ether(dst=dst_mac, src=src_mac, type=eth_type)
        ssr_header = ssr_packet.encode_consensus_header(
            node_id=node_id, row=row, run_id=run_id,
            round_id=round_id, length=len(payload),
        )
        frame = bytes(eth_header) + ssr_header + payload

        # The MAC pads short frames anyway; do it here so what the harness sends
        # is byte-for-byte what the RTL will see.
        if len(frame) < ssr_packet.MIN_FRAME_BYTES:
            frame += b"\x00" * (ssr_packet.MIN_FRAME_BYTES - len(frame))
        return frame

    @classmethod
    def decode(cls, frame:bytes) -> SSRFrame:
        if len(frame) < ssr_packet.HEADER_BYTES:
            raise ValueError("Frame is too short to contain SSR header")

        eth_header = Ether(frame[:cls.ETH_HEADER_BYTES])
        ssr_header = frame[cls.ETH_HEADER_BYTES:ssr_packet.HEADER_BYTES]
        node_id, row, run_id, round_id, length = \
            ssr_packet.decode_consensus_header(ssr_header)
        # trust the length field, not the frame size - the MAC may have padded
        payload = frame[ssr_packet.OFF_PAYLOAD:ssr_packet.OFF_PAYLOAD + length]

        return SSRFrame(
            dst_mac=eth_header.dst,
            src_mac=eth_header.src,
            eth_type=eth_header.type,
            run_id=run_id,
            round_id=round_id,
            node_id=node_id,
            row=row,
            payload=payload
        )

@dataclass(frozen=True)
class ClusterConfig:
    num_nodes: int
    mac_addresses: Sequence[str]
    eth_type: int = 0x88B5 # Custom Ethertype for SSR
    rtl_node_id: int = 0 # The node ID of the RTL SSR node under test

    def __post_init__(self):
        if self.num_nodes != len(self.mac_addresses):
            raise ValueError("Number of nodes must match the length of mac_addresses")

        if self.num_nodes > 7:
            raise ValueError("Number of nodes must be <= 7")

class SSRSimHarness:
    """
    Inject deterministic Ethernet packets into one RTL SSR node.

    Input generation is driven by the RTL consensus-core round pulse.
    The harness does not implement the SSR protocol.
    """

    def __init__(self,
                *,
                dut_port: Any,
                round_start_pulse: Any,
                round_commit_pulse: Any,
                round_id: Any,
                run_id: Any,
                cluster_config: ClusterConfig,
            ) -> None:

        self.log = SimLog(f"cocotb.SSRSimHarness")

        self._cluster_config = cluster_config
        self._dut_port = dut_port

        # Round monitor only puts batches into this queue.
        # A separate worker performs Ethernet RX injection.
        self._round_batches = Queue()

        self._running = False
        self._tasks = []

        # Round related signals
        self._round_start_pulse = round_start_pulse
        self._round_commit_pulse = round_commit_pulse
        self._round_id = round_id
        self._run_id = run_id

        # Network properties
        self._packet_interval_ns = 500
        self._received_packets = Queue()

    def start(self) -> None:
        if self._running:
            raise RuntimeError("Harness already running")

        self._running = True

        self._tasks.append(cocotb.start_soon(self._round_monitor()))
        self._tasks.append(cocotb.start_soon(self._send_packets()))
        self._tasks.append(cocotb.start_soon(self._recv_packets()))

        self.log.info("SSR simulation harness started")

    def construct_packets(self, round_id: int, run_id: int) -> list[SSRFrame]:
        config = self._cluster_config

        destination_mac = config.mac_addresses[config.rtl_node_id]
        packets = []

        for node_id in range(config.num_nodes):
            if node_id == config.rtl_node_id:
                continue

            src_mac = config.mac_addresses[node_id]
            row = (1 << config.num_nodes) - 1 # All nodes are active in this round
            payload = bytes([node_id] * SSRPacketCodec.PAYLOAD_BYTES) # Dummy payload

            packet = SSRFrame(
                dst_mac=destination_mac,
                src_mac=src_mac,
                eth_type=config.eth_type,
                run_id=run_id,
                round_id=round_id,
                node_id=node_id,
                row=row,
                payload=payload
            )
            packets.append(packet)
        return packets


    async def _round_monitor(self) -> None:
        self.log.info("Starting round monitor")
        while self._running:
            # --------------------------------------------
            #           Wait for a new round
            # --------------------------------------------
            await RisingEdge(self._round_start_pulse)

            await ReadOnly()

            round_id = int(self._round_id.value)
            run_id = int(self._run_id.value)
            packets = self.construct_packets(round_id, run_id)

            self.log.info("Starting new round: round_id=%d run_id=%d, injecting %d packets", round_id, run_id, len(packets))

            await self._round_batches.put(packets)

    async def _send_packets(self) -> None:
        self.log.info("Starting packet sender")
        while self._running:
            packets = await self._round_batches.get()

            for packet in packets:
                if self._packet_interval_ns > 0:
                    await Timer(self._packet_interval_ns, units="ns")

                frame_bytes = SSRPacketCodec.encode(
                    dst_mac=packet.dst_mac,
                    src_mac=packet.src_mac,
                    eth_type=packet.eth_type,
                    run_id=packet.run_id,
                    round_id=packet.round_id,
                    node_id=packet.node_id,
                    row=packet.row,
                    payload=packet.payload
                )

                self.log.info(f"Injecting packet: round_id={packet.round_id} run_id={packet.run_id} src_mac={packet.src_mac} dst_mac={packet.dst_mac} node_id={packet.node_id} row={packet.row}")

                await self._dut_port.rx.send(frame_bytes)

    async def _recv_packets(self) -> None:
        self.log.info("Starting packet receiver")
        while self._running:
            frame = await self._dut_port.tx.recv()

            if hasattr(frame, "data"):
                frame_bytes = bytes(frame.data)
            else:
                frame_bytes = bytes(frame)

            try:
                ssr_frame = SSRPacketCodec.decode(frame_bytes)
                self.log.info(f"Received packet: round_id={ssr_frame.round_id} run_id={ssr_frame.run_id} src_mac={ssr_frame.src_mac} dst_mac={ssr_frame.dst_mac} node_id={ssr_frame.node_id} row={ssr_frame.row}")
            except Exception as e:
                self.log.warning(f"Failed to decode received packet: {e}")
                continue

            if ssr_frame.eth_type != self._cluster_config.eth_type:
                self.log.warning(f"Received packet with unexpected Ethertype: {ssr_frame.eth_type:#04x}")

            self.log.info(
                "Received SSR packet from DUT: "
                "run_id=%d round_id=%d "
                "node_id=%d row=0x%02x "
                "src_mac=%s dst_mac=%s",
                ssr_frame.run_id,
                ssr_frame.round_id,
                ssr_frame.node_id,
                ssr_frame.row,
                ssr_frame.src_mac,
                ssr_frame.dst_mac
            )

            await self._received_packets.put(ssr_frame)

    async def recv(self) -> SSRFrame:
        """
        Wait for a packet to be received from the DUT and return it as an SSRFrame.
        """
        return await self._received_packets.get()
