`timescale 1ns / 1ps

module consensus_rx #(
    parameter P_NODE_COUNT = 3,
    parameter P_DATA_WIDTH = 512, // Ethernet frame data width of FPGA
    parameter P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter P_ETHERNET_TYPE = 16'h88B5
) (
    // clock and reset
    input wire                          clk,
    input wire                          rst_n,

    // Control Signals from Scheduler
    input wire                          i_rx_enabled,
    input wire [63:0]                   i_current_slot_id,

    // AXI Stream Slave Input
    input wire [P_DATA_WIDTH-1:0]       s_axis_tdata,
    input wire [P_KEEP_WIDTH-1:0]       s_axis_tkeep,
    input wire                          s_axis_tvalid,
    input wire                          s_axis_tuser,
    input wire                          s_axis_tlast,
    output wire                         s_axis_tready,

    // Parsed Output to Consensus Module
    output reg                          o_rx_valid,     // high when a valid packet is parsed
    output reg [7:0]                    o_rx_node_id,   // node ID extracted from packet
    output reg [7:0]                    o_rx_knowledge_vec, // knowledge vector extracted from packet
    output reg [319:0]                  o_rx_payload    // payload extracted from packet
);

//------------------------------------------------
//         Interface Logic
//------------------------------------------------
// The consensus model must run at the line rate of incoming packets.
// Therefore, we assume that the AXI Stream input is always ready to accept data.
assign s_axis_tready = 1'b1; // Always ready to accept data

//------------------------------------------------
//         Packet Parsing Logic
//------------------------------------------------
// swap helper functions
function [15:0] swap16(input [15:0] in);
    swap16 = {in[7:0], in[15:8]};
endfunction

function [63:0] swap64(input [63:0] in);
    swap64 = {in[7:0], in[15:8], in[23:16], in[31:24],
               in[39:32], in[47:40], in[55:48], in[63:56]};
endfunction

// Feilds
wire [15:0] w_ethertype_net = s_axis_tdata[111:96];
wire [15:0] w_ethertype =   swap16(w_ethertype_net);

wire [63:0] w_slot_id_net = s_axis_tdata[175:112];
wire [63:0] w_rx_slot_id = swap64(w_slot_id_net);

wire [7:0] w_rx_node_id = s_axis_tdata[176+:8];

wire [7:0] w_rx_knowledge_vec = s_axis_tdata[184+:8];

wire [319:0] w_rx_payload_net = s_axis_tdata[192+:320];
wire [319:0] w_rx_payload = {
    swap64(w_rx_payload_net[63:0]),
    swap64(w_rx_payload_net[127:64]),
    swap64(w_rx_payload_net[191:128]),
    swap64(w_rx_payload_net[255:192]),
    swap64(w_rx_payload_net[319:256])
};

//------------------------------------------------
//         Flitering Logic
//------------------------------------------------
reg r_packet_valid;

always @(*) begin
    r_packet_valid = 0;

    // Basic AXI Stream validity
    if (s_axis_tvalid && s_axis_tlast) begin
        // Check Ethertype
        if (w_ethertype == P_ETHERNET_TYPE) begin
            // Check Slot ID matches current slot
            if (w_rx_slot_id == i_current_slot_id) begin
                // Check Node ID within range
                if (w_rx_node_id < P_NODE_COUNT) begin
                    r_packet_valid = 1'b1;
                end
            end
        end
    end
end

//------------------------------------------------
//         Output Logic
//------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        o_rx_valid <= 0;
        o_rx_node_id <= 0;
        o_rx_knowledge_vec <= 0;
        o_rx_payload <= 0;
    end else if (!i_rx_enabled) begin
        o_rx_valid <= 0;
        o_rx_node_id <= 0;
        o_rx_knowledge_vec <= 0;
        o_rx_payload <= 0;
    end else begin
        o_rx_valid <= r_packet_valid;
        if (r_packet_valid) begin
            o_rx_node_id <= w_rx_node_id;
            o_rx_knowledge_vec <= w_rx_knowledge_vec;
            o_rx_payload <= w_rx_payload;
        end else begin
            o_rx_node_id <= 0;
            o_rx_knowledge_vec <= 0;
            o_rx_payload <= 0;
        end
    end
end

endmodule
