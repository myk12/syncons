// SSR wire format - the single source of truth.
//
// tx_engine, rx_engine, the cocotb harness and the host driver all describe the
// same bytes. They have disagreed three ways before (a 64-bit run_id in the old
// consensus_tx, a 32-bit one in the harness, different field orders in both), so
// the offsets live here and nowhere else. The Python mirror is
// tb/mqnic_core_pcie_us/ssr_packet.py; keep the two in step.
//
//   offset  size  field
//   ------  ----  ---------------------------------------------------------
//        0     6  destination MAC
//        6     6  source MAC
//       12     2  ethertype - 0x88B5, IEEE 802 local experimental. The frame is
//                 identified by this alone; there is no magic or version field.
//   ---------------- consensus header, 16 bytes ----------------
//       14     1  node_id      sender's replica id
//       15     1  row          sender's observation of the PREVIOUS round:
//                              "these are the peers I heard from". NOT the
//                              sender's sound set - see core.v SECTION 3.
//       16     4  run_id       fences configurations; a mismatch is dropped
//       20     8  round_id     the round this proposal belongs to
//       28     2  length       payload bytes that follow, excluding all headers.
//                              ZERO means the node had nothing to propose and
//                              the frame is header-only - see "empty" below.
//   ---------------- reserved ----------------
//       30    34  zero. Padding that pushes the payload to a beat boundary.
//   ---------------- payload ----------------
//       64     N  proposal payload
//
// Multi-byte fields are network byte order (big-endian), matching the harness.
//
// WHY THE HEADER IS PADDED TO 64 BYTES
//   The header used to end at byte 30 and the payload started there, which was
//   right while a frame was a single beat: at a 32-byte payload the whole frame
//   was 62 bytes, fitted one 512-bit beat, and the datapath needed no barrel
//   shifter at all. Padding to 32 would only have shrunk the single-beat payload
//   budget from 34 bytes to 32, so it bought nothing.
//
//   Multi-beat changes the arithmetic completely. proposal_buffer hands out
//   64-byte rows on a 512-bit datapath, so a payload starting at byte 30 puts
//   every buffer row 30 bytes out of phase with every frame beat, and each beat
//   has to be assembled from two rows - a 64-byte barrel shifter plus a carry
//   register on the transmit side, and the same again in reverse on receive.
//   Padding the header to exactly one beat makes beat 0 the header and beat k
//   the buffer's row k-1, byte for byte, with no shifting anywhere.
//
//   It costs 34 bytes per frame. At the 1 KiB payload this path is built for
//   that is 3%, against two barrel shifters and the timing closure they would
//   need. At the old 32-byte payload it would have been 50%, which is why the
//   layout only makes sense once the frame spans beats.
//
// A HEADER-ONLY FRAME IS LEGAL AND MEANS "NOTHING TO PROPOSE"
//   A node that stays silent because its proposal queue is empty looks dead to
//   its peers, who drop it from their sound sets and evict it. So a frame goes
//   out every round no matter what, and an empty queue is expressed as
//   length = 0 with no payload beats. That frame is 64 bytes, which already
//   clears the 60-byte Ethernet minimum, so nothing has to pad it.
//
//   This is why the length field is load-bearing now rather than decorative:
//   before, every frame carried exactly P_PAYLOAD_BYTES and the receiver could
//   assume it. Now length is the only thing distinguishing "proposed nothing"
//   from "proposed a payload that happens to be zeros".

// NO include guard, deliberately.
//
// These are localparams, so each module needs its own copy inside its own scope
// - the include belongs after the module header, not at file top. A guard would
// make every include after the first a silent no-op, and the second module would
// fail to elaborate with "unable to bind SSR_OFF_...". Including this file twice
// in one module is a duplicate-declaration error, which is what you want.

localparam [15:0] SSR_ETHERTYPE = 16'h88B5;

// byte offsets
localparam integer SSR_OFF_DST_MAC   = 0;
localparam integer SSR_OFF_SRC_MAC   = 6;
localparam integer SSR_OFF_ETHERTYPE = 12;
localparam integer SSR_OFF_NODE_ID   = 14;
localparam integer SSR_OFF_ROW       = 15;
localparam integer SSR_OFF_RUN_ID    = 16;
localparam integer SSR_OFF_ROUND_ID  = 20;
localparam integer SSR_OFF_LENGTH    = 28;
localparam integer SSR_OFF_RESERVED  = 30;
localparam integer SSR_OFF_PAYLOAD   = 64;

localparam integer SSR_ETH_HDR_BYTES = 14;
localparam integer SSR_CON_HDR_BYTES = 16;
localparam integer SSR_HDR_USED_BYTES = SSR_OFF_RESERVED;   // 30 bytes carry fields
localparam integer SSR_HDR_BYTES      = SSR_OFF_PAYLOAD;    // 64 bytes on the wire

// The header occupies exactly one beat of a 512-bit datapath. Everything about
// the multi-beat layout follows from this equality; assert it where used.
localparam integer SSR_HDR_BEAT_BYTES = 64;

// field widths in bits
localparam integer SSR_W_NODE_ID  = 8;
localparam integer SSR_W_ROW      = 8;
localparam integer SSR_W_RUN_ID   = 32;
localparam integer SSR_W_ROUND_ID = 64;
localparam integer SSR_W_LENGTH   = 16;

// Ethernet pads to 60 bytes before FCS; below that the MAC must pad anyway.
// The header beat is 64, so no SSR frame is ever short enough to need it.
localparam integer SSR_MIN_FRAME_BYTES = 60;
