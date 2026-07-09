`timescale 1ns / 1ps

module consensus_rx #(
    parameter P_NODE_COUNT = 3,
    parameter P_NODE_ID = 0,
    parameter P_DATA_WIDTH = 512, // Ethernet frame data width of FPGA
    parameter P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter P_PORTS_PER_IF = 1,
    parameter P_ID_WIDTH = P_PORTS_PER_IF > 1 ? $clog2(P_PORTS_PER_IF) : 1,
    parameter P_DEST_WIDTH = 8,
    parameter P_USER_WIDTH = 1,
    parameter P_ETHERNET_TYPE = 16'h88B5,
    parameter integer   P_LOG_ITEM_LEN  = 32      // 40 bytes default, smaller to fit room for other fields in the test frame
) (
    // clock and reset
    input wire                          clk,
    input wire                          rst,

    // Control Signals from Scheduler inside consensus core
    input wire                          i_rx_enabled,
    input wire [63:0]                   i_current_run_id,
    input wire [63:0]                   i_current_round_id,

    // AXI Stream Slave Input
    input wire [P_DATA_WIDTH-1:0]       s_axis_tdata,
    input wire [P_KEEP_WIDTH-1:0]       s_axis_tkeep,
    input wire                          s_axis_tvalid,
    output wire                         s_axis_tready,
    input wire                          s_axis_tlast,
    input wire [P_ID_WIDTH-1:0]         s_axis_if_rx_tid,
    input wire [P_DEST_WIDTH-1:0]       s_axis_if_rx_tdest,
    input wire [P_USER_WIDTH-1:0]       s_axis_tuser,

    // Parsed Output to Consensus Module
    output reg                              o_rx_valid,     // high when a valid packet is parsed
    output reg [7:0]                        o_rx_node_id,   // node ID extracted from packet
    output reg [7:0]                        o_rx_sound_bitmap, // sound bitmap extracted from packet
    output reg [P_LOG_ITEM_LEN*8-1:0]       o_rx_payload,
    output reg [63:0]                       o_rx_run_id,
    output reg [63:0]                       o_rx_round_id
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

wire [63:0] w_run_id_net = s_axis_tdata[175:112];
wire [63:0] w_rx_run_id = swap64(w_run_id_net);

wire [7:0] w_rx_knowledge_vec = s_axis_tdata[176+:8];

wire [7:0] w_rx_node_id = s_axis_tdata[184+:8];

wire [63:0] w_round_id_net = s_axis_tdata[192+:64];
wire [63:0] w_rx_round_id = swap64(w_round_id_net);

wire [(P_LOG_ITEM_LEN*8)-1:0] w_rx_payload_net = s_axis_tdata[256+:(P_LOG_ITEM_LEN*8)];
wire [(P_LOG_ITEM_LEN*8)-1:0] w_rx_payload = {
    swap64(w_rx_payload_net[63:0]),
    swap64(w_rx_payload_net[127:64]),
    swap64(w_rx_payload_net[191:128]),
    swap64(w_rx_payload_net[255:192])
};

// wire [7:0] w_rx_node_id = s_axis_if_rx_tid; // may be used instead
wire [7:0] w_rx_dest_id = s_axis_if_rx_tdest;

//------------------------------------------------
//         Flitering Logic
//------------------------------------------------
reg r_packet_valid;

always @(*) begin // consensus core checks round and run ID
    r_packet_valid = 0;

    // Basic AXI Stream validity
    if (s_axis_tvalid && s_axis_tlast) begin
        // Check Ethertype
        if (w_ethertype == P_ETHERNET_TYPE) begin
            // Check Node ID within range
            if (w_rx_node_id < P_NODE_COUNT && w_rx_dest_id == P_NODE_ID && w_rx_run_id == i_current_run_id && w_rx_round_id == i_current_round_id) begin
                r_packet_valid = 1'b1;
            end
        end
    end
end

//------------------------------------------------
//         Output Logic
//------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        o_rx_valid <= 0;
        o_rx_node_id <= 0;
        o_rx_sound_bitmap <= 0;
        o_rx_payload <= 0;
        o_rx_run_id <= 0;
        o_rx_round_id <= 0;
    end else if (!i_rx_enabled) begin
        o_rx_valid <= 0;
        o_rx_node_id <= 0;
        o_rx_sound_bitmap <= 0;
        o_rx_payload <= 0;
        o_rx_run_id <= 0;
        o_rx_round_id <= 0;
    end else begin
        o_rx_valid <= r_packet_valid;
        if (r_packet_valid) begin
            o_rx_node_id <= w_rx_node_id;
            o_rx_sound_bitmap <= w_rx_knowledge_vec;
            o_rx_payload <= w_rx_payload;
            o_rx_run_id <= w_rx_run_id;
            o_rx_round_id <= w_rx_round_id;
        end else begin
            o_rx_node_id <= 0;
            o_rx_sound_bitmap <= 0;
            o_rx_payload <= 0;
            o_rx_run_id <= 0;
            o_rx_round_id <= 0;
        end
    end
end

endmodule
