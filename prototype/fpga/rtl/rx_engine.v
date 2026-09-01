`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * rx_engine - turns arriving frames into commit-ring writes.
 *
 * Replaces consensus_rx. It parses one frame per beat, hands the header to
 * consensus_core, and writes the payload into the commit ring at an address
 * derived from the header.
 *
 * ORDERING COMES FROM ADDRESSING, NOT FROM TIMING
 *   The ring address is {round_id, node_id}, both taken from the frame itself,
 *   so nothing here depends on frames arriving in any particular order. TDMA
 *   does happen to make them arrive in node order - a sub-slot is 400 ns while
 *   the differential delay between two ports of one switch is a few ns, so an
 *   inversion would need about 80 m of cable-length mismatch - but relying on
 *   that would put a timing assumption underneath a correctness property, and it
 *   would quietly weaken every time the sub-slot shrank or the port was shared.
 *
 * ONE ARBITER FOR "ACCEPTED"
 *   Whether a frame counts is decided by consensus_core and read back on
 *   i_rx_accepted. Re-deriving it here would mean copying the sound set, the run
 *   id, the current round and the FSM state out of the core and keeping two
 *   copies of the rule in step. In particular this is what drops a LATE frame -
 *   one whose round_id no longer matches - which is the one arrival hazard TDMA
 *   does not remove.
 *
 * THE LOCAL PROPOSAL
 *   A node's own payload arrives on i_local_*, straight from tx_engine, because
 *   it cannot come back off the wire. It is not offered to the core: the core
 *   already counts itself present the moment it opens a stage.
 *
 * v1 SCOPE: one beat per frame, matching tx_engine.
 */

module rx_engine #(
    parameter integer P_NODE_ID       = 0,
    parameter integer P_NODE_COUNT    = 3,
    parameter integer P_PAYLOAD_BYTES = 32,

    parameter integer AXIS_DATA_WIDTH = 512,
    parameter integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8,
    parameter integer AXIS_USER_WIDTH = 17
) (
    input  wire                             clk,
    input  wire                             rst,

    // ---- from the port MAC (direct tap) ---------------------------------
    input  wire [AXIS_DATA_WIDTH-1:0]       s_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0]       s_axis_tkeep,
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,
    input  wire [AXIS_USER_WIDTH-1:0]       s_axis_tuser,

    // ---- to / from consensus_core ---------------------------------------
    output wire                             o_rx_valid,
    output wire [7:0]                       o_rx_node_id,
    output wire [7:0]                       o_rx_row,
    output wire [31:0]                      o_rx_run_id,
    output wire [63:0]                      o_rx_round_id,
    input  wire                             i_rx_accepted,

    // ---- own payload, from tx_engine ------------------------------------
    input  wire                             i_local_valid,
    input  wire [63:0]                      i_local_round_id,
    input  wire [P_PAYLOAD_BYTES*8-1:0]     i_local_payload,

    // ---- to the commit ring ----------------------------------------------
    output reg                              o_ring_wr_valid,
    output reg  [63:0]                      o_ring_wr_round_id,
    output reg  [7:0]                       o_ring_wr_node_id,
    output reg  [P_PAYLOAD_BYTES*8-1:0]     o_ring_wr_payload,

    // ---- statistics -------------------------------------------------------
    output wire [31:0]                      o_frame_count,
    output wire [31:0]                      o_foreign_count,
    output wire [31:0]                      o_rejected_count,
    output wire [31:0]                      o_local_count,
    output wire [31:0]                      o_collision_count
);

`include "ssr_packet.vh"

initial begin
    if (SSR_OFF_PAYLOAD + P_PAYLOAD_BYTES > AXIS_KEEP_WIDTH) begin
        $error("rx_engine v1 parses one beat: frame is %0d bytes, beat is %0d",
               SSR_OFF_PAYLOAD + P_PAYLOAD_BYTES, AXIS_KEEP_WIDTH);
        $finish;
    end
    if (P_NODE_COUNT > 8) begin
        $error("the row field is one byte; P_NODE_COUNT (%0d) must be <= 8", P_NODE_COUNT);
        $finish;
    end
end

// Header fields are most-significant byte first, AXI-Stream puts byte 0 in
// tdata[7:0]. These read a field back out of the beat.
function [15:0] rd16(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    rd16 = {d[off*8 +: 8], d[(off+1)*8 +: 8]};
endfunction
function [31:0] rd32(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    rd32 = {d[off*8 +: 8], d[(off+1)*8 +: 8], d[(off+2)*8 +: 8], d[(off+3)*8 +: 8]};
endfunction
function [63:0] rd64(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    rd64 = {d[off*8 +: 8], d[(off+1)*8 +: 8], d[(off+2)*8 +: 8], d[(off+3)*8 +: 8],
            d[(off+4)*8 +: 8], d[(off+5)*8 +: 8], d[(off+6)*8 +: 8], d[(off+7)*8 +: 8]};
endfunction

// Nothing here ever stalls: the frame is parsed combinationally into registers
// and the two pipeline stages run unconditionally, so a beat is always taken.
// Back-pressuring the MAC would only move a loss upstream where it is harder to
// see.
assign s_axis_tready = 1'b1;

wire beat_taken = s_axis_tvalid && s_axis_tready && s_axis_tlast;

// Only the ethertype identifies an SSR frame - there is no magic or version
// field. A bad-frame marker from the MAC discards it too.
wire frame_is_ours = (rd16(s_axis_tdata, SSR_OFF_ETHERTYPE) == SSR_ETHERTYPE)
                  && !s_axis_tuser[0];

// A frame claiming to come from this node is discarded. It cannot be genuine -
// the local payload arrives on i_local_* - and honouring it would let anything
// on the segment overwrite this node's own row.
wire [7:0] parsed_node_id = s_axis_tdata[SSR_OFF_NODE_ID*8 +: 8];
wire       node_id_sane   = (parsed_node_id < P_NODE_COUNT)
                         && (parsed_node_id != P_NODE_ID);

// ---------------------------------------------------------------- pipeline
reg        present_valid_reg = 1'b0;
reg [7:0]  node_id_reg  = 8'd0;
reg [7:0]  row_reg      = 8'd0;
reg [31:0] run_id_reg   = 32'd0;
reg [63:0] round_id_reg = 64'd0;
reg [P_PAYLOAD_BYTES*8-1:0] payload_reg = {P_PAYLOAD_BYTES*8{1'b0}};

// The local payload waits here if the ring write port is busy with a remote
// frame. TDMA keeps the two apart - a node's own sub-slot is not when its peers
// are arriving - but wire delay makes the edges overlap, so this is one entry
// deep rather than assumed impossible.
reg                         local_pending_reg = 1'b0;
reg [63:0]                  local_round_reg   = 64'd0;
reg [P_PAYLOAD_BYTES*8-1:0] local_payload_reg = {P_PAYLOAD_BYTES*8{1'b0}};

reg [31:0] frame_count_reg     = 32'd0;
reg [31:0] foreign_count_reg   = 32'd0;
reg [31:0] rejected_count_reg  = 32'd0;
reg [31:0] local_count_reg     = 32'd0;
reg [31:0] collision_count_reg = 32'd0;

assign o_rx_valid    = present_valid_reg;
assign o_rx_node_id  = node_id_reg;
assign o_rx_row      = row_reg;
assign o_rx_run_id   = run_id_reg;
assign o_rx_round_id = round_id_reg;

assign o_frame_count     = frame_count_reg;
assign o_foreign_count   = foreign_count_reg;
assign o_rejected_count  = rejected_count_reg;
assign o_local_count     = local_count_reg;
assign o_collision_count = collision_count_reg;

// A remote frame that the core has just accepted takes the ring port this cycle.
wire remote_writes = present_valid_reg && i_rx_accepted;

always @(posedge clk) begin
    present_valid_reg <= 1'b0;
    o_ring_wr_valid   <= 1'b0;

    // ---- stage 1: parse ------------------------------------------------
    if (beat_taken) begin
        if (!frame_is_ours) begin
            foreign_count_reg <= foreign_count_reg + 32'd1;
        end else if (!node_id_sane) begin
            // Counted as foreign: it carried our ethertype but cannot be a
            // legitimate peer frame.
            foreign_count_reg <= foreign_count_reg + 32'd1;
        end else begin
            node_id_reg  <= parsed_node_id;
            row_reg      <= s_axis_tdata[SSR_OFF_ROW*8 +: 8];
            run_id_reg   <= rd32(s_axis_tdata, SSR_OFF_RUN_ID);
            round_id_reg <= rd64(s_axis_tdata, SSR_OFF_ROUND_ID);
            payload_reg  <= s_axis_tdata[SSR_OFF_PAYLOAD*8 +: P_PAYLOAD_BYTES*8];
            present_valid_reg <= 1'b1;
            frame_count_reg   <= frame_count_reg + 32'd1;
        end
    end

    // ---- stage 2: the core's verdict on what stage 1 presented ----------
    if (present_valid_reg) begin
        if (i_rx_accepted) begin
            o_ring_wr_valid    <= 1'b1;
            o_ring_wr_round_id <= round_id_reg;
            o_ring_wr_node_id  <= node_id_reg;
            o_ring_wr_payload  <= payload_reg;
        end else begin
            // Stale run, wrong round, a peer already outside the sound set, or
            // the core is not running. The core decided; nothing is stored.
            rejected_count_reg <= rejected_count_reg + 32'd1;
        end
    end

    // ---- local payload ---------------------------------------------------
    if (i_local_valid) begin
        local_count_reg <= local_count_reg + 32'd1;
        if (remote_writes) begin
            local_pending_reg <= 1'b1;
            local_round_reg   <= i_local_round_id;
            local_payload_reg <= i_local_payload;
            collision_count_reg <= collision_count_reg + 32'd1;
        end else begin
            o_ring_wr_valid    <= 1'b1;
            o_ring_wr_round_id <= i_local_round_id;
            o_ring_wr_node_id  <= P_NODE_ID[7:0];
            o_ring_wr_payload  <= i_local_payload;
        end
    end else if (local_pending_reg && !remote_writes) begin
        local_pending_reg  <= 1'b0;
        o_ring_wr_valid    <= 1'b1;
        o_ring_wr_round_id <= local_round_reg;
        o_ring_wr_node_id  <= P_NODE_ID[7:0];
        o_ring_wr_payload  <= local_payload_reg;
    end

    if (rst) begin
        present_valid_reg   <= 1'b0;
        o_ring_wr_valid     <= 1'b0;
        o_ring_wr_round_id  <= 64'd0;
        o_ring_wr_node_id   <= 8'd0;
        o_ring_wr_payload   <= {P_PAYLOAD_BYTES*8{1'b0}};
        local_pending_reg   <= 1'b0;
        frame_count_reg     <= 32'd0;
        foreign_count_reg   <= 32'd0;
        rejected_count_reg  <= 32'd0;
        local_count_reg     <= 32'd0;
        collision_count_reg <= 32'd0;
    end
end

endmodule

`resetall
