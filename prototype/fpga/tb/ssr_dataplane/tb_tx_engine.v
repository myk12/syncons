`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_tx_engine - tx_engine driven by the real consensus_core.
 *
 * The point of wiring the actual core in rather than hand-driving the pulses is
 * that the timing under test is then the timing that will ship: the sub-slot
 * offset, the admission margin and the end pulse all come from SECTION 2 rather
 * than from numbers copied into this file.
 *
 * proposal_buffer is modelled here rather than instantiated. The real one needs
 * a DMA write side to have anything in it, which would drag the whole DMA path
 * into a bench about frame construction; the model reproduces the one part of
 * its contract that tx_engine depends on - a slot is only released after the
 * last beat has been read.
 */
module tb_tx_engine;

localparam integer CLK_PERIOD_NS      = 4;
localparam integer NODE_COUNT         = 3;
localparam integer NODE_ID            = 1;      // middle sub-slot
localparam integer ROUND_LENGTH_NS    = 4000;
localparam integer GUARD_TIME_NS      = 200;
localparam integer TX_SUBSLOT_NS      = 400;
localparam integer TX_ADMIT_MARGIN_NS = 100;

localparam integer AXIS_DATA_WIDTH = 512;
localparam integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8;
localparam integer AXIS_USER_WIDTH = 17;
localparam integer PAYLOAD_BYTES   = 1024;      // one frame carries one slot
localparam integer SLOT_BEATS      = 16;        // 1024-byte slot / 64-byte beat

localparam [47:0] SRC_MAC = 48'h02_00_00_00_00_01;
localparam [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF;

localparam [23:0] RB_BASE_ADDR = 24'h003000;
localparam [23:0] REG_CONTROL                    = RB_BASE_ADDR + 24'h00C;
localparam [23:0] REG_CONFIG_RUN_ID              = RB_BASE_ADDR + 24'h100;
localparam [23:0] REG_CONFIG_MEMBERSHIP          = RB_BASE_ADDR + 24'h104;
localparam [23:0] REG_CONFIG_EFFECTIVE_ROUND_LOW = RB_BASE_ADDR + 24'h108;

`include "ssr_packet.vh"

localparam integer PAYLOAD_BEATS = PAYLOAD_BYTES/AXIS_KEEP_WIDTH;   // 16

// -------------------------------------------------------------------------
reg clk = 1'b0, rst = 1'b1;
always #(CLK_PERIOD_NS/2.0) clk = ~clk;

reg [47:0] time_seconds     = 48'd7;
reg [31:0] time_nanoseconds = 32'd0;
reg        time_advancing   = 1'b0;
always @(posedge clk) if (time_advancing) begin
    if (time_nanoseconds + CLK_PERIOD_NS >= 32'd1_000_000_000) begin
        time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS - 32'd1_000_000_000;
        time_seconds     <= time_seconds + 48'd1;
    end else time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS;
end

reg  [23:0] csr_addr = 24'd0;
reg  [31:0] csr_data = 32'd0;
reg         csr_en   = 1'b0;
wire        csr_ack;

// -------------------------------------------------------------------------
// consensus_core: the only source of transmit timing
// -------------------------------------------------------------------------
wire        tx_start_pulse, tx_window, tx_end_pulse, round_start_pulse;
wire [63:0] core_round_id;
wire [63:0] tx_round_id;

// Peer rows have to be fed in, or the core spends two rounds priming and then
// halts for want of a quorum - and a halted core stops pulsing o_tx_start_pulse,
// which looks exactly like a tx_engine that has stopped transmitting.
reg        rx_valid = 1'b0;
reg [7:0]  rx_node  = 8'd0;
reg [7:0]  rx_row   = 8'd0;
reg [31:0] rx_run   = 32'd0;
reg [63:0] rx_round = 64'd0;
reg [7:0]  peer_row = 8'b111;      // every peer claims to have heard everyone
wire [31:0] tx_run_id;
wire [7:0]  tx_row;

consensus_core #(
    .P_NODE_COUNT(NODE_COUNT), .P_NODE_ID(NODE_ID), .RB_BASE_ADDR(RB_BASE_ADDR),
    .ROUND_LENGTH_NS(ROUND_LENGTH_NS), .GUARD_TIME_NS(GUARD_TIME_NS),
    .TX_SUBSLOT_NS(TX_SUBSLOT_NS), .TX_ADMIT_MARGIN_NS(TX_ADMIT_MARGIN_NS)
) core (
    .clk(clk), .rst(rst), .i_enable(1'b1),
    .i_ptp_tod_sec(time_seconds), .i_ptp_tod_ns(time_nanoseconds),
    .i_ptp_time_valid(1'b1), .i_ptp_step(1'b0),
    .reg_wr_addr(csr_addr), .reg_wr_data(csr_data), .reg_wr_strb(4'hF),
    .reg_wr_en(csr_en), .reg_wr_wait(), .reg_wr_ack(csr_ack),
    .reg_rd_addr(24'd0), .reg_rd_en(1'b0), .reg_rd_data(), .reg_rd_wait(), .reg_rd_ack(),
    .o_round_id(core_round_id), .o_round_start_pulse(round_start_pulse),
    .o_round_boundary_pulse(),
    .o_tx_start_pulse(tx_start_pulse), .o_tx_end_pulse(tx_end_pulse),
    .o_tx_window(tx_window),
    .o_rx_start_pulse(), .o_rx_end_pulse(), .o_rx_window(),
    .o_tx_round_id(tx_round_id), .o_tx_run_id(tx_run_id), .o_tx_row(tx_row),
    .i_rx_valid(rx_valid), .i_rx_node_id(rx_node), .i_rx_row(rx_row),
    .i_rx_run_id(rx_run), .i_rx_round_id(rx_round),
    .o_commit_valid(), .o_commit_round_id(), .o_commit_set(),
    .o_halt(), .o_time_fault(), .o_time_fault_count()
);

// Deliver one row from each peer per round, inside the receive window. Rows all
// match, so the core keeps a quorum and stays in S_RUN for the whole bench.
integer inject_i;
always @(posedge round_start_pulse) begin
    repeat (GUARD_TIME_NS/CLK_PERIOD_NS + 4) @(posedge clk);
    for (inject_i = 0; inject_i < NODE_COUNT; inject_i = inject_i + 1) begin
        if (inject_i != NODE_ID) begin
            @(negedge clk);
            rx_node  = inject_i[7:0];
            rx_row   = peer_row;
            rx_run   = tx_run_id;
            rx_round = core_round_id;
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
        end
    end
end

// -------------------------------------------------------------------------
// proposal_buffer model: holds `buf_slots` slots of SLOT_BEATS beats each and
// only releases one once its last beat has been read.
// -------------------------------------------------------------------------
integer buf_slots = 0;                      // slots available
// The slot length is a run-time property of the model, not a parameter. That is
// the whole point of the change under test: tx_engine takes the length from
// buf_tx_len, so this bench can hand it a different geometry mid-run without
// re-elaborating anything.
integer buf_slot_beats = SLOT_BEATS;
reg [AXIS_DATA_WIDTH-1:0] buf_pattern = {AXIS_DATA_WIDTH{1'b0}};
reg [4:0]  buf_beat = 5'd0;
wire       buf_rd_valid = (buf_slots > 0);
wire       buf_tx_last  = (buf_beat == buf_slot_beats-1);
wire [15:0] buf_tx_len   = buf_slot_beats*AXIS_KEEP_WIDTH;
wire       buf_rd_ready;
wire [AXIS_DATA_WIDTH-1:0] buf_rd_data = buf_pattern | {{(AXIS_DATA_WIDTH-16){1'b0}}, 3'd0, buf_beat, 8'd0};

always @(posedge clk) begin
    if (rst) begin
        buf_beat <= 5'd0;
    end else if (buf_rd_valid && buf_rd_ready) begin
        if (buf_tx_last) begin
            buf_beat  <= 5'd0;
            buf_slots  = buf_slots - 1;     // slot released only on the last beat
        end else begin
            buf_beat <= buf_beat + 5'd1;
        end
    end
end

// -------------------------------------------------------------------------
wire [AXIS_DATA_WIDTH-1:0] axis_tdata;
wire [AXIS_KEEP_WIDTH-1:0] axis_tkeep;
wire                       axis_tvalid, axis_tlast;
wire [AXIS_USER_WIDTH-1:0] axis_tuser;
reg                        axis_tready = 1'b1;

wire [31:0] frame_count, empty_count, overrun_count, missed_count;
wire [31:0] len_mismatch_count, oversize_count;
wire                       local_sof, local_valid, local_last;
wire [63:0]                local_round_id;
wire [15:0]                local_len;
wire [AXIS_DATA_WIDTH-1:0] local_data;

tx_engine #(
    .P_NODE_ID(NODE_ID), .P_NODE_COUNT(NODE_COUNT),
    .P_SRC_MAC(SRC_MAC), .P_DST_MAC(DST_MAC),
    .P_MAX_PAYLOAD_BYTES(PAYLOAD_BYTES),
    .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH), .AXIS_USER_WIDTH(AXIS_USER_WIDTH),
    .RAM_SEG_COUNT(2), .RAM_SEG_DATA_WIDTH(AXIS_DATA_WIDTH/2)
) dut (
    .clk(clk), .rst(rst),
    .i_tx_start_pulse(tx_start_pulse), .i_tx_window(tx_window),
    .i_tx_end_pulse(tx_end_pulse),
    .i_tx_round_id(tx_round_id), .i_tx_run_id(tx_run_id), .i_tx_row(tx_row),
    .i_buf_rd_data(buf_rd_data), .i_buf_rd_valid(buf_rd_valid),
    .o_buf_rd_ready(buf_rd_ready), .i_buf_tx_last(buf_tx_last),
    .i_buf_tx_len(buf_tx_len),
    .m_axis_tdata(axis_tdata), .m_axis_tkeep(axis_tkeep),
    .m_axis_tvalid(axis_tvalid), .m_axis_tready(axis_tready),
    .m_axis_tlast(axis_tlast), .m_axis_tuser(axis_tuser),
    .o_local_sof(local_sof), .o_local_round_id(local_round_id),
    .o_local_len(local_len), .o_local_valid(local_valid),
    .o_local_data(local_data), .o_local_last(local_last),
    .o_frame_count(frame_count), .o_empty_count(empty_count),
    .o_overrun_count(overrun_count), .o_missed_count(missed_count),
    .o_len_mismatch_count(len_mismatch_count), .o_oversize_count(oversize_count)
);

// -------------------------------------------------------------------------
integer error_count = 0, check_count = 0;
task check(input condition, input string message);
begin
    check_count = check_count + 1;
    if (!condition) begin
        $display("[%0t] ERROR: %0s", $realtime, message);
        error_count = error_count + 1;
    end
end
endtask

task csr_write(input [23:0] a, input [31:0] d);
    integer g;
begin
    @(negedge clk); csr_addr=a; csr_data=d; csr_en=1'b1; g=0;
    while (g<16) begin @(posedge clk); #0.1; if (csr_ack) g=99; else g=g+1; end
    @(negedge clk); csr_en=1'b0;
end
endtask

// -------------------------------------------------------------------------
// frame capture + continuous checks
// -------------------------------------------------------------------------
reg [AXIS_DATA_WIDTH-1:0] seen_frame = {AXIS_DATA_WIDTH{1'b0}};
reg [AXIS_KEEP_WIDTH-1:0] seen_keep  = {AXIS_KEEP_WIDTH{1'b0}};
integer seen_frames = 0;
real    last_start_offset_ns;

function [15:0] rd16(input integer off);
    rd16 = {seen_frame[off*8 +: 8], seen_frame[(off+1)*8 +: 8]};
endfunction
function [31:0] rd32(input integer off);
    rd32 = {seen_frame[off*8 +: 8], seen_frame[(off+1)*8 +: 8],
            seen_frame[(off+2)*8 +: 8], seen_frame[(off+3)*8 +: 8]};
endfunction
function [63:0] rd64(input integer off);
    rd64 = {seen_frame[off*8 +: 8], seen_frame[(off+1)*8 +: 8],
            seen_frame[(off+2)*8 +: 8], seen_frame[(off+3)*8 +: 8],
            seen_frame[(off+4)*8 +: 8], seen_frame[(off+5)*8 +: 8],
            seen_frame[(off+6)*8 +: 8], seen_frame[(off+7)*8 +: 8]};
endfunction
function [47:0] rd48(input integer off);
    rd48 = {seen_frame[off*8 +: 8], seen_frame[(off+1)*8 +: 8],
            seen_frame[(off+2)*8 +: 8], seen_frame[(off+3)*8 +: 8],
            seen_frame[(off+4)*8 +: 8], seen_frame[(off+5)*8 +: 8]};
endfunction

// A frame may only be LAUNCHED inside the admission window - checked on the
// rising edge of tvalid, not on the handshake. Checking the handshake would fail
// the moment backpressure holds a legitimately admitted frame past the end of
// the sub-slot, which is precisely the case that must be allowed.
reg axis_valid_delayed = 1'b0;
always @(posedge clk) begin
    axis_valid_delayed <= axis_tvalid;
    if (axis_tvalid && !axis_valid_delayed)
        check(tx_window === 1'b1, "tvalid rose outside the admission window");
end

// Beat 0 is the header, beats 1..N are buffer rows byte for byte.
integer beat_in_frame = 0, payload_beats_seen = 0, header_only_frames = 0;
integer expect_beats = 0, last_frame_len = 0;
reg [15:0] frame_len_reg;

always @(posedge clk) begin
    if (axis_tvalid && axis_tready) begin
        check(axis_tkeep == {AXIS_KEEP_WIDTH{1'b1}}, "every beat of an SSR frame is full");
        check(axis_tuser[0] === 1'b0, "tuser bad-frame bit must be clear");

        if (beat_in_frame == 0) begin
            seen_frame  = axis_tdata;
            seen_keep   = axis_tkeep;
            seen_frames = seen_frames + 1;
            frame_len_reg = rd16(SSR_OFF_LENGTH);

            check(rd48(SSR_OFF_DST_MAC)   == DST_MAC, "dst MAC");
            check(rd48(SSR_OFF_SRC_MAC)   == SRC_MAC, "src MAC");
            check(rd16(SSR_OFF_ETHERTYPE) == SSR_ETHERTYPE, "ethertype");
            check(seen_frame[SSR_OFF_NODE_ID*8 +: 8] == NODE_ID[7:0], "node_id");
            check(rd64(SSR_OFF_ROUND_ID) == tx_round_id,
                  $sformatf("round_id %0d, core says %0d", rd64(SSR_OFF_ROUND_ID), tx_round_id));
            check(rd32(SSR_OFF_RUN_ID) == tx_run_id, "run_id");
            check(seen_frame[SSR_OFF_ROW*8 +: 8] == tx_row,
                  $sformatf("row %02h, core says %02h", seen_frame[SSR_OFF_ROW*8 +: 8], tx_row));
            check(seen_frame[SSR_OFF_RESERVED*8 +: (SSR_OFF_PAYLOAD-SSR_OFF_RESERVED)*8] == 0,
                  "header padding must be zero");

            // An empty proposal queue is a header-only frame saying length = 0.
            // That is the only thing distinguishing "nothing to propose" from
            // "a payload that happens to be zeros", so it is checked explicitly.
            if (frame_len_reg == 16'd0) begin
                header_only_frames = header_only_frames + 1;
                expect_beats = 0;
                check(axis_tlast === 1'b1, "a length-0 frame must end on the header beat");
            end else begin
                // The frame declares its own length; the number of payload beats
                // must follow from it. Nothing here knows the buffer's geometry.
                expect_beats = (frame_len_reg + AXIS_KEEP_WIDTH - 1) / AXIS_KEEP_WIDTH;
                last_frame_len = frame_len_reg;
                check(axis_tlast === 1'b0, "a frame with a payload cannot end on the header");
            end
            beat_in_frame = axis_tlast ? 0 : 1;
        end else begin
            payload_beats_seen = payload_beats_seen + 1;
            // The buffer model tags every beat with its index, so a frame that
            // is shifted or repeated shows up here rather than in a spot check.
            check(axis_tdata[7:0] == buf_pattern[7:0],
                  $sformatf("payload beat %0d byte0 %02h, expected %02h",
                            beat_in_frame-1, axis_tdata[7:0], buf_pattern[7:0]));
            check(axis_tdata[15:8] == (beat_in_frame-1),
                  $sformatf("payload beat %0d carries index %0d",
                            beat_in_frame-1, axis_tdata[15:8]));
            if (axis_tlast) begin
                check(beat_in_frame == expect_beats,
                      $sformatf("frame carried %0d payload beats, length %0d implies %0d",
                                beat_in_frame, last_frame_len, expect_beats));
                beat_in_frame = 0;
            end else beat_in_frame = beat_in_frame + 1;
        end
    end
end

// -------------------------------------------------------------------------
integer n, frames_before, empty_before;
integer stall_i, overrun_before, oversize_before;
reg [AXIS_DATA_WIDTH-1:0] held_data;
reg held_last, held_valid;
reg [7:0] payload_byte0;

initial begin
    $dumpfile("build/tb_tx_engine.vcd");
    $dumpvars(0, tb_tx_engine);

    rst = 1'b1; time_advancing = 1'b0;
    repeat (10) @(posedge clk);
    time_advancing = 1'b1;
    rst = 1'b0;
    repeat (5) @(posedge clk);

    csr_write(REG_CONFIG_RUN_ID,     32'h0000_0055);
    csr_write(REG_CONFIG_MEMBERSHIP, 32'h0000_0007);
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW, 32'h0000_0100);
    csr_write(REG_CONTROL, 32'h0000_0003);         // enable | activate

    // Activation costs an arm boundary plus an install boundary, and the core
    // gates o_tx_start_pulse until then. Counting rounds before that would just
    // be counting rounds the core was never going to transmit in.
    wait (core.state_reg == 2'd2);
    repeat (3*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(core.state_reg == 2'd2, "core should still be running once primed");

    // ---------------- Test 0: empty queue still transmits ----------------
    // The row has to reach the peers even with nothing to propose; a silent
    // node gets dropped from their sound sets.
    $display("[%0t] Test 0: empty proposal queue still sends a frame", $realtime);
    buf_slots = 0;
    frames_before = frame_count;
    empty_before  = empty_count;
    repeat (4*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);

    check(frame_count - frames_before >= 3,
          $sformatf("only %0d frames over 4 rounds with an empty queue",
                    frame_count - frames_before));
    check(empty_count - empty_before == frame_count - frames_before,
          "every frame in this window should have counted as empty");
    check(header_only_frames > 0, "an empty queue must send header-only frames");

    // ---------------- Test 1: payload comes from the buffer --------------
    $display("[%0t] Test 1: payload is taken from the buffer", $realtime);
    buf_pattern = {AXIS_DATA_WIDTH{1'b0}};
    buf_pattern[7:0] = 8'hA5;
    buf_slots = 4;
    empty_before = empty_count;
    repeat (2*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);

    check(payload_beats_seen > 0, "a frame should have carried payload beats");
    check(empty_count == empty_before, "frames with data must not count as empty");

    // the slot must be fully drained, or proposal_buffer never releases it
    repeat (2*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(buf_slots < 4, "a slot was consumed but never released");

    // ---------------- Test 2: one frame per round ------------------------
    // Broadcast means a round is one frame, not one per peer.
    $display("[%0t] Test 2: exactly one frame per round", $realtime);
    buf_slots = 20;
    frames_before = frame_count;
    repeat (8*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(frame_count - frames_before >= 7 && frame_count - frames_before <= 9,
          $sformatf("%0d frames over 8 rounds; expected one each",
                    frame_count - frames_before));

    // ---------------- Test 3: backpressure must not truncate -------------
    // Holding tready low across the end of the sub-slot is the case that made
    // the old module violate AXI-Stream. The frame must still go out whole,
    // just late, and the lateness must be counted.
    //
    // Multi-beat adds a second obligation the single-beat version could not
    // test: TVALID, TDATA and TLAST must all hold steady across the stall.
    // proposal_buffer gaps between rows, so a design that passed its rd_valid
    // straight to the MAC would drop TVALID mid-frame and break the protocol.
    $display("[%0t] Test 3: backpressure past the sub-slot end", $realtime);
    buf_slots = 8;
    @(posedge tx_start_pulse);
    repeat (6) @(posedge clk);              // land inside the payload, not on the header
    @(negedge clk); axis_tready = 1'b0;
    @(negedge clk);
    held_data = axis_tdata;
    held_last = axis_tlast;
    held_valid = axis_tvalid;
    overrun_before = overrun_count;
    for (stall_i = 0; stall_i < TX_SUBSLOT_NS/CLK_PERIOD_NS + 20; stall_i = stall_i + 1) begin
        @(negedge clk);
        check(axis_tvalid === held_valid, "tvalid must not drop while tready is low");
        check(axis_tdata  === held_data,  "tdata must hold while tready is low");
        check(axis_tlast  === held_last,  "tlast must hold while tready is low");
    end
    check(overrun_count > overrun_before, "an overrun should have been counted");

    frames_before = frame_count;
    @(negedge clk); axis_tready = 1'b1;
    // a whole frame is 1 header beat + PAYLOAD_BEATS payload beats, and the
    // buffer needs a few cycles per row, so allow generously
    repeat (16*(PAYLOAD_BEATS+2)) @(posedge clk);
    check(frame_count > frames_before, "the held frame must complete once tready returns");

    // ---------------- Test 3b: the length comes from the buffer -----------
    // tx_engine holds no slot-geometry parameter any more. Hand the model a
    // different slot size and the frames must change shape with it, with no
    // re-elaboration and no counter complaining. This is the property that
    // makes i_buf_tx_last / i_buf_tx_len worth their wires: the alternative,
    // a parameter on each side that nothing forces to agree, fails silently by
    // wedging the ring rather than by transmitting a wrong-sized frame.
    $display("[%0t] Test 3b: frame length follows the buffer's slot size", $realtime);
    buf_slots = 20;

    buf_slot_beats = 8;                       // 512-byte slots
    repeat (3*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(last_frame_len == 512,
          $sformatf("expected 512-byte frames, saw length %0d", last_frame_len));

    buf_slot_beats = 16;                      // back to 1 KiB
    repeat (3*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(last_frame_len == 1024,
          $sformatf("expected 1024-byte frames, saw length %0d", last_frame_len));

    buf_slot_beats = 4;                       // 256-byte slots
    repeat (3*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(last_frame_len == 256,
          $sformatf("expected 256-byte frames, saw length %0d", last_frame_len));

    check(len_mismatch_count == 32'd0,
          "tx_len and tx_last must agree at every slot size");
    check(oversize_count == 32'd0, "no slot exceeded the link budget");

    // A slot larger than P_MAX_PAYLOAD_BYTES must be COUNTED, not refused.
    // Refusing it would leave the slot unconsumed, and proposal_buffer only
    // releases a slot on the handshake of its last beat - so a refusal wedges
    // the ring, which is strictly worse than an over-long frame.
    oversize_before = oversize_count;
    frames_before   = frame_count;
    buf_slot_beats  = 24;                     // 1536 bytes, over the 1 KiB bound
    repeat (3*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(oversize_count > oversize_before, "an over-long slot must be counted");
    check(frame_count > frames_before, "and the frame must still go out whole");
    check(last_frame_len == 1536,
          $sformatf("the over-long frame should still declare 1536, saw %0d", last_frame_len));
    check(len_mismatch_count == 32'd0, "tx_len and tx_last still agree");

    buf_slot_beats = SLOT_BEATS;

    // ---------------- Test 4: no frame outside the window ----------------
    // The continuous monitor above already asserts this on every beat; this
    // just runs long enough for it to mean something.
    $display("[%0t] Test 4: sustained run", $realtime);
    buf_slots = 40;
    repeat (10*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(missed_count == 0,
          $sformatf("%0d start pulses fell outside the window", missed_count));

    $display("--------------------------------------------------");
    $display("frames=%0d (%0d header-only, %0d payload beats) empty=%0d overrun=%0d missed=%0d",
             frame_count, header_only_frames, payload_beats_seen,
             empty_count, overrun_count, missed_count);
    $display("len_mismatch=%0d oversize=%0d", len_mismatch_count, oversize_count);
    $display("checks : %0d", check_count);
    $display("errors : %0d", error_count);
    $display("--------------------------------------------------");
    if (error_count == 0) $display("[%0t] ALL TESTS PASSED", $realtime);
    else                  $display("[%0t] %0d FAILURES", $realtime, error_count);
    $finish;
end

initial begin
    #2_000_000;
    $display("[%0t] TIMEOUT", $realtime);
    $finish;
end

endmodule

`resetall
