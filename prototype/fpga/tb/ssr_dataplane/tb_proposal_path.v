`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_proposal_path - the whole proposal datapath, end to end, with the real core.
 *
 *   CSR ─► proposal_dma_reader ──descriptor──► [fake DMA engine in this bench]
 *              │  tail_slot_valid/addr                    │ dma_ram_wr_cmd_*
 *              └──tail_slot_commit──► proposal_buffer ◄───┘
 *                                          │ buf_rd_*
 *   consensus_core ──tx timing + row──► tx_engine ──AXIS──► [frame checker]
 *
 * WHY THIS BENCH EXISTS
 *   Every module on this path already has (or had) its own unit bench, and each
 *   one stubs out its neighbours. What none of them can show is the property the
 *   path actually exists for: a payload placed at a host address ends up in the
 *   frame that leaves the port, in the right round, under timing the core
 *   generated. That is one assertion, and it needs all five modules at once.
 *
 *   It replaces the previous tb_proposal_path, which no longer elaborated:
 *   proposal_dma_reader used to forward DMA write-back into the buffer itself
 *   (buf_wr_*, plus RAM_SEG_* parameters), and that job has since moved to
 *   proposal_buffer, which is now the DMA RAM write endpoint. The old bench
 *   still wired the pre-refactor interface.
 *
 * WHAT THE FAKE DMA ENGINE IS FOR
 *   Corundum's dma_if_pcie is not in this bench. The model does the only three
 *   things the reader can observe: accept a descriptor, write LEN bytes into the
 *   named RAM rows, and report a status with the matching tag. Its payload is
 *   derived from the descriptor's dma_addr, so the frame checker can prove the
 *   bytes on the wire came from the host address the descriptor asked for -
 *   not merely that *some* bytes arrived.
 *
 * SLOT_COUNT is deliberately smaller than the batch, so the ring fills and the
 * reader has to stall in STATE_ISSUE_DMA waiting on tail_slot_valid. Back
 * pressure from the wire all the way to the descriptor issue is the part of this
 * path most likely to deadlock, and it only appears when the ring is too small.
 */

module tb_proposal_path;

// ---------------------------------------------------------------- geometry
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

localparam [47:0] SRC_MAC = 48'h02_00_00_00_00_01;
localparam [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF;

// RAM / ring geometry, matching ssr_dataplane's defaults except SLOT_COUNT
localparam integer DMA_ADDR_WIDTH = 64;
localparam integer DMA_LEN_WIDTH  = 16;
localparam integer DMA_TAG_WIDTH  = 16;
localparam integer RAM_SEL_WIDTH  = 4;
localparam integer RAM_ADDR_WIDTH = 16;
localparam integer RAM_SEG_COUNT  = 2;
localparam integer RAM_SEG_DATA_WIDTH = 256;
localparam integer RAM_SEG_BE_WIDTH   = RAM_SEG_DATA_WIDTH/8;
localparam integer RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH);
localparam integer RAM_PIPELINE = 2;

`ifndef SSR_TB_SLOT_BYTES
  `define SSR_TB_SLOT_BYTES 1024
`endif
localparam integer SLOT_BYTES = `SSR_TB_SLOT_BYTES;
localparam integer SLOT_COUNT = 4;                        // smaller than a batch on purpose
localparam integer BEAT_BYTES = RAM_SEG_COUNT*RAM_SEG_BE_WIDTH;   // 64
localparam integer SLOT_BEATS = SLOT_BYTES/BEAT_BYTES;            // 16
localparam integer PAYLOAD_BYTES = SLOT_BYTES;   // one frame carries one slot

// host-side proposal array the fake DMA engine reads from
localparam [63:0] HOST_BASE   = 64'h0000_0000_1000_0000;
localparam [63:0] HOST_STRIDE = 64'h0000_0000_0000_1000;

// ---------------------------------------------------------------- CSR map
localparam integer REG_ADDR_WIDTH = 24;
localparam integer REG_DATA_WIDTH = 32;

localparam [23:0] PROP_RB_BASE = 24'h001000;
localparam [23:0] CORE_RB_BASE = 24'h003000;

localparam [23:0] PROP_REG_MAGIC        = PROP_RB_BASE + 24'h000;
localparam [23:0] PROP_REG_SLOT_BYTES   = PROP_RB_BASE + 24'h00C;
localparam [23:0] PROP_REG_ENTRY_CNT_LO = PROP_RB_BASE + 24'h018;
localparam [23:0] PROP_REG_DMA_ADDR_LO  = PROP_RB_BASE + 24'h100;
localparam [23:0] PROP_REG_DMA_ADDR_HI  = PROP_RB_BASE + 24'h104;
localparam [23:0] PROP_REG_DMA_STRIDE_LO= PROP_RB_BASE + 24'h10C;
localparam [23:0] PROP_REG_DMA_STRIDE_HI= PROP_RB_BASE + 24'h110;
localparam [23:0] PROP_REG_DMA_COUNT    = PROP_RB_BASE + 24'h114;
localparam [23:0] PROP_REG_DMA_CONTROL  = PROP_RB_BASE + 24'h118;
localparam [23:0] PROP_REG_DMA_STATUS   = PROP_RB_BASE + 24'h11C;
localparam [23:0] PROP_REG_DMA_STATE    = PROP_RB_BASE + 24'h124;

localparam [23:0] CORE_REG_CONTROL      = CORE_RB_BASE + 24'h00C;
localparam [23:0] CORE_REG_CFG_RUN_ID   = CORE_RB_BASE + 24'h100;
localparam [23:0] CORE_REG_CFG_MEMBER   = CORE_RB_BASE + 24'h104;
localparam [23:0] CORE_REG_CFG_EFF_LOW  = CORE_RB_BASE + 24'h108;

localparam [2:0] PROP_STATE_IDLE = 3'd0;

`include "ssr_packet.vh"

localparam integer FRAME_BEATS = 1 + SLOT_BEATS;   // header beat + payload rows

// ---------------------------------------------------------------- clock, PTP
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

// ---------------------------------------------------------------- scoreboard
integer checks = 0, errors = 0;
task check(input condition, input string message);
begin
    checks = checks + 1;
    if (!condition) begin
        errors = errors + 1;
        $display("[%0t] ERROR: %0s", $realtime, message);
    end
end
endtask

// ---------------------------------------------------------------- CSR bus
// One bus, two register blocks, selected the same way ssr_dataplane selects
// them: by the block index in the upper address bits.
reg  [23:0] csr_addr = 24'd0;
reg  [31:0] csr_wdata = 32'd0;
reg         csr_wr_en = 1'b0;
reg         csr_rd_en = 1'b0;
wire [31:0] csr_rdata;

wire sel_prop = (csr_addr[23:12] == PROP_RB_BASE[23:12]);
wire sel_core = (csr_addr[23:12] == CORE_RB_BASE[23:12]);

wire prop_wr_ack, prop_rd_ack, core_wr_ack, core_rd_ack;
wire [31:0] prop_rdata, core_rdata;

wire csr_wr_ack = prop_wr_ack | core_wr_ack;
wire csr_rd_ack = prop_rd_ack | core_rd_ack;
assign csr_rdata = sel_prop ? prop_rdata : core_rdata;

task csr_write(input [23:0] a, input [31:0] d);
    integer g;
begin
    @(negedge clk); csr_addr = a; csr_wdata = d; csr_wr_en = 1'b1; g = 0;
    while (g < 32) begin @(posedge clk); #0.1; if (csr_wr_ack) g = 99; else g = g + 1; end
    @(negedge clk); csr_wr_en = 1'b0;
    if (g != 99) begin
        errors = errors + 1;
        $display("[%0t] ERROR: CSR write to %06h never acked", $realtime, a);
    end
end
endtask

task csr_read(input [23:0] a, output [31:0] d);
    integer g;
begin
    @(negedge clk); csr_addr = a; csr_rd_en = 1'b1; g = 0; d = 32'hDEAD_BEEF;
    while (g < 32) begin @(posedge clk); #0.1; if (csr_rd_ack) begin d = csr_rdata; g = 99; end else g = g + 1; end
    @(negedge clk); csr_rd_en = 1'b0;
    if (g != 99) begin
        errors = errors + 1;
        $display("[%0t] ERROR: CSR read from %06h never acked", $realtime, a);
    end
end
endtask

// ---------------------------------------------------------------- the core
wire        tx_start_pulse, tx_window, tx_end_pulse, round_start_pulse;
wire [63:0] core_round_id, tx_round_id;
wire [31:0] tx_run_id;
wire [7:0]  tx_row;
wire        core_halt;

reg        rx_valid = 1'b0;
reg [7:0]  rx_node  = 8'd0;
reg [7:0]  rx_row   = 8'd0;
reg [31:0] rx_run   = 32'd0;
reg [63:0] rx_round = 64'd0;
reg [7:0]  peer_row = 8'b111;

consensus_core #(
    .P_NODE_COUNT(NODE_COUNT), .P_NODE_ID(NODE_ID),
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH), .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .RB_BASE_ADDR(CORE_RB_BASE),
    .ROUND_LENGTH_NS(ROUND_LENGTH_NS), .GUARD_TIME_NS(GUARD_TIME_NS),
    .TX_SUBSLOT_NS(TX_SUBSLOT_NS), .TX_ADMIT_MARGIN_NS(TX_ADMIT_MARGIN_NS)
) core (
    .clk(clk), .rst(rst), .i_enable(1'b1),
    .i_ptp_tod_sec(time_seconds), .i_ptp_tod_ns(time_nanoseconds),
    .i_ptp_time_valid(1'b1), .i_ptp_step(1'b0),

    .reg_wr_addr(csr_addr), .reg_wr_data(csr_wdata), .reg_wr_strb(4'hF),
    .reg_wr_en(csr_wr_en && sel_core), .reg_wr_wait(), .reg_wr_ack(core_wr_ack),
    .reg_rd_addr(csr_addr), .reg_rd_en(csr_rd_en && sel_core),
    .reg_rd_data(core_rdata), .reg_rd_wait(), .reg_rd_ack(core_rd_ack),

    .o_round_id(core_round_id), .o_round_start_pulse(round_start_pulse),
    .o_round_boundary_pulse(),
    .o_tx_start_pulse(tx_start_pulse), .o_tx_end_pulse(tx_end_pulse),
    .o_tx_window(tx_window),
    .o_rx_start_pulse(), .o_rx_end_pulse(), .o_rx_window(),
    .o_tx_round_id(tx_round_id), .o_tx_run_id(tx_run_id), .o_tx_row(tx_row),
    .i_rx_valid(rx_valid), .i_rx_node_id(rx_node), .i_rx_row(rx_row),
    .i_rx_run_id(rx_run), .i_rx_round_id(rx_round), .o_rx_accepted(),
    .o_commit_valid(), .o_commit_round_id(), .o_commit_set(),
    .o_halt(core_halt), .o_time_fault(), .o_time_fault_count()
);

// Peers must keep speaking or the core loses quorum and halts, and a halted core
// stops pulsing o_tx_start_pulse - which looks exactly like a broken proposal
// path. Keeping them alive is what makes a transmit failure here mean something.
integer inject_i;
always @(posedge round_start_pulse) begin
    repeat (GUARD_TIME_NS/CLK_PERIOD_NS + 4) @(posedge clk);
    for (inject_i = 0; inject_i < NODE_COUNT; inject_i = inject_i + 1) begin
        if (inject_i != NODE_ID) begin
            @(negedge clk);
            rx_node = inject_i[7:0]; rx_row = peer_row;
            rx_run = tx_run_id; rx_round = core_round_id; rx_valid = 1'b1;
            @(negedge clk); rx_valid = 1'b0;
        end
    end
end

// ---------------------------------------------------------------- the path
wire                       tail_slot_valid;
wire [RAM_ADDR_WIDTH-1:0]  tail_slot_addr;
wire                       tail_slot_commit;

wire [DMA_ADDR_WIDTH-1:0]  desc_dma_addr;
wire [RAM_SEL_WIDTH-1:0]   desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0]  desc_ram_addr;
wire [DMA_LEN_WIDTH-1:0]   desc_len;
wire [DMA_TAG_WIDTH-1:0]   desc_tag;
wire                       desc_valid;
reg                        desc_ready = 1'b1;

reg  [DMA_TAG_WIDTH-1:0]   status_tag   = {DMA_TAG_WIDTH{1'b0}};
reg  [3:0]                 status_error = 4'd0;
reg                        status_valid = 1'b0;

proposal_dma_reader #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH), .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .RB_BASE_ADDR(PROP_RB_BASE),
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH), .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH), .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEL_PROP(0), .DMA_TAG_PROP(0),
    .PROPOSAL_SLOT_BYTES(SLOT_BYTES)
) reader (
    .clk(clk), .rst(rst),
    .reg_wr_addr(csr_addr), .reg_wr_data(csr_wdata), .reg_wr_strb(4'hF),
    .reg_wr_en(csr_wr_en && sel_prop), .reg_wr_wait(), .reg_wr_ack(prop_wr_ack),
    .reg_rd_addr(csr_addr), .reg_rd_en(csr_rd_en && sel_prop),
    .reg_rd_data(prop_rdata), .reg_rd_wait(), .reg_rd_ack(prop_rd_ack),

    .m_axis_dma_read_desc_dma_addr(desc_dma_addr),
    .m_axis_dma_read_desc_ram_sel(desc_ram_sel),
    .m_axis_dma_read_desc_ram_addr(desc_ram_addr),
    .m_axis_dma_read_desc_len(desc_len),
    .m_axis_dma_read_desc_tag(desc_tag),
    .m_axis_dma_read_desc_valid(desc_valid),
    .m_axis_dma_read_desc_ready(desc_ready),

    .s_axis_dma_read_desc_status_tag(status_tag),
    .s_axis_dma_read_desc_status_error(status_error),
    .s_axis_dma_read_desc_status_valid(status_valid),

    .tail_slot_valid(tail_slot_valid),
    .tail_slot_addr(tail_slot_addr),
    .tail_slot_commit(tail_slot_commit)
);

reg  [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      wr_sel   = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   wr_be    = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] wr_data  = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] wr_addr  = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT-1:0]                    wr_valid = {RAM_SEG_COUNT{1'b0}};
wire [RAM_SEG_COUNT-1:0]                    wr_ready, wr_done;

wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] buf_rd_data;
wire                                        buf_rd_valid, buf_tx_last, buf_rd_ready;
wire [DMA_LEN_WIDTH-1:0]                    buf_tx_len;

proposal_buffer #(
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH), .RAM_SEL_PROP(0),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH), .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH), .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH), .RAM_PIPELINE(RAM_PIPELINE),
    .PROPOSAL_SLOT_BYTES(SLOT_BYTES), .PROPOSAL_SLOT_COUNT(SLOT_COUNT)
) buffer (
    .clk(clk), .rst(rst),
    .tail_slot_valid(tail_slot_valid), .tail_slot_addr(tail_slot_addr),
    .tail_slot_commit(tail_slot_commit),
    .dma_ram_wr_cmd_sel(wr_sel), .dma_ram_wr_cmd_be(wr_be),
    .dma_ram_wr_cmd_data(wr_data), .dma_ram_wr_cmd_addr(wr_addr),
    .dma_ram_wr_cmd_valid(wr_valid), .dma_ram_wr_cmd_ready(wr_ready),
    .dma_ram_wr_done(wr_done),
    .buf_rd_data(buf_rd_data), .buf_rd_be(), .buf_rd_valid(buf_rd_valid),
    .buf_rd_ready(buf_rd_ready), .buf_tx_last(buf_tx_last), .buf_tx_len(buf_tx_len)
);

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
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT), .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH)
) txe (
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

// ---------------------------------------------------------------- fake DMA
// The payload is a function of the descriptor's dma_addr, so a frame carrying
// entry k proves the engine was pointed at HOST_BASE + k*HOST_STRIDE.
function [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] host_word(input integer entry, input integer beat);
    integer lane;
    reg [7:0] e8, b8, l8;
begin
    host_word = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
    e8 = 8'hA0 + entry[7:0];
    b8 = beat[7:0];
    for (lane = 0; lane < (RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH)/32; lane = lane + 1) begin
        l8 = lane[7:0];
        host_word[lane*32 +: 32] = {8'h5A, l8, b8, e8};   // byte 0 of the beat is e8
    end
end
endfunction

integer descs_seen   = 0;      // descriptors accepted since the last arm
integer dma_latency  = 6;      // cycles between last write beat and status
reg     inject_error = 1'b0;   // next descriptor completes with an error

integer cap_entry, cap_beat, cap_row;
// Sized, not an integer: {RAM_SEG_COUNT{<32-bit>}} truncates to the port width
// from the LSB end, which leaves segment 1 addressing row 0 for every beat.
reg [RAM_SEG_ADDR_WIDTH-1:0] cap_row_v;
reg [DMA_ADDR_WIDTH-1:0] cap_dma_addr;
reg [RAM_ADDR_WIDTH-1:0] cap_ram_addr;
reg [DMA_LEN_WIDTH-1:0]  cap_len;
reg [DMA_TAG_WIDTH-1:0]  cap_tag;

initial begin : fake_dma_engine
    forever begin
        @(negedge clk);
        if (!rst && desc_valid && desc_ready) begin
            cap_dma_addr = desc_dma_addr;
            cap_ram_addr = desc_ram_addr;
            cap_len      = desc_len;
            cap_tag      = desc_tag;
            cap_entry    = (cap_dma_addr - HOST_BASE) / HOST_STRIDE;
            descs_seen   = descs_seen + 1;

            check(cap_len == SLOT_BYTES[DMA_LEN_WIDTH-1:0],
                  $sformatf("descriptor len %0d, expected %0d", cap_len, SLOT_BYTES));
            check(cap_dma_addr == HOST_BASE + cap_entry*HOST_STRIDE,
                  "descriptor dma_addr is not base + k*stride");
            check((cap_ram_addr % SLOT_BYTES) == 0,
                  $sformatf("descriptor ram_addr %0d is not slot aligned", cap_ram_addr));
`ifdef SSR_TB_VERBOSE
            $display("[%0t]   DESC #%0d entry=a%0h ram_addr=%0d (slot %0d) tail_ptr=%0d cnt=%0d",
                     $realtime, descs_seen-1, 8'hA0+cap_entry, cap_ram_addr,
                     cap_ram_addr/SLOT_BYTES, buffer.tail_ptr_reg, buffer.slot_count_reg);
`endif

            // REGRESSION GUARD - see the comment on !tail_slot_commit_reg in
            // proposal_dma_reader.v. The reader used to sample tail_slot_addr in
            // the very cycle it presented tail_slot_commit, before the buffer had
            // retired it, so every descriptor after the first was aimed one slot
            // behind and overwrote a proposal that was already queued to send.
            // Nothing downstream notices: the frame is well formed, the counters
            // are right, and only the payload is wrong. Model the tail pointer
            // here so the address is checked rather than assumed.
            check(cap_ram_addr == model_tail*SLOT_BYTES,
                  $sformatf("descriptor #%0d targets slot %0d, buffer tail is slot %0d",
                            descs_seen-1, cap_ram_addr/SLOT_BYTES, model_tail));

            // write the slot into the buffer's RAM, one 64-byte beat per cycle
            cap_row = cap_ram_addr / BEAT_BYTES;
            for (cap_beat = 0; cap_beat < SLOT_BEATS; cap_beat = cap_beat + 1) begin
                @(negedge clk);
                cap_row_v = (cap_row + cap_beat);
                wr_addr   = {RAM_SEG_COUNT{cap_row_v}};
                wr_data  = host_word(cap_entry, cap_beat);
                wr_be    = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};
                wr_valid = {RAM_SEG_COUNT{1'b1}};
            end
            @(negedge clk); wr_valid = {RAM_SEG_COUNT{1'b0}};

            repeat (dma_latency) @(posedge clk);
            @(negedge clk);
            status_tag   = cap_tag;
            status_error = inject_error ? 4'd3 : 4'd0;
            status_valid = 1'b1;
            @(negedge clk);
            status_valid = 1'b0;
            inject_error = 1'b0;      // one-shot
        end
    end
end

// ---------------------------------------------------------------- frame check
reg [AXIS_DATA_WIDTH-1:0] seen = {AXIS_DATA_WIDTH{1'b0}};
integer frames_seen = 0, payload_frames = 0, zero_frames = 0, payload_beats_seen = 0;
integer beat_in_frame = 0;
integer cur_entry = -1;
integer payload_beat;
reg [15:0] frame_len_reg;

// Exact expectation model: an entry becomes transmittable the moment its slot is
// committed, and tx_engine consumes committed slots in order. Counting frames
// instead would go wrong the first time a batch leaves slots in the ring.
integer exp_q [0:255];
integer exp_head = 0, exp_tail = 0;
integer model_tail = 0;                 // independent model of buffer.tail_ptr_reg
always @(posedge clk) if (!rst && tail_slot_commit && buffer.tail_slot_valid) begin
    exp_q[exp_tail % 256] = cap_entry;
    exp_tail   = exp_tail + 1;
    model_tail = (model_tail + 1) % SLOT_COUNT;
end

function [15:0] rd16(input integer off);
    rd16 = {seen[off*8 +: 8], seen[(off+1)*8 +: 8]};
endfunction
function [31:0] rd32(input integer off);
    rd32 = {seen[off*8 +: 8], seen[(off+1)*8 +: 8], seen[(off+2)*8 +: 8], seen[(off+3)*8 +: 8]};
endfunction
function [63:0] rd64(input integer off);
    rd64 = {seen[off*8 +: 8], seen[(off+1)*8 +: 8], seen[(off+2)*8 +: 8], seen[(off+3)*8 +: 8],
            seen[(off+4)*8 +: 8], seen[(off+5)*8 +: 8], seen[(off+6)*8 +: 8], seen[(off+7)*8 +: 8]};
endfunction

// Beat 0 is the header, beats 1..N are proposal_buffer rows byte for byte. That
// identity is the whole point of padding the header to a beat, so it is checked
// row by row rather than sampled - a barrel-shift bug would show up as every
// beat being 34 bytes out of phase, which a spot check on byte 0 would miss.
always @(posedge clk) begin
    if (!rst && axis_tvalid && axis_tready) begin
        check(axis_tkeep == {AXIS_KEEP_WIDTH{1'b1}}, "every beat of an SSR frame is full");

        if (beat_in_frame == 0) begin
            seen = axis_tdata;
            frames_seen = frames_seen + 1;
            frame_len_reg = rd16(SSR_OFF_LENGTH);

            check(rd16(SSR_OFF_ETHERTYPE) == SSR_ETHERTYPE, "ethertype");
            check(seen[SSR_OFF_NODE_ID*8 +: 8] == NODE_ID[7:0], "node_id");
            check(rd64(SSR_OFF_ROUND_ID) == tx_round_id, "round_id must match the core");
            check(rd32(SSR_OFF_RUN_ID) == tx_run_id, "run_id must match the core");
            check(seen[SSR_OFF_ROW*8 +: 8] == tx_row, "row must match the core");
            check(seen[SSR_OFF_RESERVED*8 +: (SSR_OFF_PAYLOAD-SSR_OFF_RESERVED)*8] == 0,
                  "header padding must be zero");

            if (frame_len_reg == 16'd0) begin
                // an empty proposal queue: header-only, and length says so
                zero_frames = zero_frames + 1;
                check(axis_tlast === 1'b1, "a length-0 frame must end on the header beat");
                cur_entry = -1;
            end else begin
                payload_frames = payload_frames + 1;
                check(frame_len_reg == SLOT_BYTES[15:0],
                      $sformatf("length %0d, expected %0d (the buffer's slot size)",
                                frame_len_reg, SLOT_BYTES));
                check(axis_tlast === 1'b0, "a frame with a payload cannot end on the header");
                if (exp_head == exp_tail) begin
                    check(1'b0, $sformatf("frame %0d has a payload but no slot was committed",
                                          frames_seen));
                    cur_entry = -1;
                end else begin
                    cur_entry = exp_q[exp_head % 256];
                    exp_head  = exp_head + 1;
                end
            end
            beat_in_frame = axis_tlast ? 0 : 1;
        end else begin
            payload_beat       = beat_in_frame - 1;
            payload_beats_seen = payload_beats_seen + 1;

            // THE END-TO-END ASSERTION: this beat is byte-for-byte the row the
            // DMA engine fetched from HOST_BASE + cur_entry*HOST_STRIDE.
            if (cur_entry >= 0)
                check(axis_tdata === host_word(cur_entry, payload_beat),
                      $sformatf("frame %0d payload beat %0d does not match entry a%0h",
                                frames_seen, payload_beat, 8'hA0 + cur_entry));

            if (axis_tlast) begin
                check(payload_beat == SLOT_BEATS-1,
                      $sformatf("frame ended on payload beat %0d, expected %0d",
                                payload_beat, SLOT_BEATS-1));
                beat_in_frame = 0;
            end else begin
                beat_in_frame = beat_in_frame + 1;
            end
        end
    end
end

// The local echo must mirror the wire exactly - it is the only copy of this
// node's own proposal that ever reaches its commit ring.
integer local_beats = 0, local_sofs = 0;
always @(posedge clk) if (!rst) begin
    if (local_sof)   local_sofs  = local_sofs + 1;
    if (local_valid) local_beats = local_beats + 1;
end

// ---------------------------------------------------------------- tests
integer n;
reg [31:0] rd;
integer frames_before, descs_before, entries_before;

task arm_batch(input integer count);
begin
    descs_seen = 0;
    csr_write(PROP_REG_DMA_ADDR_LO,   HOST_BASE[31:0]);
    csr_write(PROP_REG_DMA_ADDR_HI,   HOST_BASE[63:32]);
    csr_write(PROP_REG_DMA_STRIDE_LO, HOST_STRIDE[31:0]);
    csr_write(PROP_REG_DMA_STRIDE_HI, HOST_STRIDE[63:32]);
    csr_write(PROP_REG_DMA_COUNT,     count[31:0]);
    csr_write(PROP_REG_DMA_CONTROL,   32'h0000_0001);   // start
end
endtask

initial begin
    $dumpfile("build/tb_proposal_path.vcd");
    $dumpvars(0, tb_proposal_path);

    $display("=========================================================");
    $display(" tb_proposal_path  nodes=%0d id=%0d slot=%0dB ring=%0d",
             NODE_COUNT, NODE_ID, SLOT_BYTES, SLOT_COUNT);
    $display("=========================================================");

    rst = 1'b1; time_advancing = 1'b0;
    repeat (10) @(posedge clk);
    time_advancing = 1'b1;
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // ---------------- Test 0: both register blocks answer ----------------
    $display("[%0t] Test 0: CSR identity on both blocks", $realtime);
    csr_read(PROP_REG_MAGIC, rd);
    check(rd == 32'h70726F71, $sformatf("proposal MAGIC %08h, expected 70726F71 (\"proq\")", rd));
    csr_read(PROP_REG_SLOT_BYTES, rd);
    check(rd == SLOT_BYTES, $sformatf("SLOT_BYTES reads %0d, expected %0d", rd, SLOT_BYTES));
    csr_read(PROP_REG_DMA_STATE, rd);
    check(rd[2:0] == PROP_STATE_IDLE, "reader should start idle");

    // ---------------- bring the core up ----------------------------------
    csr_write(CORE_REG_CFG_RUN_ID,   32'h0000_0055);
    csr_write(CORE_REG_CFG_MEMBER,   32'h0000_0007);
    csr_write(CORE_REG_CFG_EFF_LOW,  32'h0000_0100);
    csr_write(CORE_REG_CONTROL,      32'h0000_0003);   // enable | activate

    wait (core.state_reg == 2'd2);
    repeat (3*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(core.state_reg == 2'd2, "core should be running after activation");
    check(core_halt === 1'b0, "core must not halt while peers agree");

    // ---------------- Test 1: an empty queue still transmits -------------
    // Regression on the rule that a round always puts a frame on the wire: a
    // node that goes quiet because it has nothing to propose gets evicted.
    $display("[%0t] Test 1: empty queue still transmits", $realtime);
    frames_before = frames_seen;
    repeat (2*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(frames_seen > frames_before, "no frame went out with an empty queue");
    check(zero_frames > 0, "an empty-queue frame should carry a zero payload");

    // ---------------- Test 2: descriptors are issued as configured -------
    $display("[%0t] Test 2: batch of 6 into a %0d-slot ring", $realtime, SLOT_COUNT);
    csr_read(PROP_REG_ENTRY_CNT_LO, entries_before);
    arm_batch(6);

    // The ring is smaller than the batch, so the reader cannot finish until
    // tx_engine has drained slots. Give it enough rounds to do so.
    repeat (10*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);

    check(descs_seen == 6, $sformatf("expected 6 descriptors, saw %0d", descs_seen));
    csr_read(PROP_REG_DMA_STATUS, rd);
    check(rd[1] == 1'b1, "batch should report done");
    check(rd[2] == 1'b0, "batch should report no error");
    check(rd[0] == 1'b0, "batch should no longer be running");
    csr_read(PROP_REG_ENTRY_CNT_LO, rd);
    check(rd - entries_before == 6,
          $sformatf("entry counter advanced by %0d, expected 6", rd - entries_before));

    // ---------------- Test 3: the payload reaches the wire ---------------
    // This is the assertion the whole bench exists for. The per-frame check in
    // the monitor has already been running; here we only confirm enough frames
    // carried real payloads, in order, to make it meaningful.
    $display("[%0t] Test 3: host payloads arrive on the wire in order", $realtime);
    check(payload_frames >= 4,
          $sformatf("only %0d frames carried a payload; expected at least 4", payload_frames));
    check(exp_tail == 6, $sformatf("%0d slots were committed, expected 6", exp_tail));
    check(payload_beats_seen == payload_frames*SLOT_BEATS,
          $sformatf("%0d payload beats for %0d frames; expected %0d",
                    payload_beats_seen, payload_frames, payload_frames*SLOT_BEATS));
    check(local_sofs == frames_seen,
          $sformatf("local echo saw %0d frames, the wire saw %0d", local_sofs, frames_seen));
    check(local_beats == payload_beats_seen,
          $sformatf("local echo saw %0d payload beats, the wire saw %0d",
                    local_beats, payload_beats_seen));
    $display("        %0d frames total, %0d with payload (%0d beats), %0d header-only",
             frames_seen, payload_frames, payload_beats_seen, zero_frames);

    // ---------------- Test 4: a DMA error must not commit a slot ---------
    // If the reader committed on error, tx_engine would transmit whatever
    // happened to be in the slot RAM - stale bytes presented as a proposal.
    $display("[%0t] Test 4: a failed DMA does not commit its slot", $realtime);
    descs_before = descs_seen;
    inject_error = 1'b1;
    csr_read(PROP_REG_ENTRY_CNT_LO, entries_before);
    arm_batch(3);
    repeat (4*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);

    csr_read(PROP_REG_DMA_STATUS, rd);
    check(rd[2] == 1'b1, "a DMA error must set the error flag");
    check(rd[0] == 1'b0, "the batch must stop running after an error");
    csr_read(PROP_REG_ENTRY_CNT_LO, rd);
    check(rd - entries_before == 0,
          $sformatf("entry counter moved by %0d after a failed DMA; expected 0", rd - entries_before));
    csr_read(PROP_REG_DMA_STATE, rd);
    check(rd[2:0] == PROP_STATE_IDLE, "reader should be back in idle after an error");

    // ---------------- Test 5: it recovers and keeps running --------------
    $display("[%0t] Test 5: a new batch after the error", $realtime);
    check(core_halt === 1'b0, "core must still be running");
    arm_batch(3);
    repeat (8*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    csr_read(PROP_REG_DMA_STATUS, rd);
    check(rd[1] == 1'b1 && rd[2] == 1'b0, "the batch after an error should complete cleanly");
    check(missed_count == 32'd0,
          $sformatf("tx_engine missed %0d rounds; the path stalled", missed_count));
    check(len_mismatch_count == 32'd0,
          "the buffer's tx_len and tx_last disagree with each other");
    check(oversize_count == 32'd0, "the buffer offered more than the link budget");
    check(core_halt === 1'b0, "core must not have halted during the run");

    $display("--------------------------------------------------");
    $display("frames=%0d  payload=%0d (%0d beats)  header-only=%0d  descriptors=%0d",
             frames_seen, payload_frames, payload_beats_seen, zero_frames, descs_seen);
    $display("tx: frame=%0d empty=%0d overrun=%0d missed=%0d len_mismatch=%0d oversize=%0d",
             frame_count, empty_count, overrun_count, missed_count,
             len_mismatch_count, oversize_count);
    $display("local echo: sof=%0d beats=%0d", local_sofs, local_beats);
    $display("checks : %0d", checks);
    $display("errors : %0d", errors);
    $display("--------------------------------------------------");
    if (errors == 0) $display("[%0t] ALL TESTS PASSED", $realtime);
    else             $display("[%0t] %0d FAILURES", $realtime, errors);
    $finish;
end

initial begin
    #3000000;
    $display("ERROR: timeout");
    $display("errors : %0d", errors + 1);
    $finish;
end

endmodule

`default_nettype wire
