`timescale 1ns / 1ps

/*
    Atomic Broadcast Switch Module
    This module simulates a shared medium for atomic broadcast among multiple nodes.
    It collects transmissions from all nodes and broadcasts them to all nodes.

    To keep the example simple, this medium uses a wire-or model where if multiple nodes
    transmit simultaneously. So it is user's responsibility to ensure that only one node
    transmits at a time (e.g. using a time-division scheme).
*/

module atomic_broadcast_switch #(
    parameter integer P_NODE_COUNT = 3,
    parameter integer P_DATA_WIDTH = 512
)(
    // TX Signals from Nodes
    input  wire [P_NODE_COUNT*P_DATA_WIDTH-1:0]         s_axis_tx_tdata,
    input  wire [P_NODE_COUNT*(P_DATA_WIDTH/8)-1:0]     s_axis_tx_tkeep,
    input  wire [P_NODE_COUNT-1:0]                      s_axis_tx_tvalid,
    input  wire [P_NODE_COUNT-1:0]                      s_axis_tx_tlast,
    input  wire [P_NODE_COUNT-1:0]                      s_axis_tx_tuser,
    output wire [P_NODE_COUNT-1:0]                      s_axis_tx_tready,   // Always ready

    // RX Signals to Nodes
    output reg  [P_NODE_COUNT*P_DATA_WIDTH-1:0]         m_axis_rx_tdata,
    output reg  [P_NODE_COUNT*(P_DATA_WIDTH/8)-1:0]     m_axis_rx_tkeep,
    output reg  [P_NODE_COUNT-1:0]                      m_axis_rx_tvalid,
    output reg  [P_NODE_COUNT-1:0]                      m_axis_rx_tuser,
    output reg  [P_NODE_COUNT-1:0]                      m_axis_rx_tlast,
    input  wire [P_NODE_COUNT-1:0]                      m_axis_rx_tready    // Always ready
);
    assign s_axis_tx_tready = {P_NODE_COUNT{1'b1}}; // Always ready to accept transmissions

    integer i;

    always @(*) begin
        // Default outputs
        m_axis_rx_tdata  = {P_NODE_COUNT*P_DATA_WIDTH{1'b0}};
        m_axis_rx_tkeep  = {P_NODE_COUNT*(P_DATA_WIDTH/8){1'b0}};
        m_axis_rx_tvalid = {P_NODE_COUNT{1'b0}};
        m_axis_rx_tlast  = {P_NODE_COUNT{1'b0}};

        // Broadcast logic
        for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
            if (s_axis_tx_tvalid[i]) begin
                // Broadcast to all nodes
                integer j;
                for (j = 0; j < P_NODE_COUNT; j = j + 1) begin
                    m_axis_rx_tdata[j*P_DATA_WIDTH +: P_DATA_WIDTH]  = s_axis_tx_tdata[i*P_DATA_WIDTH +: P_DATA_WIDTH];
                    m_axis_rx_tkeep[j*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)] = s_axis_tx_tkeep[i*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)];
                    m_axis_rx_tvalid[j] = 1'b1;
                    m_axis_rx_tlast[j]  = s_axis_tx_tlast[i];
                end
            end
        end
    end

endmodule
