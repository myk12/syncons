`timescale 1ns / 1ps

module consensus_tx #(
    parameter integer P_DATA_WIDTH = 512,
    parameter integer P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter integer P_NODE_ID = 0,
    parameter integer P_NODE_COUNT = 3,
    parameter [47:0] P_DEST_MAC = 48'hFF_FF_FF_FF_FF_FF,
    parameter [47:0] P_SRC_MAC = 48'h02_00_00_00_00_00,
    parameter [15:0] P_ETHERNET_TYPE = 16'h88B5
) (
    // clock and reset
    input wire                          clk,
    input wire                          rst_n,

    // Control logic
    input wire                          i_tx_trigger,
    input wire [63:0]                   i_current_slot_id,

    // User data to send
    input wire [319:0]                  i_payload_vec,

    // AXI Stream Master Output
    output reg [P_DATA_WIDTH-1:0]       m_axis_tdata,
    output reg [P_KEEP_WIDTH-1:0]       m_axis_tkeep,
    output reg                          m_axis_tvalid,
    output reg                          m_axis_tlast,
    input wire                          m_axis_tready
);
//------------------------------------------------
//         Endianess Conversion
//------------------------------------------------
// helper function for byte swapping
function [15:0] to_big_endian_16(input [15:0] in);
    to_big_endian_16 = {in[7:0], in[15:8]};
endfunction

function [63:0] to_big_endian_64(input [63:0] in);
    to_big_endian_64 = {in[7:0], in[15:8], in[23:16], in[31:24],
                       in[39:32], in[47:40], in[55:48], in[63:56]};
endfunction

//------------------------------------------------
//         Packet Construction (Single Cycle)
//------------------------------------------------
wire [P_DATA_WIDTH-1:0] w_packet_data;
wire [47:0] w_dst_mac = P_DEST_MAC;

assign w_packet_data = {
    i_payload_vec,                // Payload (40 bytes)
    8'h01,                        // Type: 0x01 for data packet
    P_NODE_ID[7:0],              // Node ID
    to_big_endian_64(i_current_slot_id),    // Current Macro Slot ID
    to_big_endian_16(P_ETHERNET_TYPE),        // Ethertype
    P_SRC_MAC,                      // Source MAC
    P_DEST_MAC                      // Destination MAC
};

//------------------------------------------------
//         AXI Stream Packet Send Logic
//------------------------------------------------
// Packet format:
always @(posedge clk) begin
    if (!rst_n) begin
        m_axis_tdata <= 0;
        m_axis_tkeep <= 0;
        m_axis_tvalid <= 0;
        m_axis_tlast <= 0;
    end else begin
        if (m_axis_tvalid && m_axis_tready) begin
            // Packet sent
            m_axis_tvalid <= 0;
            m_axis_tdata <= 0;
            m_axis_tkeep <= 0;
            m_axis_tlast <= 0;
        end else if (i_tx_trigger && !m_axis_tvalid) begin
            // Trigger to send packet
            m_axis_tdata <= w_packet_data;
            m_axis_tkeep <= {P_KEEP_WIDTH{1'b1}}; // All bytes are valid
            m_axis_tvalid <= 1;
            m_axis_tlast <= 1;
        end
    end 
end

endmodule
