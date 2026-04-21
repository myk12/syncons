`timescale 1ns / 1ps

module consensus_node #(
    // node parameters
    parameter integer   P_NODE_ID       = 0,
    parameter integer   P_NODE_COUNT    = 3,    // we support up to 5 nodes

    // protocol parameters
    parameter integer   P_SLOT_DURATION_NS   = 10000, // 10 microseconds
    parameter integer   P_GUARD_BAND_NS      = 100,   // 100 nanoseconds
    parameter integer   P_COMMIT_TIME_NS     = 1000,  // 1 microsecond

    // AXI & Ethernet parameters
    parameter integer   P_DATA_WIDTH    = 512,
    parameter integer   P_ETHERNET_TYPE = 16'h88B5,
    parameter [47:0]    P_NODE_MAC_ADDR = 48'h00_0a_35_06_50_94,
    parameter integer   P_LOG_ITEM_LEN  = 40      // 40 bytes default
) (
    // clock and reset
    input wire                              clk,
    input wire                              rst_n,

    // control and time source
    input wire                              i_enable,           // enable the consensus module
    input wire [63:0]                       i_ptp_time_ns,      // PTP time in nanoseconds

    // network interface
    // TX AXI Stream Output
    output wire [P_DATA_WIDTH-1:0]          m_axis_tdata,
    output wire [P_DATA_WIDTH/8-1:0]        m_axis_tkeep,
    output wire                             m_axis_tvalid,
    output wire                             m_axis_tlast,
    output wire                             m_axis_tuser,
    input wire                              m_axis_tready,

    // RX AXI Stream Input
    input wire [P_DATA_WIDTH-1:0]           s_axis_tdata,
    input wire [P_DATA_WIDTH/8-1:0]         s_axis_tkeep,
    input wire                              s_axis_tvalid,
    input wire                              s_axis_tlast,
    input wire                              s_axis_tuser,
    output wire                             s_axis_tready,

    // host interface
    output wire                                         o_system_halt,        // high when system halts
    output wire [3:0]                                   o_debug_state,

    output wire [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]     o_host_commit_data,
    output wire [(P_LOG_ITEM_LEN*8*P_NODE_COUNT)/8-1:0] o_host_commit_keep,
    output wire [P_NODE_COUNT-1:0]                      o_host_commit_valid,
    input wire                                          i_host_commit_ready,
    output wire                                         o_host_commit_last
);

//------------------------------------------------
//   1. Interface Interconnections
//------------------------------------------------

// scheduler -> other modules
wire [63:0]     w_current_slot_id;
wire            w_new_slot_pulse;
wire            w_commit_start_pulse;
wire            w_slot_end_pulse;
wire            w_tx_allowed;
wire            w_rx_enabled;

// RX -> Core
wire            w_rx_valid;
wire [7:0]      w_rx_node_id;
wire [7:0]      w_rx_knowledge_vec;
wire [319:0]    w_rx_payload;

// Core -> TX
wire [P_NODE_COUNT-1:0]        w_tx_knowledge_vec;
wire [P_LOG_ITEM_LEN*8-1:0]    w_tx_propose;

// Core outputs
wire [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]    w_commit_log;
wire [P_NODE_COUNT-1:0]                     w_commit_valid;

// User -> TX
wire [P_NODE_COUNT-1:0]        i_tx_payload_vec; // user provided payload vector

//------------------------------------------------
//   2. Module Instantiations
//------------------------------------------------

// The conductor: Time Slot Scheduler
consensus_scheduler #(
    .P_NODE_ID(P_NODE_ID),
    .P_SYS_CLOCK_FREQ_HZ(250_000_000), // 250 MHz
    .P_SLOT_DURATION_NS(P_SLOT_DURATION_NS),
    .P_GUARD_NS(P_GUARD_BAND_NS),
    .P_COMMIT_DURATION_NS(P_COMMIT_TIME_NS)
) consensus_scheduler_inst (
    .clk(clk),
    .rst_n(rst_n),

    .i_enable(i_enable),
    .i_ptp_time_ns(i_ptp_time_ns),

    .o_current_slot_id(w_current_slot_id),
    .o_new_slot_pulse(w_new_slot_pulse),
    .o_commit_start_pulse(w_commit_start_pulse),
    .o_slot_end_pulse(w_slot_end_pulse),

    .o_tx_allowed(w_tx_allowed),
    .o_rx_enabled(w_rx_enabled)
);

// The Brain: Consensus Core
consensus_core #(
    .P_NODE_ID(P_NODE_ID),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_LOG_ITEM_LEN(P_LOG_ITEM_LEN),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_KEEP_WIDTH(P_DATA_WIDTH/8)
) consensus_core_inst (
    .clk(clk),
    .rst_n(rst_n),
    .i_current_slot_id(w_current_slot_id),
    .i_new_slot_pulse(w_new_slot_pulse),
    .i_commit_start_pulse(w_commit_start_pulse),
    .i_slot_end_pulse(w_slot_end_pulse),

    .i_rx_valid(w_rx_valid),
    .i_rx_node_id(w_rx_node_id),
    .i_rx_knowledge_vec(w_rx_knowledge_vec),
    .i_rx_propose(w_rx_payload[P_LOG_ITEM_LEN*8-1:0]),

    .o_system_halt(o_system_halt),

    .o_tx_knowledge_vec(w_tx_knowledge_vec),
    .o_tx_propose(w_tx_propose),

    .o_commit_log(w_commit_log),
    .o_commit_valid(w_commit_valid)
);

// The Gun: Packet Generator
consensus_tx #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_NODE_ID(P_NODE_ID),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_KEEP_WIDTH(P_DATA_WIDTH/8),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE),
    .P_LOG_ITEM_LEN(P_LOG_ITEM_LEN),
    .P_SRC_MAC(P_NODE_MAC_ADDR)
) consensus_tx_inst (
    .clk(clk),
    .rst_n(rst_n),

    .i_current_slot_id(w_current_slot_id),
    .i_new_slot_pulse(w_new_slot_pulse),
    .i_knowledge_vec(w_tx_knowledge_vec),
    .i_propose(w_tx_propose),
    .i_tx_allowed(w_tx_allowed),

    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
);

// The Gatekeeper: Packet Parser
consensus_rx #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE)
) consensus_rx_inst (
    .clk(clk),
    .rst_n(rst_n),

    .i_current_slot_id(w_current_slot_id),
    .i_rx_enabled(w_rx_enabled),

    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .s_axis_tready(s_axis_tready),

    .o_rx_valid(w_rx_valid),
    .o_rx_node_id(w_rx_node_id),
    .o_rx_knowledge_vec(w_rx_knowledge_vec),
    .o_rx_payload(w_rx_payload)
);

// Connect core outputs to host interface
assign o_host_commit_data = w_commit_log;
assign o_host_commit_valid = w_commit_valid;
assign o_host_commit_keep = {(P_LOG_ITEM_LEN*8*P_NODE_COUNT)/8{1'b1}};
assign o_host_commit_last = |w_commit_valid;

endmodule
