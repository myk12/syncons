`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tx_engine - turns one consensus round into one Ethernet frame.
 *
 * WHAT MUST GO OUT EVERY ROUND
 *   The row, not the proposal. A node that stays silent because its proposal
 *   queue is empty looks dead to its peers, who drop it from their sound sets
 *   and evict it. So a frame is sent unconditionally; an empty queue means a
 *   header-only frame carrying length = 0, and that still counts as having
 *   proposed (the log gets an empty entry, like a Raft no-op).
 *
 * ADMISSION, NOT ABORT
 *   i_tx_window gates the START of a frame and nothing else. A frame already on
 *   the wire is never truncated - that was the old module's AXI-Stream
 *   violation. If the sub-slot ends while a frame is still going out,
 *   i_tx_end_pulse counts it as an overrun; that counter is the measurement that
 *   tells you whether TX_SUBSLOT_NS is big enough, since 400 ns was a guess.
 *
 * MULTI-BEAT
 *   beat 0      the 64-byte header (see ssr_packet.vh for why it is padded)
 *   beat 1..N   the payload, taken from proposal_buffer one row at a time
 *
 *   Because the header is exactly one beat, frame beat k is buffer row k-1 byte
 *   for byte and there is no barrel shifter anywhere on this path. That is the
 *   entire reason the header carries 34 bytes of padding; the alternative is a
 *   64-byte rotator plus a carry register here and the same again in rx_engine.
 *
 * THE PAYLOAD LENGTH BELONGS TO proposal_buffer, NOT TO THIS MODULE
 *   Both the length (i_buf_tx_len) and the end of the payload (i_buf_tx_last)
 *   come from the buffer. This module holds no slot-geometry parameter that has
 *   to be kept equal to the buffer's - P_MAX_PAYLOAD_BYTES is an upper bound for
 *   sizing counters, never a value the logic depends on.
 *
 *   That matters because the two used to be independent parameters that nothing
 *   forced to agree. Configure them differently and the failure was silent: this
 *   module would stop asking for rows at its own count, the buffer would never
 *   see the handshake on the beat it calls last, head_pop_fire would never fire,
 *   the slot would never be released, and the ring would wedge a few proposals
 *   later with no counter moving anywhere. Taking both facts from the buffer
 *   removes the class of bug rather than detecting it.
 *
 *   It also makes variable-length slots work without touching this file, which
 *   is the first item on ring_buffer.md's future-extensions list.
 *
 * WHY THE PAYLOAD BEAT IS REGISTERED RATHER THAN PASSED THROUGH
 *   AXI-Stream forbids deasserting TVALID before the handshake completes.
 *   proposal_buffer's read side can gap mid-slot - it has to go round the RAM
 *   for each row - so wiring i_buf_rd_valid straight to m_axis_tvalid would drop
 *   TVALID between beats and violate the protocol against the MAC. The one-deep
 *   holding register below decouples the two: it accepts a row whenever it is
 *   free, and holds it on the wire until the MAC takes it.
 */

module tx_engine #(
    parameter integer P_NODE_ID       = 0,
    parameter integer P_NODE_COUNT    = 3,

    // Node identity is compile-time, matching consensus_core's P_NODE_ID and
    // its read-only REPLICA_ID register: one bitstream per node.
    parameter [47:0]  P_SRC_MAC       = 48'h02_00_00_00_00_00,
    // Broadcast by default. One frame reaches every peer, which is what makes a
    // round exactly one frame; set it to a multicast group if the segment is
    // shared with anything else.
    parameter [47:0]  P_DST_MAC       = 48'hFF_FF_FF_FF_FF_FF,

    // Upper bound, for counter widths and for spotting a buffer that offers more
    // than the link budget allows. NOT the length of a frame - that is
    // i_buf_tx_len, decided per slot by proposal_buffer.
    parameter integer P_MAX_PAYLOAD_BYTES = 1024,

    parameter integer AXIS_DATA_WIDTH = 512,
    parameter integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8,
    // TX_TAG_WIDTH + 1 in Corundum: bit 0 is "bad frame", the rest is the
    // transmit tag. The old module declared this 1 bit wide and silently
    // truncated it.
    parameter integer AXIS_USER_WIDTH = 17,

    // Rides in tuser[AXIS_USER_WIDTH-1:1] and comes back on the transmit
    // completion. ssr_tx_mux uses the reserved top bit of it to tell this
    // node's own frames from the host's and keep their completions out of the
    // interface's descriptor accounting - see ssr_tx_mux.v.
    parameter [15:0]  P_TX_CPL_TAG    = 16'h8000,

    parameter integer DMA_LEN_WIDTH   = 16,
    parameter integer RAM_SEG_COUNT   = 2,
    parameter integer RAM_SEG_DATA_WIDTH = 256
) (
    input  wire                             clk,
    input  wire                             rst,

    // ---- from consensus_core -------------------------------------------
    input  wire                             i_tx_start_pulse,
    input  wire                             i_tx_window,
    input  wire                             i_tx_end_pulse,
    input  wire [63:0]                      i_tx_round_id,
    input  wire [31:0]                      i_tx_run_id,
    input  wire [7:0]                       i_tx_row,

    // ---- from proposal_buffer ------------------------------------------
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  i_buf_rd_data,
    input  wire                                         i_buf_rd_valid,
    output wire                                         o_buf_rd_ready,
    input  wire                                         i_buf_tx_last,
    input  wire [DMA_LEN_WIDTH-1:0]                     i_buf_tx_len,

    // ---- to the port MAC (direct tap) -----------------------------------
    output wire [AXIS_DATA_WIDTH-1:0]       m_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0]       m_axis_tkeep,
    output wire                             m_axis_tvalid,
    input  wire                             m_axis_tready,
    output wire                             m_axis_tlast,
    output wire [AXIS_USER_WIDTH-1:0]       m_axis_tuser,

    // ---- local echo of what was just transmitted -------------------------
    // A node's own proposal must reach its own commit ring, and it cannot come
    // back off the wire: a switch does not reflect a broadcast to the port it
    // arrived on, and an internal loopback would make a node lose its own data
    // whenever the link went down.
    //
    // This carries what was ACTUALLY SENT, beat for beat, at the instant each
    // beat is committed to the wire. Re-reading proposal_buffer instead would
    // fork this node's log from everyone else's the first time the queue filled
    // a cycle late, and no check would catch it - the rows still agree.
    //
    // o_local_sof pulses once per frame, before any payload beat, and carries
    // the round and the length. A header-only frame produces an sof with
    // o_local_len = 0 and no payload beats at all, which is how "this node
    // proposed nothing in round N" reaches the commit path as a positive fact
    // rather than as an absence.
    output reg                              o_local_sof,
    output reg [63:0]                       o_local_round_id,
    output reg [15:0]                       o_local_len,
    output reg                              o_local_valid,
    output reg [AXIS_DATA_WIDTH-1:0]        o_local_data,
    output reg                              o_local_last,

    // ---- statistics ------------------------------------------------------
    output wire [31:0]                      o_frame_count,
    output wire [31:0]                      o_empty_count,
    output wire [31:0]                      o_overrun_count,
    output wire [31:0]                      o_missed_count,
    // i_buf_tx_len and i_buf_tx_last disagreed: the buffer said N bytes and then
    // ended the slot somewhere other than beat ceil(N/64)-1. Both come from the
    // buffer, so this is a check on it rather than on a parameter mismatch.
    output wire [31:0]                      o_len_mismatch_count,
    // The buffer offered a slot larger than this link is configured to carry.
    // The frame still goes out whole - refusing it would leave the slot
    // unconsumed and wedge the ring - but the frame may exceed the MTU.
    output wire [31:0]                      o_oversize_count
);

`include "ssr_packet.vh"

localparam integer BUF_BEAT_BITS = RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH;
localparam integer BEAT_BYTES    = AXIS_KEEP_WIDTH;

initial begin
    if (SSR_HDR_BYTES != BEAT_BYTES) begin
        $error("the header must be exactly one beat: header %0d bytes, beat %0d",
               SSR_HDR_BYTES, BEAT_BYTES);
        $finish;
    end
    if (BUF_BEAT_BITS != AXIS_DATA_WIDTH) begin
        $error("proposal_buffer beat (%0d bits) must match the stream (%0d)",
               BUF_BEAT_BITS, AXIS_DATA_WIDTH);
        $finish;
    end
    if (P_NODE_COUNT > 8) begin
        $error("the row field is one byte; P_NODE_COUNT (%0d) must be <= 8", P_NODE_COUNT);
        $finish;
    end
end

// Header fields go on the wire most-significant byte first, while AXI-Stream
// puts byte 0 in tdata[7:0]. These put the MSB at the lowest byte offset.
function [15:0] be16(input [15:0] v); be16 = {v[7:0], v[15:8]}; endfunction
function [31:0] be32(input [31:0] v);
    be32 = {v[7:0], v[15:8], v[23:16], v[31:24]};
endfunction
function [47:0] be48(input [47:0] v);
    be48 = {v[7:0], v[15:8], v[23:16], v[31:24], v[39:32], v[47:40]};
endfunction
function [63:0] be64(input [63:0] v);
    be64 = {v[7:0], v[15:8], v[23:16], v[31:24],
            v[39:32], v[47:40], v[55:48], v[63:56]};
endfunction

// ---------------------------------------------------------------- state
localparam [1:0] S_IDLE    = 2'd0,
                 S_HDR     = 2'd1,
                 S_PAYLOAD = 2'd2;

reg [1:0]  state_reg = S_IDLE;

reg [63:0] round_id_reg = 64'd0;
reg [31:0] run_id_reg   = 32'd0;
reg [7:0]  row_reg      = 8'd0;
reg [15:0] length_reg   = 16'd0;      // 0 for a header-only frame
reg        has_payload_reg = 1'b0;

// Derived from the length this buffer offered, latched with it so the frame's
// geometry cannot change under it once the header has gone out.
reg [15:0]                payload_beats_reg = 16'd0;
reg [AXIS_KEEP_WIDTH-1:0] last_keep_reg = {AXIS_KEEP_WIDTH{1'b1}};

reg [31:0] frame_count_reg        = 32'd0;
reg [31:0] empty_count_reg        = 32'd0;
reg [31:0] overrun_count_reg      = 32'd0;
reg [31:0] missed_count_reg       = 32'd0;
reg [31:0] len_mismatch_count_reg = 32'd0;
reg [31:0] oversize_count_reg     = 32'd0;

// one-deep holding register for a payload beat
reg                       beat_valid_reg = 1'b0;
reg [AXIS_DATA_WIDTH-1:0] beat_data_reg  = {AXIS_DATA_WIDTH{1'b0}};
reg                       beat_last_reg  = 1'b0;
reg [15:0]                beat_index_reg = 16'd0;

// A start pulse is only honoured inside the admission window. Outside it the
// round is skipped and counted - a non-zero missed_count means either the window
// and the start pulse have drifted apart (a consensus_core bug) or the previous
// frame was still going out when this round began (severe MAC back-pressure).
wire start_accepted = i_tx_start_pulse && i_tx_window && (state_reg == S_IDLE);
wire start_dropped  = i_tx_start_pulse && !(i_tx_window && (state_reg == S_IDLE));

// The holding register may take a row whenever it is free, or is being emptied
// this very cycle. Combinational on m_axis_tready on purpose: registering it
// would put the handshake a cycle behind the beat it was meant to accept.
wire payload_space = (state_reg == S_PAYLOAD) && (!beat_valid_reg || m_axis_tready);
assign o_buf_rd_ready = payload_space;

// ------------------------------------------------- geometry of the next frame
// All of this is a function of what the buffer is offering right now; it is
// sampled once, at admission, and never re-read.
wire [15:0] offered_len   = i_buf_rd_valid ? i_buf_tx_len[15:0] : 16'd0;
wire        offered_valid = i_buf_rd_valid && (offered_len != 16'd0);

wire [15:0] offered_beats = (offered_len + BEAT_BYTES[15:0] - 16'd1) / BEAT_BYTES[15:0];
wire [15:0] offered_tail  = offered_len - ((offered_beats - 16'd1) * BEAT_BYTES[15:0]);

// (1 << tail) - 1, computed one bit wide so a full 64-byte tail lands on all
// ones rather than on zero.
wire [AXIS_KEEP_WIDTH:0] offered_keep_wide =
        ({{AXIS_KEEP_WIDTH{1'b0}}, 1'b1} << offered_tail) - {{AXIS_KEEP_WIDTH{1'b0}}, 1'b1};
wire [AXIS_KEEP_WIDTH-1:0] offered_keep = offered_keep_wide[AXIS_KEEP_WIDTH-1:0];

// ---------------------------------------------------------------- header beat
reg [AXIS_DATA_WIDTH-1:0] header_bits;
always @* begin
    header_bits = {AXIS_DATA_WIDTH{1'b0}};      // the reserved bytes are zero
    header_bits[SSR_OFF_DST_MAC  *8 +: 48] = be48(P_DST_MAC);
    header_bits[SSR_OFF_SRC_MAC  *8 +: 48] = be48(P_SRC_MAC);
    header_bits[SSR_OFF_ETHERTYPE*8 +: 16] = be16(SSR_ETHERTYPE);
    header_bits[SSR_OFF_NODE_ID  *8 +:  8] = P_NODE_ID[7:0];
    header_bits[SSR_OFF_ROW      *8 +:  8] = row_reg;
    header_bits[SSR_OFF_RUN_ID   *8 +: 32] = be32(run_id_reg);
    header_bits[SSR_OFF_ROUND_ID *8 +: 64] = be64(round_id_reg);
    header_bits[SSR_OFF_LENGTH   *8 +: 16] = be16(length_reg);
end

wire header_is_last = !has_payload_reg;

assign m_axis_tdata  = (state_reg == S_HDR) ? header_bits : beat_data_reg;
// The header beat and every full payload row are complete; only the final row
// of a payload that is not a whole number of beats is short.
assign m_axis_tkeep  = (state_reg == S_PAYLOAD && beat_last_reg)
                     ? last_keep_reg : {AXIS_KEEP_WIDTH{1'b1}};
assign m_axis_tvalid = (state_reg == S_HDR) ? 1'b1
                     : (state_reg == S_PAYLOAD) ? beat_valid_reg : 1'b0;
assign m_axis_tlast  = (state_reg == S_HDR) ? header_is_last : beat_last_reg;
// bit 0 = 0: the frame is good. The rest is the transmit tag.
assign m_axis_tuser  = {P_TX_CPL_TAG[AXIS_USER_WIDTH-2:0], 1'b0};

assign o_frame_count        = frame_count_reg;
assign o_empty_count        = empty_count_reg;
assign o_overrun_count      = overrun_count_reg;
assign o_missed_count       = missed_count_reg;
assign o_len_mismatch_count = len_mismatch_count_reg;
assign o_oversize_count     = oversize_count_reg;

// ------------------------------------------------------------- sequential
always @(posedge clk) begin
    o_local_sof   <= 1'b0;
    o_local_valid <= 1'b0;

    // The sub-slot ended while a frame was still on the wire. Never acted upon -
    // truncating it would put a malformed frame on the segment - only counted,
    // as evidence that TX_SUBSLOT_NS is too small.
    if (i_tx_end_pulse && (state_reg != S_IDLE))
        overrun_count_reg <= overrun_count_reg + 32'd1;

    if (start_dropped) missed_count_reg <= missed_count_reg + 32'd1;

    case (state_reg)
        S_IDLE: begin
            if (start_accepted) begin
                round_id_reg <= i_tx_round_id;
                run_id_reg   <= i_tx_run_id;
                row_reg      <= i_tx_row;

                // Latch the whole geometry here, once. Sampling the buffer again
                // later would let a slot that arrived mid-frame change the length
                // after the header had already gone out.
                has_payload_reg   <= offered_valid;
                length_reg        <= offered_len;
                payload_beats_reg <= offered_beats;
                last_keep_reg     <= offered_keep;

                if (!offered_valid) empty_count_reg <= empty_count_reg + 32'd1;
                if (offered_len > P_MAX_PAYLOAD_BYTES[15:0])
                    oversize_count_reg <= oversize_count_reg + 32'd1;

                beat_index_reg <= 16'd0;
                state_reg      <= S_HDR;
            end
        end

        S_HDR: begin
            if (m_axis_tready) begin
                // The local echo is announced the instant the header is
                // committed, so a consumer knows the round and the length before
                // the first payload beat reaches it.
                o_local_sof      <= 1'b1;
                o_local_round_id <= round_id_reg;
                o_local_len      <= length_reg;

                if (has_payload_reg) begin
                    state_reg <= S_PAYLOAD;
                end else begin
                    frame_count_reg <= frame_count_reg + 32'd1;
                    state_reg       <= S_IDLE;
                end
            end
        end

        S_PAYLOAD: begin
            if (beat_valid_reg && m_axis_tready) begin
                beat_valid_reg <= 1'b0;

                o_local_valid <= 1'b1;
                o_local_data  <= beat_data_reg;
                o_local_last  <= beat_last_reg;

                if (beat_last_reg) begin
                    // The buffer told us the length and then told us where the
                    // slot ends. If those two disagree the frame is still well
                    // formed, so nothing downstream would notice - count it.
                    if (beat_index_reg != payload_beats_reg - 16'd1)
                        len_mismatch_count_reg <= len_mismatch_count_reg + 32'd1;
                    frame_count_reg <= frame_count_reg + 32'd1;
                    state_reg       <= S_IDLE;
                end else begin
                    beat_index_reg <= beat_index_reg + 16'd1;
                end
            end

            // Accept the next row into the holding register. Written after the
            // pop above so that a pop and a load in the same cycle leave the
            // register loaded, which is what keeps the stream gapless.
            if (payload_space && i_buf_rd_valid) begin
                beat_data_reg  <= i_buf_rd_data;
                beat_last_reg  <= i_buf_tx_last;
                beat_valid_reg <= 1'b1;
            end
        end

        default: state_reg <= S_IDLE;
    endcase

    if (rst) begin
        state_reg              <= S_IDLE;
        round_id_reg           <= 64'd0;
        run_id_reg             <= 32'd0;
        row_reg                <= 8'd0;
        length_reg             <= 16'd0;
        has_payload_reg        <= 1'b0;
        payload_beats_reg      <= 16'd0;
        last_keep_reg          <= {AXIS_KEEP_WIDTH{1'b1}};
        beat_valid_reg         <= 1'b0;
        beat_data_reg          <= {AXIS_DATA_WIDTH{1'b0}};
        beat_last_reg          <= 1'b0;
        beat_index_reg         <= 16'd0;
        o_local_sof            <= 1'b0;
        o_local_valid          <= 1'b0;
        o_local_last           <= 1'b0;
        o_local_round_id       <= 64'd0;
        o_local_len            <= 16'd0;
        o_local_data           <= {AXIS_DATA_WIDTH{1'b0}};
        frame_count_reg        <= 32'd0;
        empty_count_reg        <= 32'd0;
        overrun_count_reg      <= 32'd0;
        missed_count_reg       <= 32'd0;
        len_mismatch_count_reg <= 32'd0;
        oversize_count_reg     <= 32'd0;
    end
end

endmodule

`resetall
