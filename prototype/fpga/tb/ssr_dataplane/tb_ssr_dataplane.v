`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_dataplane - the integration bench for the real ssr_dataplane wrapper.
 *
 *   CSR ─┬─► [common block]        counters, timestamps
 *        ├─► [proposal_dma_reader] arm a DMA batch
 *        └─► [consensus_core]      enable + activate
 *
 *   proposal_dma_reader ──desc──► [fake DMA engine] ──ram_wr──► proposal_buffer
 *                                                                    │
 *   consensus_core ──tx timing──► tx_engine ──┐                      │
 *                                             ├─► ssr_tx_mux ─► port model
 *   host TX stream ───────────────────────────┘        ▲   │
 *                                                      │   └─► m_axis cpl
 *                                       completions ───┘        (host only)
 *
 * WHAT THIS BENCH IS FOR, AND WHAT IT IS NOT FOR
 *   tb_proposal_path already proves the proposal datapath itself: a payload
 *   placed at a host address leaves tx_engine in the frame for the round the
 *   core named. It does that on hand-instantiated modules, wired by the bench.
 *
 *   Nothing there touches ssr_dataplane.v, and ssr_dataplane.v is where the
 *   wiring mistakes actually live - a module instantiated on its defaults, a
 *   CSR decoded at the wrong offset, a completion stream forwarded to the
 *   interface. This bench instantiates the wrapper unmodified and checks the
 *   four properties that only exist at that level:
 *
 *     1. the CSR map brings the core up and reports the transmit counters
 *     2. a proposal armed through the CSR reaches the port with its payload
 *     3. an SSR frame's completion is CONSUMED, never forwarded, and its PTP
 *        timestamp lands in the common register block
 *     4. a host frame's completion is still forwarded untouched, and a host
 *        frame sharing the port with SSR is never interleaved with one
 *
 * WHY (3) AND (4) ARE THE POINT
 *   Corundum's interface matches a transmit completion's tag against its own
 *   descriptor table. An SSR frame has no descriptor - the application injected
 *   it - so forwarding its completion retires a descriptor that was never
 *   posted and corrupts the completion queue the driver is reading. There is no
 *   way to see that from a unit bench on tx_engine, and no way to see it in
 *   hardware except as driver corruption a long way downstream.
 *
 * WHY THE CLUSTER IS ONE NODE HERE
 *   The core halts on its first boundary without a quorum of matching rows, so
 *   a 3-node configuration needs peer frames arriving on the receive path every
 *   round. The receive path inside this wrapper is still the OLD consensus_rx,
 *   which parses the pre-refactor wire format (64-bit run_id at byte 14, no
 *   64-byte header beat) - feeding it would mean generating frames in a format
 *   nothing else in the tree still speaks, and testing a module that is on its
 *   way out.
 *
 *   With P_NODE_COUNT = 1 the quorum is one and the node witnesses its own row,
 *   so the core runs indefinitely with no receive traffic at all. Multi-node
 *   timing and the agreement rules are tb_proposal_path's and tb_core_protocol's
 *   job; this bench is about the wrapper's wiring. Revisit when rx_engine
 *   replaces consensus_rx here.
 */

module tb_ssr_dataplane;

// ---------------------------------------------------------------- geometry
localparam integer CLK_PERIOD_NS   = 4;

localparam integer NODE_COUNT      = 1;
localparam integer NODE_ID         = 0;
localparam integer ROUND_LENGTH_NS = 4000;
localparam integer GUARD_TIME_NS   = 200;

localparam integer AXIS_DATA_WIDTH = 512;
localparam integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8;
localparam integer TX_TAG_WIDTH    = 16;
localparam integer AXIS_TX_USER_WIDTH = TX_TAG_WIDTH + 1;   // 17
localparam integer PTP_TS_WIDTH    = 96;
localparam integer AXIS_TX_ID_WIDTH   = 12;
localparam integer AXIS_TX_DEST_WIDTH = 4;
localparam integer AXIS_RX_ID_WIDTH   = 1;
localparam integer AXIS_RX_DEST_WIDTH = 8;
localparam integer AXIS_RX_USER_WIDTH = PTP_TS_WIDTH + 1;

localparam integer REG_ADDR_WIDTH = 24;
localparam integer REG_DATA_WIDTH = 32;

localparam integer DMA_ADDR_WIDTH = 64;
localparam integer DMA_IMM_WIDTH  = 32;
localparam integer DMA_LEN_WIDTH  = 16;
localparam integer DMA_TAG_WIDTH  = 16;
localparam integer RAM_SEL_WIDTH  = 4;
localparam integer RAM_ADDR_WIDTH = 16;
localparam integer RAM_SEG_COUNT  = 2;
localparam integer RAM_SEG_DATA_WIDTH = 256;
localparam integer RAM_SEG_BE_WIDTH   = RAM_SEG_DATA_WIDTH/8;
localparam integer RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH);

localparam integer SLOT_BYTES = 1024;
localparam integer SLOT_COUNT = 8;
localparam integer BEAT_BYTES = RAM_SEG_COUNT*RAM_SEG_BE_WIDTH;   // 64
localparam integer SLOT_BEATS = SLOT_BYTES/BEAT_BYTES;            // 16

// The tag ssr_dataplane hands tx_engine, and the bit ssr_tx_mux filters on.
localparam [15:0]  SSR_TX_CPL_TAG = 16'h8000;
localparam integer SSR_TAG_BIT    = 15;

localparam [63:0] HOST_BASE   = 64'h0000_0000_2000_0000;
localparam [63:0] HOST_STRIDE = 64'h0000_0000_0000_1000;

// ---------------------------------------------------------------- CSR map
localparam [23:0] RBB_COMMON   = 24'h000000;
localparam [23:0] RBB_PROPOSAL = 24'h001000;
localparam [23:0] RBB_CONSENSUS= 24'h003000;

localparam [23:0] COMMON_REG_TYPE     = RBB_COMMON + 24'h000;
localparam [23:0] COMMON_REG_VERSION  = RBB_COMMON + 24'h004;
localparam [23:0] COMMON_REG_SCRATCH  = RBB_COMMON + 24'h01c;
localparam [23:0] COMMON_REG_REPLICA_ID  = RBB_COMMON + 24'h020;
localparam [23:0] COMMON_REG_REPLICA_NUM = RBB_COMMON + 24'h024;
localparam [23:0] COMMON_REG_ROUND_LEN   = RBB_COMMON + 24'h028;
localparam [23:0] COMMON_REG_STATUS      = RBB_COMMON + 24'h014;

localparam [23:0] COMMON_REG_TX_FRAME    = RBB_COMMON + 24'h030;
localparam [23:0] COMMON_REG_TX_EMPTY    = RBB_COMMON + 24'h034;
localparam [23:0] COMMON_REG_TX_OVERRUN  = RBB_COMMON + 24'h038;
localparam [23:0] COMMON_REG_TX_MISSED   = RBB_COMMON + 24'h03c;
localparam [23:0] COMMON_REG_CPL_TS_0    = RBB_COMMON + 24'h040;
localparam [23:0] COMMON_REG_CPL_TS_1    = RBB_COMMON + 24'h044;
localparam [23:0] COMMON_REG_CPL_TS_2    = RBB_COMMON + 24'h048;
localparam [23:0] COMMON_REG_CPL_COUNT   = RBB_COMMON + 24'h04c;
localparam [23:0] COMMON_REG_CPL_OVERRUN = RBB_COMMON + 24'h050;
localparam [23:0] COMMON_REG_MUX_SSR     = RBB_COMMON + 24'h054;
localparam [23:0] COMMON_REG_MUX_DMA     = RBB_COMMON + 24'h058;
localparam [23:0] COMMON_REG_TX_LEN_MISMATCH = RBB_COMMON + 24'h05c;

localparam [23:0] PROP_REG_MAGIC        = RBB_PROPOSAL + 24'h000;
localparam [23:0] PROP_REG_SLOT_BYTES   = RBB_PROPOSAL + 24'h00C;
localparam [23:0] PROP_REG_ENTRY_CNT_LO = RBB_PROPOSAL + 24'h018;
localparam [23:0] PROP_REG_DMA_ADDR_LO  = RBB_PROPOSAL + 24'h100;
localparam [23:0] PROP_REG_DMA_ADDR_HI  = RBB_PROPOSAL + 24'h104;
localparam [23:0] PROP_REG_DMA_STRIDE_LO= RBB_PROPOSAL + 24'h10C;
localparam [23:0] PROP_REG_DMA_STRIDE_HI= RBB_PROPOSAL + 24'h110;
localparam [23:0] PROP_REG_DMA_COUNT    = RBB_PROPOSAL + 24'h114;
localparam [23:0] PROP_REG_DMA_CONTROL  = RBB_PROPOSAL + 24'h118;
localparam [23:0] PROP_REG_DMA_STATUS   = RBB_PROPOSAL + 24'h11C;

localparam [23:0] CORE_REG_STATUS       = RBB_CONSENSUS + 24'h010;
localparam [23:0] CORE_REG_CONTROL      = RBB_CONSENSUS + 24'h00C;
localparam [23:0] CORE_REG_CFG_RUN_ID   = RBB_CONSENSUS + 24'h100;
localparam [23:0] CORE_REG_CFG_MEMBER   = RBB_CONSENSUS + 24'h104;
localparam [23:0] CORE_REG_CFG_EFF_LOW  = RBB_CONSENSUS + 24'h108;

`include "ssr_packet.vh"

// ---------------------------------------------------------------- clock, PTP
reg clk = 1'b0, rst = 1'b1;
always #(CLK_PERIOD_NS/2.0) clk = ~clk;

reg [47:0] time_seconds     = 48'd11;
reg [31:0] time_nanoseconds = 32'd0;
reg        time_advancing   = 1'b0;
always @(posedge clk) if (time_advancing) begin
    if (time_nanoseconds + CLK_PERIOD_NS >= 32'd1_000_000_000) begin
        time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS - 32'd1_000_000_000;
        time_seconds     <= time_seconds + 48'd1;
    end else time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS;
end

// PTP_TS_FMT_TOD with PTP_SIM=0: sec in [95:48], ns in [47:16], fractional ns
// in [15:0]. ssr_dataplane slices it exactly this way to feed the core.
wire [PTP_TS_WIDTH-1:0] ptp_ts_rel = {time_seconds, time_nanoseconds, 16'd0};

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
// One bus into the wrapper; the wrapper does its own block decode on
// addr[23:12], which is half of what this bench is here to check.
reg  [REG_ADDR_WIDTH-1:0] csr_addr  = 24'd0;
reg  [REG_DATA_WIDTH-1:0] csr_wdata = 32'd0;
reg                       csr_wr_en = 1'b0;
reg                       csr_rd_en = 1'b0;
wire [REG_DATA_WIDTH-1:0] csr_rdata;
wire                      csr_wr_ack, csr_rd_ack, csr_wr_wait, csr_rd_wait;

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

// ---------------------------------------------------------------- DMA plumbing
wire [DMA_ADDR_WIDTH-1:0] rd_desc_dma_addr;
wire [RAM_SEL_WIDTH-1:0]  rd_desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0] rd_desc_ram_addr;
wire [DMA_LEN_WIDTH-1:0]  rd_desc_len;
wire [DMA_TAG_WIDTH-1:0]  rd_desc_tag;
wire                      rd_desc_valid;
reg                       rd_desc_ready = 1'b1;

reg  [DMA_TAG_WIDTH-1:0]  rd_status_tag   = {DMA_TAG_WIDTH{1'b0}};
reg  [3:0]                rd_status_error = 4'd0;
reg                       rd_status_valid = 1'b0;

reg  [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      wr_sel   = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   wr_be    = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] wr_data  = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] wr_addr  = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT-1:0]                    wr_valid = {RAM_SEG_COUNT{1'b0}};
wire [RAM_SEG_COUNT-1:0]                    wr_ready, wr_done;

// ---------------------------------------------------------------- TX streams
// host -> wrapper (the interface's own DMA transmit path)
reg  [AXIS_DATA_WIDTH-1:0]    host_tx_tdata  = {AXIS_DATA_WIDTH{1'b0}};
reg  [AXIS_KEEP_WIDTH-1:0]    host_tx_tkeep  = {AXIS_KEEP_WIDTH{1'b0}};
reg                           host_tx_tvalid = 1'b0;
wire                          host_tx_tready;
reg                           host_tx_tlast  = 1'b0;
reg  [AXIS_TX_ID_WIDTH-1:0]   host_tx_tid    = {AXIS_TX_ID_WIDTH{1'b0}};
reg  [AXIS_TX_DEST_WIDTH-1:0] host_tx_tdest  = {AXIS_TX_DEST_WIDTH{1'b0}};
reg  [AXIS_TX_USER_WIDTH-1:0] host_tx_tuser  = {AXIS_TX_USER_WIDTH{1'b0}};

// wrapper -> port
wire [AXIS_DATA_WIDTH-1:0]    port_tx_tdata;
wire [AXIS_KEEP_WIDTH-1:0]    port_tx_tkeep;
wire                          port_tx_tvalid;
reg                           port_tx_tready = 1'b1;
wire                          port_tx_tlast;
wire [AXIS_TX_ID_WIDTH-1:0]   port_tx_tid;
wire [AXIS_TX_DEST_WIDTH-1:0] port_tx_tdest;
wire [AXIS_TX_USER_WIDTH-1:0] port_tx_tuser;

// port -> wrapper completions
reg  [PTP_TS_WIDTH-1:0]  port_cpl_ts    = {PTP_TS_WIDTH{1'b0}};
reg  [TX_TAG_WIDTH-1:0]  port_cpl_tag   = {TX_TAG_WIDTH{1'b0}};
reg                      port_cpl_valid = 1'b0;
wire                     port_cpl_ready;

// wrapper -> interface completions (SSR removed)
wire [PTP_TS_WIDTH-1:0]  if_cpl_ts;
wire [TX_TAG_WIDTH-1:0]  if_cpl_tag;
wire                     if_cpl_valid;
reg                      if_cpl_ready = 1'b1;

// ---------------------------------------------------------------- DUT
ssr_dataplane #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .IF_COUNT(1),
    .PORTS_PER_IF(1),
    .PTP_TS_ENABLE(1),
    .PTP_TS_FMT_TOD(1),
    // Drive a real time-of-day rather than the simulation format, so the
    // bench's own clock IS the core's clock and the round boundaries are
    // predictable from ROUND_LENGTH_NS alone.
    .PTP_SIM(0),
    .TX_TAG_WIDTH(TX_TAG_WIDTH),
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_BUFF_SLOT_BYTES(SLOT_BYTES),
    .RAM_BUFF_SLOT_COUNT(SLOT_COUNT),
    .AXIS_IF_DATA_WIDTH(AXIS_DATA_WIDTH),
    .P_NODE_ID(NODE_ID),
    .P_NODE_COUNT(NODE_COUNT),
    .P_SLOT_DURATION_NS(ROUND_LENGTH_NS),
    .P_GUARD_NS(GUARD_TIME_NS)
) dut (
    .clk(clk),
    .rst(rst),

    .reg_wr_addr(csr_addr), .reg_wr_data(csr_wdata), .reg_wr_strb(4'hF),
    .reg_wr_en(csr_wr_en), .reg_wr_wait(csr_wr_wait), .reg_wr_ack(csr_wr_ack),
    .reg_rd_addr(csr_addr), .reg_rd_en(csr_rd_en),
    .reg_rd_data(csr_rdata), .reg_rd_wait(csr_rd_wait), .reg_rd_ack(csr_rd_ack),

    .m_axis_data_dma_read_desc_dma_addr(rd_desc_dma_addr),
    .m_axis_data_dma_read_desc_ram_sel(rd_desc_ram_sel),
    .m_axis_data_dma_read_desc_ram_addr(rd_desc_ram_addr),
    .m_axis_data_dma_read_desc_len(rd_desc_len),
    .m_axis_data_dma_read_desc_tag(rd_desc_tag),
    .m_axis_data_dma_read_desc_valid(rd_desc_valid),
    .m_axis_data_dma_read_desc_ready(rd_desc_ready),

    .s_axis_data_dma_read_desc_status_tag(rd_status_tag),
    .s_axis_data_dma_read_desc_status_error(rd_status_error),
    .s_axis_data_dma_read_desc_status_valid(rd_status_valid),

    // The commit direction is not exercised here - tie its handshake off so it
    // can never stall, and leave its outputs unobserved.
    .m_axis_data_dma_write_desc_dma_addr(), .m_axis_data_dma_write_desc_ram_sel(),
    .m_axis_data_dma_write_desc_ram_addr(), .m_axis_data_dma_write_desc_imm(),
    .m_axis_data_dma_write_desc_imm_en(), .m_axis_data_dma_write_desc_len(),
    .m_axis_data_dma_write_desc_tag(), .m_axis_data_dma_write_desc_valid(),
    .m_axis_data_dma_write_desc_ready(1'b1),
    .s_axis_data_dma_write_desc_status_tag({DMA_TAG_WIDTH{1'b0}}),
    .s_axis_data_dma_write_desc_status_error(4'd0),
    .s_axis_data_dma_write_desc_status_valid(1'b0),

    .data_dma_ram_wr_cmd_sel(wr_sel),
    .data_dma_ram_wr_cmd_be(wr_be),
    .data_dma_ram_wr_cmd_addr(wr_addr),
    .data_dma_ram_wr_cmd_data(wr_data),
    .data_dma_ram_wr_cmd_valid(wr_valid),
    .data_dma_ram_wr_cmd_ready(wr_ready),
    .data_dma_ram_wr_done(wr_done),

    .data_dma_ram_rd_cmd_sel({RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}}),
    .data_dma_ram_rd_cmd_addr({RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}}),
    .data_dma_ram_rd_cmd_valid({RAM_SEG_COUNT{1'b0}}),
    .data_dma_ram_rd_cmd_ready(),
    .data_dma_ram_rd_resp_data(),
    .data_dma_ram_rd_resp_valid(),
    .data_dma_ram_rd_resp_ready({RAM_SEG_COUNT{1'b1}}),

    .ptp_clk(clk), .ptp_rst(rst), .ptp_sample_clk(clk),
    .ptp_td_sd(1'b0), .ptp_pps(1'b0), .ptp_pps_str(1'b0),
    .ptp_sync_locked(1'b1),
    .ptp_sync_ts_rel(ptp_ts_rel), .ptp_sync_ts_rel_step(1'b0),
    .ptp_sync_ts_tod(ptp_ts_rel), .ptp_sync_ts_tod_step(1'b0),
    .ptp_sync_pps(1'b0), .ptp_sync_pps_str(1'b0),
    .ptp_perout_locked(1'b0), .ptp_perout_error(1'b0), .ptp_perout_pulse(1'b0),

    .s_axis_if_tx_tdata(host_tx_tdata),
    .s_axis_if_tx_tkeep(host_tx_tkeep),
    .s_axis_if_tx_tvalid(host_tx_tvalid),
    .s_axis_if_tx_tready(host_tx_tready),
    .s_axis_if_tx_tlast(host_tx_tlast),
    .s_axis_if_tx_tid(host_tx_tid),
    .s_axis_if_tx_tdest(host_tx_tdest),
    .s_axis_if_tx_tuser(host_tx_tuser),

    .m_axis_if_tx_tdata(port_tx_tdata),
    .m_axis_if_tx_tkeep(port_tx_tkeep),
    .m_axis_if_tx_tvalid(port_tx_tvalid),
    .m_axis_if_tx_tready(port_tx_tready),
    .m_axis_if_tx_tlast(port_tx_tlast),
    .m_axis_if_tx_tid(port_tx_tid),
    .m_axis_if_tx_tdest(port_tx_tdest),
    .m_axis_if_tx_tuser(port_tx_tuser),

    .s_axis_if_tx_cpl_ts(port_cpl_ts),
    .s_axis_if_tx_cpl_tag(port_cpl_tag),
    .s_axis_if_tx_cpl_valid(port_cpl_valid),
    .s_axis_if_tx_cpl_ready(port_cpl_ready),

    .m_axis_if_tx_cpl_ts(if_cpl_ts),
    .m_axis_if_tx_cpl_tag(if_cpl_tag),
    .m_axis_if_tx_cpl_valid(if_cpl_valid),
    .m_axis_if_tx_cpl_ready(if_cpl_ready),

    .s_axis_if_rx_tdata({AXIS_DATA_WIDTH{1'b0}}),
    .s_axis_if_rx_tkeep({AXIS_KEEP_WIDTH{1'b0}}),
    .s_axis_if_rx_tvalid(1'b0),
    .s_axis_if_rx_tready(),
    .s_axis_if_rx_tlast(1'b0),
    .s_axis_if_rx_tid({AXIS_RX_ID_WIDTH{1'b0}}),
    .s_axis_if_rx_tdest({AXIS_RX_DEST_WIDTH{1'b0}}),
    .s_axis_if_rx_tuser({AXIS_RX_USER_WIDTH{1'b0}}),

    .m_axis_if_rx_tdata(), .m_axis_if_rx_tkeep(), .m_axis_if_rx_tvalid(),
    .m_axis_if_rx_tready(1'b1), .m_axis_if_rx_tlast(),
    .m_axis_if_rx_tid(), .m_axis_if_rx_tdest(), .m_axis_if_rx_tuser()
);

// ---------------------------------------------------------------- fake DMA
// Identical in spirit to tb_proposal_path's: the payload is a function of the
// descriptor's dma_addr, so a frame carrying entry k proves the engine was
// pointed at HOST_BASE + k*HOST_STRIDE rather than merely that some bytes made
// it through.
function [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] host_word(input integer entry, input integer beat);
    integer lane;
    reg [7:0] e8, b8, l8;
begin
    host_word = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
    e8 = 8'hA0 + entry[7:0];
    b8 = beat[7:0];
    for (lane = 0; lane < (RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH)/32; lane = lane + 1) begin
        l8 = lane[7:0];
        host_word[lane*32 +: 32] = {8'h5A, l8, b8, e8};
    end
end
endfunction

integer descs_seen  = 0;
integer dma_latency = 6;

integer cap_entry, cap_beat, cap_row;
reg [RAM_SEG_ADDR_WIDTH-1:0] cap_row_v;
reg [DMA_ADDR_WIDTH-1:0] cap_dma_addr;
reg [RAM_ADDR_WIDTH-1:0] cap_ram_addr;
reg [DMA_LEN_WIDTH-1:0]  cap_len;
reg [DMA_TAG_WIDTH-1:0]  cap_tag;

initial begin : fake_dma_engine
    forever begin
        @(negedge clk);
        if (!rst && rd_desc_valid && rd_desc_ready) begin
            cap_dma_addr = rd_desc_dma_addr;
            cap_ram_addr = rd_desc_ram_addr;
            cap_len      = rd_desc_len;
            cap_tag      = rd_desc_tag;
            cap_entry    = (cap_dma_addr - HOST_BASE) / HOST_STRIDE;
            descs_seen   = descs_seen + 1;

            check(cap_len == SLOT_BYTES[DMA_LEN_WIDTH-1:0],
                  $sformatf("descriptor len %0d, expected %0d", cap_len, SLOT_BYTES));
            check(rd_desc_ram_sel == 4'd0, "proposal descriptors must select RAM_SEL_PROP");
            check(cap_dma_addr == HOST_BASE + cap_entry*HOST_STRIDE,
                  "descriptor dma_addr is not base + k*stride");

            cap_row = cap_ram_addr / BEAT_BYTES;
            for (cap_beat = 0; cap_beat < SLOT_BEATS; cap_beat = cap_beat + 1) begin
                @(negedge clk);
                cap_row_v = (cap_row + cap_beat);
                wr_addr  = {RAM_SEG_COUNT{cap_row_v}};
                wr_data  = host_word(cap_entry, cap_beat);
                wr_be    = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};
                wr_valid = {RAM_SEG_COUNT{1'b1}};
            end
            @(negedge clk); wr_valid = {RAM_SEG_COUNT{1'b0}};

            repeat (dma_latency) @(posedge clk);
            @(negedge clk);
            rd_status_tag   = cap_tag;
            rd_status_error = 4'd0;
            rd_status_valid = 1'b1;
            @(negedge clk);
            rd_status_valid = 1'b0;
        end
    end
end

// Slots become transmittable in commit order; tx_engine drains them in order.
integer exp_q [0:255];
integer exp_head = 0, exp_tail = 0;
always @(posedge clk) if (!rst && dut.proposal_tail_slot_commit && dut.proposal_tail_slot_valid) begin
    exp_q[exp_tail % 256] = cap_entry;
    exp_tail = exp_tail + 1;
end

// ---------------------------------------------------------------- host frames
// Three beats, the last one partial, so the mux is also carrying a tkeep that
// is not all ones. Content is a function of the frame index, checked beat for
// beat on the far side.
localparam integer HOST_FRAME_BEATS = 3;
localparam [AXIS_KEEP_WIDTH-1:0] HOST_LAST_KEEP = {{(AXIS_KEEP_WIDTH-16){1'b0}}, {16{1'b1}}};

function [AXIS_DATA_WIDTH-1:0] host_frame_word(input integer f, input integer beat);
    integer lane;
begin
    host_frame_word = {AXIS_DATA_WIDTH{1'b0}};
    for (lane = 0; lane < AXIS_DATA_WIDTH/32; lane = lane + 1)
        host_frame_word[lane*32 +: 32] = {8'hC3, lane[7:0], beat[7:0], f[7:0]};
end
endfunction

function [TX_TAG_WIDTH-1:0] host_tag(input integer f);
    host_tag = 16'h0100 + f[15:0];      // bit 15 clear: this is not an SSR frame
endfunction

integer host_frames_sent = 0;
integer host_exp_q [0:255];
integer host_exp_head = 0, host_exp_tail = 0;

task send_host_frame(input integer f);
    integer b;
begin
    host_exp_q[host_exp_tail % 256] = f;
    host_exp_tail = host_exp_tail + 1;
    for (b = 0; b < HOST_FRAME_BEATS; b = b + 1) begin
        @(negedge clk);
        host_tx_tdata  = host_frame_word(f, b);
        host_tx_tkeep  = (b == HOST_FRAME_BEATS-1) ? HOST_LAST_KEEP : {AXIS_KEEP_WIDTH{1'b1}};
        host_tx_tlast  = (b == HOST_FRAME_BEATS-1);
        host_tx_tuser  = {host_tag(f), 1'b0};
        host_tx_tvalid = 1'b1;
        // TVALID must not drop before the handshake, so hold until ready.
        @(posedge clk);
        while (!host_tx_tready) @(posedge clk);
    end
    @(negedge clk);
    host_tx_tvalid = 1'b0;
    host_tx_tlast  = 1'b0;
    host_frames_sent = host_frames_sent + 1;
end
endtask

// ---------------------------------------------------------------- port model
// The port returns exactly one completion per frame, carrying the tag the
// sender put in tuser[16:1] and the PTP time at which the frame finished. That
// is all the real hardware tells us apart, and all ssr_tx_mux has to work with.
localparam integer CPL_DEPTH = 16;
reg [TX_TAG_WIDTH-1:0] cpl_q_tag [0:CPL_DEPTH-1];
reg [PTP_TS_WIDTH-1:0] cpl_q_ts  [0:CPL_DEPTH-1];
integer cpl_head = 0, cpl_tail = 0;

reg [PTP_TS_WIDTH-1:0] last_ssr_cpl_ts_model = {PTP_TS_WIDTH{1'b0}};
integer ssr_cpl_model_count = 0;
integer host_cpl_model_count = 0;

always @(posedge clk) if (!rst && port_tx_tvalid && port_tx_tready && port_tx_tlast) begin
    cpl_q_tag[cpl_tail % CPL_DEPTH] = port_tx_tuser[TX_TAG_WIDTH:1];
    cpl_q_ts [cpl_tail % CPL_DEPTH] = ptp_ts_rel;
    cpl_tail = cpl_tail + 1;
end

initial begin : port_cpl_driver
    forever begin
        @(negedge clk);
        if (!rst && cpl_head != cpl_tail) begin
            repeat (4) @(negedge clk);
            port_cpl_tag   = cpl_q_tag[cpl_head % CPL_DEPTH];
            port_cpl_ts    = cpl_q_ts [cpl_head % CPL_DEPTH];
            port_cpl_valid = 1'b1;
            if (port_cpl_tag[SSR_TAG_BIT]) begin
                last_ssr_cpl_ts_model = port_cpl_ts;
                ssr_cpl_model_count   = ssr_cpl_model_count + 1;
            end else begin
                host_cpl_model_count  = host_cpl_model_count + 1;
            end
            @(posedge clk);
            while (!port_cpl_ready) @(posedge clk);
            @(negedge clk);
            port_cpl_valid = 1'b0;
            cpl_head = cpl_head + 1;
        end
    end
end

// Completions that survive the filter. Every one of them must belong to a host
// frame; an SSR tag reaching here is the bug this whole mux exists to prevent.
integer if_cpl_seen = 0;
reg [TX_TAG_WIDTH-1:0] last_if_cpl_tag = {TX_TAG_WIDTH{1'b0}};
always @(posedge clk) if (!rst && if_cpl_valid && if_cpl_ready) begin
    if_cpl_seen = if_cpl_seen + 1;
    last_if_cpl_tag = if_cpl_tag;
    check(if_cpl_tag[SSR_TAG_BIT] === 1'b0,
          $sformatf("completion for tag %04h reached the interface; SSR completions must be consumed",
                    if_cpl_tag));
end

// ---------------------------------------------------------------- frame check
reg [AXIS_DATA_WIDTH-1:0] seen = {AXIS_DATA_WIDTH{1'b0}};
integer ssr_frames = 0, ssr_payload_frames = 0, ssr_zero_frames = 0, ssr_payload_beats = 0;
integer host_frames_out = 0;
integer beat_in_frame = 0;
integer cur_entry = -1, cur_host = -1;
integer payload_beat;
reg [15:0] frame_len_reg;
reg        frame_is_ssr = 1'b0;

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

// The source of a frame is decided once, on its first beat, from the tag. If
// the mux ever switched mid-frame the beats would stop matching whichever model
// this picked, which is exactly the failure the old arbiter had.
always @(posedge clk) begin
    if (!rst && port_tx_tvalid && port_tx_tready) begin
        if (beat_in_frame == 0) begin
            frame_is_ssr = (port_tx_tuser[TX_TAG_WIDTH:1] == SSR_TX_CPL_TAG);
            seen = port_tx_tdata;

            if (frame_is_ssr) begin
                ssr_frames    = ssr_frames + 1;
                frame_len_reg = rd16(SSR_OFF_LENGTH);

                check(port_tx_tkeep == {AXIS_KEEP_WIDTH{1'b1}}, "an SSR header beat is full");
                check(port_tx_tuser[0] === 1'b0, "SSR frames must not be marked bad");
                check(rd16(SSR_OFF_ETHERTYPE) == SSR_ETHERTYPE, "ethertype");
                check(seen[SSR_OFF_NODE_ID*8 +: 8] == NODE_ID[7:0], "node_id");
                check(rd64(SSR_OFF_ROUND_ID) == dut.core_tx_round_id, "round_id must match the core");
                check(rd32(SSR_OFF_RUN_ID) == dut.core_tx_run_id, "run_id must match the core");
                check(seen[SSR_OFF_ROW*8 +: 8] == dut.core_tx_row, "row must match the core");
                check(seen[SSR_OFF_RESERVED*8 +: (SSR_OFF_PAYLOAD-SSR_OFF_RESERVED)*8] == 0,
                      "header padding must be zero");

                if (frame_len_reg == 16'd0) begin
                    ssr_zero_frames = ssr_zero_frames + 1;
                    check(port_tx_tlast === 1'b1, "a length-0 frame must end on the header beat");
                    cur_entry = -1;
                end else begin
                    ssr_payload_frames = ssr_payload_frames + 1;
                    check(frame_len_reg == SLOT_BYTES[15:0],
                          $sformatf("length %0d, expected %0d", frame_len_reg, SLOT_BYTES));
                    check(port_tx_tlast === 1'b0, "a frame with a payload cannot end on the header");
                    if (exp_head == exp_tail) begin
                        check(1'b0, "an SSR frame carried a payload but no slot was committed");
                        cur_entry = -1;
                    end else begin
                        cur_entry = exp_q[exp_head % 256];
                        exp_head  = exp_head + 1;
                    end
                end
            end else begin
                host_frames_out = host_frames_out + 1;
                if (host_exp_head == host_exp_tail) begin
                    check(1'b0, "a host frame left the port that the bench never sent");
                    cur_host = -1;
                end else begin
                    cur_host = host_exp_q[host_exp_head % 256];
                    host_exp_head = host_exp_head + 1;
                    check(port_tx_tuser[TX_TAG_WIDTH:1] == host_tag(cur_host),
                          "host frame tag was not preserved through the mux");
                    check(port_tx_tdata === host_frame_word(cur_host, 0),
                          "host frame beat 0 corrupted");
                end
            end
            beat_in_frame = port_tx_tlast ? 0 : 1;
        end else begin
            if (frame_is_ssr) begin
                payload_beat      = beat_in_frame - 1;
                ssr_payload_beats = ssr_payload_beats + 1;
                check(port_tx_tkeep == {AXIS_KEEP_WIDTH{1'b1}}, "an SSR payload beat is full");
                if (cur_entry >= 0)
                    check(port_tx_tdata === host_word(cur_entry, payload_beat),
                          $sformatf("SSR frame %0d payload beat %0d does not match entry a%0h",
                                    ssr_frames, payload_beat, 8'hA0 + cur_entry));
                if (port_tx_tlast)
                    check(payload_beat == SLOT_BEATS-1,
                          $sformatf("SSR frame ended on payload beat %0d, expected %0d",
                                    payload_beat, SLOT_BEATS-1));
            end else begin
                if (cur_host >= 0)
                    check(port_tx_tdata === host_frame_word(cur_host, beat_in_frame),
                          $sformatf("host frame %0d beat %0d corrupted", cur_host, beat_in_frame));
                if (port_tx_tlast) begin
                    check(beat_in_frame == HOST_FRAME_BEATS-1,
                          "host frame ended on the wrong beat");
                    check(port_tx_tkeep == HOST_LAST_KEEP, "host frame tkeep was not preserved");
                end
            end
            beat_in_frame = port_tx_tlast ? 0 : beat_in_frame + 1;
        end
    end
end

// ---------------------------------------------------------------- tests
integer n;
reg [31:0] rd, rd0, rd1, rd2;
reg [PTP_TS_WIDTH-1:0] csr_ts, model_ts;
integer frames_before, cpl_before, if_cpl_before, mux_dma_before;

task arm_batch(input integer count);
begin
    csr_write(PROP_REG_DMA_ADDR_LO,   HOST_BASE[31:0]);
    csr_write(PROP_REG_DMA_ADDR_HI,   HOST_BASE[63:32]);
    csr_write(PROP_REG_DMA_STRIDE_LO, HOST_STRIDE[31:0]);
    csr_write(PROP_REG_DMA_STRIDE_HI, HOST_STRIDE[63:32]);
    csr_write(PROP_REG_DMA_COUNT,     count[31:0]);
    csr_write(PROP_REG_DMA_CONTROL,   32'h0000_0001);
end
endtask

initial begin
    $dumpfile("build/tb_ssr_dataplane.vcd");
    $dumpvars(0, tb_ssr_dataplane);

    $display("=========================================================");
    $display(" tb_ssr_dataplane  node=%0d/%0d slot=%0dB ring=%0d round=%0dns",
             NODE_ID, NODE_COUNT, SLOT_BYTES, SLOT_COUNT, ROUND_LENGTH_NS);
    $display("=========================================================");

    rst = 1'b1; time_advancing = 1'b0;
    repeat (10) @(posedge clk);
    time_advancing = 1'b1;
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // ---------------- Test 0: the wrapper's own register block -----------
    $display("[%0t] Test 0: CSR block decode", $realtime);
    csr_read(COMMON_REG_TYPE, rd);
    check(rd == 32'h53535201, $sformatf("common TYPE %08h, expected 53535201", rd));
    csr_read(COMMON_REG_VERSION, rd);
    check(rd == 32'h00000100, $sformatf("common VERSION %08h, expected 00000100", rd));

    csr_write(COMMON_REG_SCRATCH, 32'hA5A5_1234);
    csr_read(COMMON_REG_SCRATCH, rd);
    check(rd == 32'hA5A5_1234, "SCRATCH must read back what was written");

    // The proposal block sits at 0x001000 and the consensus block at 0x003000.
    // Reading each one's identity is what proves addr[23:12] is decoded, and
    // that the two blocks are not both answering.
    csr_read(PROP_REG_MAGIC, rd);
    check(rd == 32'h70726F71, $sformatf("proposal MAGIC %08h, expected 70726F71", rd));
    csr_read(PROP_REG_SLOT_BYTES, rd);
    check(rd == SLOT_BYTES, $sformatf("SLOT_BYTES reads %0d, expected %0d", rd, SLOT_BYTES));

    // ---------------- Test 1: bring the core up through the CSR ----------
    $display("[%0t] Test 1: activate the core", $realtime);
    csr_write(COMMON_REG_REPLICA_ID,  NODE_ID);
    csr_write(COMMON_REG_REPLICA_NUM, NODE_COUNT);
    csr_write(COMMON_REG_ROUND_LEN,   ROUND_LENGTH_NS);
    csr_read(COMMON_REG_STATUS, rd);
    check(rd[0] == 1'b1, "configuration should read back valid");

    csr_write(CORE_REG_CFG_RUN_ID,  32'h0000_0077);
    csr_write(CORE_REG_CFG_MEMBER,  32'h0000_0001);   // membership = {node 0}
    csr_write(CORE_REG_CFG_EFF_LOW, 32'h0000_0100);
    csr_write(CORE_REG_CONTROL,     32'h0000_0003);   // enable | activate

    wait (dut.consensus_core_inst.state_reg == 2'd2);
    repeat (3*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    csr_read(CORE_REG_STATUS, rd);
    check(rd[0] == 1'b0, "the core must not be halted after activation");

    // ---------------- Test 2: an empty queue still transmits -------------
    $display("[%0t] Test 2: empty queue still puts a frame on the wire", $realtime);
    frames_before = ssr_frames;
    repeat (2*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
    check(ssr_frames > frames_before, "no SSR frame reached the port with an empty queue");
    check(ssr_zero_frames > 0, "an empty-queue frame should be header-only");

    csr_read(COMMON_REG_TX_FRAME, rd);
    check(rd == ssr_frames, $sformatf("TX_FRAME_COUNT reads %0d, the bench saw %0d", rd, ssr_frames));
    csr_read(COMMON_REG_TX_EMPTY, rd);
    check(rd == ssr_zero_frames,
          $sformatf("TX_EMPTY_COUNT reads %0d, the bench saw %0d header-only frames",
                    rd, ssr_zero_frames));

    // ---------------- Test 3: a proposal reaches the port ----------------
    // The per-beat check in the monitor has been running all along; this only
    // confirms enough payload frames went out for it to mean something.
    $display("[%0t] Test 3: an armed proposal reaches the port", $realtime);
    arm_batch(4);
    repeat (8*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);

    check(descs_seen == 4, $sformatf("expected 4 descriptors, saw %0d", descs_seen));
    csr_read(PROP_REG_DMA_STATUS, rd);
    check(rd[1] == 1'b1 && rd[2] == 1'b0, "the batch should complete without error");
    check(ssr_payload_frames >= 4,
          $sformatf("only %0d frames carried a payload, expected at least 4", ssr_payload_frames));
    check(ssr_payload_beats == ssr_payload_frames*SLOT_BEATS,
          $sformatf("%0d payload beats for %0d frames, expected %0d",
                    ssr_payload_beats, ssr_payload_frames, ssr_payload_frames*SLOT_BEATS));

    csr_read(COMMON_REG_MUX_SSR, rd);
    check(rd == ssr_frames,
          $sformatf("TX_MUX_SSR_FRAMES reads %0d, the bench saw %0d", rd, ssr_frames));

    // ---------------- Test 4: SSR completions are consumed ---------------
    // The wrapper must eat them: the interface would otherwise retire a
    // descriptor that the host never posted.
    $display("[%0t] Test 4: SSR completions are consumed, not forwarded", $realtime);
    check(ssr_cpl_model_count > 0, "the port model never returned an SSR completion");
    check(if_cpl_seen == 0,
          $sformatf("%0d completions reached the interface before any host frame was sent",
                    if_cpl_seen));

    csr_read(COMMON_REG_CPL_COUNT, rd);
    check(rd == ssr_cpl_model_count,
          $sformatf("TX_CPL_COUNT reads %0d, the port returned %0d SSR completions",
                    rd, ssr_cpl_model_count));

    // ---------------- Test 5: the transmit timestamp lands in the CSR ----
    // Sample right after a completion so the three-word read cannot be torn by
    // the next one - there is a whole round of quiet behind it.
    $display("[%0t] Test 5: the SSR transmit timestamp reaches the CSR", $realtime);
    cpl_before = ssr_cpl_model_count;
    wait (ssr_cpl_model_count > cpl_before);
    model_ts = last_ssr_cpl_ts_model;
    repeat (4) @(posedge clk);
    csr_read(COMMON_REG_CPL_TS_0, rd0);
    csr_read(COMMON_REG_CPL_TS_1, rd1);
    csr_read(COMMON_REG_CPL_TS_2, rd2);
    csr_ts = {rd2, rd1, rd0};
    check(csr_ts == model_ts,
          $sformatf("TX_CPL_TS reads %024h, the port reported %024h", csr_ts, model_ts));
    check(model_ts != {PTP_TS_WIDTH{1'b0}}, "the captured timestamp should not be zero");

    csr_read(COMMON_REG_CPL_OVERRUN, rd);
    $display("        TX_CPL_OVERRUN = %0d (expected: nothing acknowledges yet)", rd);

    // ---------------- Test 6: host frames still pass, cpl still forwarded -
    $display("[%0t] Test 6: a host frame crosses the mux untouched", $realtime);
    if_cpl_before  = if_cpl_seen;
    csr_read(COMMON_REG_MUX_DMA, mux_dma_before);
    check(mux_dma_before == 0, "no host frame should have crossed the mux yet");

    for (n = 0; n < 4; n = n + 1) begin
        send_host_frame(n);
        repeat (20) @(posedge clk);
    end
    repeat (2*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);

    check(host_frames_out == 4,
          $sformatf("%0d host frames reached the port, expected 4", host_frames_out));
    csr_read(COMMON_REG_MUX_DMA, rd);
    check(rd == 4, $sformatf("TX_MUX_DMA_FRAMES reads %0d, expected 4", rd));
    check(if_cpl_seen - if_cpl_before == 4,
          $sformatf("%0d host completions were forwarded, expected 4",
                    if_cpl_seen - if_cpl_before));
    check(last_if_cpl_tag == host_tag(3),
          $sformatf("last forwarded completion carried tag %04h, expected %04h",
                    last_if_cpl_tag, host_tag(3)));

    // ---------------- Test 7: contention does not interleave frames ------
    // Host traffic offered continuously, straight through the transmit window.
    // The monitor decides each frame's source on its first beat and then checks
    // every following beat against that source's model, so any mid-frame switch
    // shows up as a corrupted beat rather than as a silent merge.
    $display("[%0t] Test 7: host and SSR frames contend for the port", $realtime);
    arm_batch(4);
    fork
        begin : host_pressure
            for (n = 4; n < 24; n = n + 1) send_host_frame(n);
        end
        begin : run_rounds
            repeat (8*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);
        end
    join
    repeat (4*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk);

    check(host_frames_out == 24,
          $sformatf("%0d host frames reached the port, expected 24", host_frames_out));
    check(host_exp_head == host_exp_tail,
          $sformatf("%0d host frames were sent but never left the port",
                    host_exp_tail - host_exp_head));
    csr_read(COMMON_REG_MUX_DMA, rd);
    check(rd == 24, $sformatf("TX_MUX_DMA_FRAMES reads %0d, expected 24", rd));

    csr_read(CORE_REG_STATUS, rd);
    check(rd[0] == 1'b0, "the core must still be running");
    csr_read(COMMON_REG_TX_MISSED, rd);
    check(rd == 32'd0, $sformatf("tx_engine missed %0d rounds; the path stalled", rd));
    csr_read(COMMON_REG_TX_LEN_MISMATCH, rd);
    check(rd == 32'd0, "the buffer's tx_len and tx_last disagree");
    csr_read(COMMON_REG_TX_OVERRUN, rd);
    $display("        TX_OVERRUN_COUNT = %0d (host contention may push a frame past its sub-slot)", rd);

    csr_read(COMMON_REG_CPL_COUNT, rd);
    check(rd == ssr_cpl_model_count,
          $sformatf("TX_CPL_COUNT reads %0d, the port returned %0d SSR completions",
                    rd, ssr_cpl_model_count));
    check(if_cpl_seen == host_cpl_model_count,
          $sformatf("%0d host completions forwarded, the port returned %0d",
                    if_cpl_seen, host_cpl_model_count));

    $display("--------------------------------------------------");
    $display("ssr frames=%0d (payload=%0d, %0d beats, header-only=%0d)  descriptors=%0d",
             ssr_frames, ssr_payload_frames, ssr_payload_beats, ssr_zero_frames, descs_seen);
    $display("host frames=%0d  ssr cpl=%0d (consumed)  host cpl=%0d (forwarded %0d)",
             host_frames_out, ssr_cpl_model_count, host_cpl_model_count, if_cpl_seen);
    $display("checks : %0d", checks);
    $display("errors : %0d", errors);
    $display("--------------------------------------------------");
    if (errors == 0) $display("[%0t] ALL TESTS PASSED", $realtime);
    else             $display("[%0t] %0d FAILURES", $realtime, errors);
    $finish;
end

initial begin
    #4000000;
    $display("ERROR: timeout");
    $display("errors : %0d", errors + 1);
    $finish;
end

endmodule

`default_nettype wire
