`timescale 1ns / 1ps

module consensus_nic #(
    parameter integer P_NODE_ID = 0,
    parameter integer P_NODE_COUNT = 3,
    parameter integer P_DATA_WIDTH = 512,

    // protocol parameters
    parameter integer P_SLOT_LEN_NS = 10000,
    parameter integer P_GUARD_BAND_NS = 100,
    parameter integer P_COMMIT_TIME_NS = 1000,
    parameter [15:0] P_ETHERNET_TYPE = 16'h88B5
) (
    // clock and reset
    input wire                              clk,
    input wire                              rst_n,

    // time source
    input wire [63:0]                       i_ptp_ns,

    // user data input
    input wire [319:0]                      i_tx_payload_vec,

    // network interface
    // TX AXI Stream Output
    output wire [P_DATA_WIDTH-1:0]          m_axis_tdata,
    output wire [P_DATA_WIDTH/8-1:0]        m_axis_tkeep,
    output wire                             m_axis_tvalid,
    output wire                             m_axis_tlast,
    input wire                              m_axis_tready,

    // RX AXI Stream Input
    input wire [P_DATA_WIDTH-1:0]           s_axis_tdata,
    input wire [P_DATA_WIDTH/8-1:0]         s_axis_tkeep,
    input wire                              s_axis_tvalid,
    input wire                              s_axis_tlast,
    output wire                             s_axis_tready,

    // host interface outputs can be added here
    output wire [P_DATA_WIDTH-1:0]          o_host_commit_data,
    output wire [P_DATA_WIDTH/8-1:0]        o_host_commit_keep,
    output wire                             o_host_commit_valid,
    output wire                             o_host_commit_last,
    input wire                              i_host_commit_ready
);

//------------------------------------------------
//   1. Interface Interconnections
//------------------------------------------------

// scheduler -> other modules
wire [63:0]     w_current_slot_id;
wire            w_tx_trigger;
wire            w_commit_start;

// RX -> parser -> consensus core
wire            w_rx_valid;
wire [7:0]      w_rx_node_id;
wire [319:0]    w_rx_payload;

//------------------------------------------------
//   2. Module Instantiations
//------------------------------------------------

// The conductor: Time Slot Scheduler
consensus_scheduler #(
    .P_NODE_ID(P_NODE_ID),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_SLOT_LEN_NS(P_SLOT_LEN_NS),
    .P_GUARD_BAND_NS(P_GUARD_BAND_NS),
    .P_COMMIT_TIME_NS(P_COMMIT_TIME_NS)
) consensus_scheduler_inst (
    .clk(clk),
    .rst_n(rst_n),
    .i_ptp_ns(i_ptp_ns),
    .o_current_slot_id(w_current_slot_id),
    .o_tx_trigger_pulse(w_tx_trigger),
    .o_commit_start_pulse(w_commit_start),
    .o_new_slot_pulse() // not used
);

// The Gun: Packet Generator
consensus_tx #(
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_KEEP_WIDTH(P_DATA_WIDTH/8),
    .P_NODE_ID(P_NODE_ID),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_DEST_MAC(48'hFF_FF_FF_FF_FF_FF),
    .P_SRC_MAC(48'h02_00_00_00_00_00),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE)
) consensus_tx_inst (
    .clk(clk),
    .rst_n(rst_n),
    .i_tx_trigger(w_tx_trigger),
    .i_current_slot_id(w_current_slot_id),
    .i_payload_vec(i_tx_payload_vec),   // from user
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tready(m_axis_tready) // always ready
);

// The Gatekeeper: Packet Parser
consensus_rx #(
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_KEEP_WIDTH(P_DATA_WIDTH/8),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE)
) consensus_rx_inst (
    .clk(clk),
    .rst_n(rst_n),
    .i_current_slot_id(w_current_slot_id),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tlast(s_axis_tlast),
    .o_rx_valid(w_rx_valid),
    .o_rx_node_id(w_rx_node_id),
    .o_rx_payload(w_rx_payload)
);

// The Brain: Consensus Core
consensus_core #(
    .P_NODE_ID(P_NODE_ID),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_KEEP_WIDTH(P_DATA_WIDTH/8)
) consensus_core_inst (
    .clk(clk),
    .rst_n(rst_n),
    .i_current_slot_id(w_current_slot_id),
    .i_commit_start_pulse(w_commit_start),
    .i_rx_valid(w_rx_valid),
    .i_rx_node_id(w_rx_node_id),
    .i_rx_payload(w_rx_payload),
    .m_axis_tdata(o_host_commit_data),
    .m_axis_tkeep(o_host_commit_keep),
    .m_axis_tvalid(o_host_commit_valid),
    .m_axis_tready(i_host_commit_ready),
    .m_axis_tlast(o_host_commit_last)
);

endmodule
