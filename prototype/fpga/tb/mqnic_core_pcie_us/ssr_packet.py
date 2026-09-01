"""SSR wire format - Python mirror of rtl/ssr_packet.vh.

Both files describe the same bytes. They have disagreed three ways before (a
64-bit run_id in the old consensus_tx, a 32-bit one here, different field orders
in both), which is why the layout now lives in exactly two places that name each
other. Change one, change the other.

    offset  size  field
    ------  ----  -----------------------------------------------------------
         0     6  destination MAC
         6     6  source MAC
        12     2  ethertype - 0x88B5, IEEE 802 local experimental. The frame is
                  identified by this alone; there is no magic or version field.
    ---------------- consensus header, 16 bytes ----------------
        14     1  node_id      sender's replica id
        15     1  row          sender's observation of the PREVIOUS round:
                               "these are the peers I heard from". NOT the
                               sender's sound set - see core.v SECTION 3.
        16     4  run_id       fences configurations; a mismatch is dropped
        20     8  round_id     the round this proposal belongs to
        28     2  length       payload bytes that follow, excluding all headers.
                               ZERO means the sender had nothing to propose and
                               the frame is header-only.
    ---------------- reserved ----------------
        30    34  zero. Padding that pushes the payload to a beat boundary.
    ---------------- payload ----------------
        64     N  proposal payload

Multi-byte fields are network byte order.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

ETHERTYPE = 0x88B5

OFF_DST_MAC = 0
OFF_SRC_MAC = 6
OFF_ETHERTYPE = 12
OFF_NODE_ID = 14
OFF_ROW = 15
OFF_RUN_ID = 16
OFF_ROUND_ID = 20
OFF_LENGTH = 28
OFF_RESERVED = 30
OFF_PAYLOAD = 64

ETH_HEADER_BYTES = 14
# node_id B, row B, run_id I, round_id Q, length H
CONSENSUS_HEADER = struct.Struct("!BBIQH")
CONSENSUS_HEADER_BYTES = CONSENSUS_HEADER.size
HEADER_USED_BYTES = ETH_HEADER_BYTES + CONSENSUS_HEADER_BYTES   # 30 carry fields
# The header occupies exactly one 512-bit beat. Padding it to the beat boundary
# is what lets frame beat k be proposal_buffer row k-1 byte for byte, so neither
# tx_engine nor rx_engine needs a barrel shifter. See rtl/ssr_packet.vh.
HEADER_BEAT_BYTES = 64
HEADER_BYTES = HEADER_BEAT_BYTES

# Ethernet pads to 60 bytes before the FCS.
MIN_FRAME_BYTES = 60

# A payload this size or smaller keeps the whole frame inside one 512-bit beat,
# so the datapath needs no barrel shifter. Worth staying under.
SINGLE_BEAT_PAYLOAD_BYTES = 64 - HEADER_BYTES     # 34

assert OFF_PAYLOAD == HEADER_BYTES
assert CONSENSUS_HEADER_BYTES == 16


@dataclass
class SSRFrame:
    dst_mac: str
    src_mac: str
    eth_type: int

    node_id: int
    row: int
    run_id: int
    round_id: int
    payload: bytes

    @property
    def length(self) -> int:
        return len(self.payload)


def encode_consensus_header(*, node_id: int, row: int, run_id: int,
                            round_id: int, length: int) -> bytes:
    """The 16 field bytes only. Callers that build a whole frame must pad the
    header out to HEADER_BEAT_BYTES - see encode_header_beat."""
    return CONSENSUS_HEADER.pack(node_id, row, run_id, round_id, length)


def encode_header_beat(*, dst_mac: bytes, src_mac: bytes, node_id: int, row: int,
                       run_id: int, round_id: int, length: int) -> bytes:
    """One complete 64-byte header beat, reserved bytes zeroed."""
    beat = (bytes(dst_mac) + bytes(src_mac) + ETHERTYPE.to_bytes(2, "big")
            + encode_consensus_header(node_id=node_id, row=row, run_id=run_id,
                                      round_id=round_id, length=length))
    assert len(beat) == HEADER_USED_BYTES
    return beat + b"\x00" * (HEADER_BEAT_BYTES - HEADER_USED_BYTES)


def decode_consensus_header(raw: bytes) -> tuple[int, int, int, int, int]:
    """-> (node_id, row, run_id, round_id, length)"""
    return CONSENSUS_HEADER.unpack(raw)
