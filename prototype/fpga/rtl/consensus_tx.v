`timescale 1ns / 1ps

module consensus_tx #(
    parameter integer P_DATA_WIDTH = 512,
    parameter integer P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter integer P_ID_WIDTH = 12,
    parameter integer P_DEST_WIDTH = 4,
    parameter integer P_NODE_ID = 0,
    parameter integer P_NODE_COUNT = 3,
    parameter integer P_LOG_ITEM_LEN = 32, // bytes
    parameter [47:0] P_SRC_MAC = 48'h02_00_00_00_00_00,
    parameter [15:0] P_ETHERNET_TYPE = 16'h88B5
) (
    // clock and reset
    input wire                              clk,
    input wire                              rst,

    // Control and Data
    input wire                              i_tx_allowed,
    input wire [63:0]                       i_current_slot_id,
    input wire [63:0]                       i_current_run_id,
    input wire [P_NODE_COUNT-1:0]           i_knowledge_vec,
    input wire [P_LOG_ITEM_LEN*8-1:0]       i_propose,
    output reg                              o_tx_start,

    // AXI Stream Master Output
    output reg [P_DATA_WIDTH-1:0]           m_axis_tdata,
    output reg [P_KEEP_WIDTH-1:0]           m_axis_tkeep,
    output reg                              m_axis_tvalid,
    output reg                              m_axis_tlast,
    output reg                              m_axis_tuser,
    output reg [P_ID_WIDTH-1:0]             m_axis_tid,
    output reg [P_DEST_WIDTH-1:0]           m_axis_tdest,
    input wire                              m_axis_tready
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
//           parameter Definitions
//------------------------------------------------
localparam S_IDLE           = 1'b0;
localparam S_BROADCAST      = 1'b1;
reg [1:0] state;
reg [7:0]   r_target_node_id;

reg last_tx_allowed;
wire tx_allowed_pulse = i_tx_allowed && !last_tx_allowed; // Detect rising edge of tx_allowed

// MAC address
reg [47:0]  v_dest_mac;

always @(*) begin
    // Default value
    v_dest_mac = 48'hFF_FF_FF_FF_FF_FF; // Broadcast MAC

    // Select destination MAC based on destination node ID
    case (r_target_node_id)
        0: v_dest_mac = 48'h00_0a_35_06_50_94;
        1: v_dest_mac = 48'h00_0a_35_06_09_24;
        2: v_dest_mac = 48'h00_0a_35_06_0b_84;
        3: v_dest_mac = 48'h00_0a_35_06_09_3c;
        4: v_dest_mac = 48'h00_0a_35_06_0b_72;
        default: v_dest_mac = 48'hFF_FF_FF_FF_FF_FF; // Broadcast MAC
    endcase
end

//------------------------------------------------
//         Packet Construction (Single Cycle)
//------------------------------------------------
// Construct packet flit
// Packet format:
// [ Ethernet Header ]
//   - Destination MAC (48 bits)
//   - Source MAC (48 bits)
//   - Ethertype (16 bits)
// [ Consensus Header ]
//  - Slot ID (64 bits)
//  - Node ID (8 bits)
//  - Knowledge Vector (8 bits)
//  - Payload (40 bytes)

reg [P_DATA_WIDTH-1:0]      v_packet_flit;
always @(*) begin
    v_packet_flit = {P_DATA_WIDTH{1'b0}};

    // ------- Ethernet Header -------
    v_packet_flit[0*8:0]       = v_dest_mac[47:40];
    v_packet_flit[1*8:8]       = v_dest_mac[39:32];
    v_packet_flit[2*8:16]      = v_dest_mac[31:24];
    v_packet_flit[3*8:24]      = v_dest_mac[23:16];
    v_packet_flit[4*8:32]      = v_dest_mac[15:8];
    v_packet_flit[5*8:40]      = v_dest_mac[7:0];

    v_packet_flit[6*8:48]      = P_SRC_MAC[47:40];
    v_packet_flit[7*8:56]      = P_SRC_MAC[39:32];
    v_packet_flit[8*8:64]      = P_SRC_MAC[31:24];
    v_packet_flit[9*8:72]      = P_SRC_MAC[23:16];
    v_packet_flit[10*8:80]     = P_SRC_MAC[15:8];
    v_packet_flit[11*8:88]     = P_SRC_MAC[7:0];

    v_packet_flit[12*8 +: 16] = to_big_endian_16(P_ETHERNET_TYPE);

    // ------- Consensus Header -------
    v_packet_flit[14*8 +: 64]  = to_big_endian_64(i_current_run_id);
    v_packet_flit[22*8 +: 8]   = i_knowledge_vec;
    v_packet_flit[23*8 +: 8]   = P_NODE_ID[7:0];
    v_packet_flit[24*8 +: 64]  = to_big_endian_64(i_current_slot_id);

    // ------- Payload -------
    v_packet_flit[32*8 +: P_LOG_ITEM_LEN*8] = 
    {
        to_big_endian_64(i_propose[63:0]),
        to_big_endian_64(i_propose[127:64]),
        to_big_endian_64(i_propose[191:128]),
        to_big_endian_64(i_propose[255:192])
    }; // not sure if this is right, but doing this to be consistent with rx side parsing
end

assign o_tx_start = (state == S_IDLE) && tx_allowed_pulse;

//------------------------------------------------
//         State Machine
//------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        state <= S_IDLE;
        m_axis_tdata <= {P_DATA_WIDTH{1'b0}};
        m_axis_tkeep <= {P_KEEP_WIDTH{1'b0}};
        m_axis_tvalid <= 1'b0;
        m_axis_tlast <= 1'b0;
        m_axis_tuser <= 1'b0;
        m_axis_tid <= 8'b0;
        m_axis_tdest <= 8'b0;
        r_target_node_id <= 8'b0;
        last_tx_allowed <= 1'b0;
    end else begin
        last_tx_allowed <= i_tx_allowed;

        case (state)
            S_IDLE: begin
                // clear outputs
                m_axis_tdata <= {P_DATA_WIDTH{1'b0}};
                m_axis_tkeep <= {P_KEEP_WIDTH{1'b0}};
                m_axis_tvalid <= 1'b0;
                m_axis_tlast <= 1'b0;
                m_axis_tuser <= 1'b0;
                m_axis_tid <= 8'b0; // Use target node ID as TID
                m_axis_tdest <= 8'b0; // Use target node ID as DEST
                
                r_target_node_id <= 0;

                if (tx_allowed_pulse) begin
                    // Start broadcasting to all nodes
                    state <= S_BROADCAST;
                end
            end

            S_BROADCAST: begin
                if (!i_tx_allowed) begin
                    state <= S_IDLE; // Abort if not allowed
                    m_axis_tdata <= {P_DATA_WIDTH{1'b0}};
                    m_axis_tkeep <= {P_KEEP_WIDTH{1'b0}};
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast <= 1'b0;
                    m_axis_tuser <= 1'b0;
                    m_axis_tid <= 8'b0;
                    m_axis_tdest <= 8'b0;
                end
                else begin
                    if (m_axis_tready) begin
                        // Check if this is the last node
                        // m_axis_tdata <= {P_DATA_WIDTH{1'b0}};
                        // m_axis_tkeep <= {P_KEEP_WIDTH{1'b0}};
                        // m_axis_tvalid <= 1'b0;
                        // m_axis_tlast <= 1'b0;
                        // m_axis_tuser <= 1'b0;
                        // m_axis_tid <= 8'b0;
                        // m_axis_tdest <= 8'b0;

                        if (r_target_node_id >= P_NODE_COUNT) begin
                            // Finished broadcasting
                            state <= S_IDLE;
                        end else begin
                            // broadcast to all nodes except self
                            if (r_target_node_id != P_NODE_ID && (i_knowledge_vec[r_target_node_id])) begin
                                m_axis_tdata <= v_packet_flit;
                                m_axis_tkeep <= {P_KEEP_WIDTH{1'b1}}; // All bytes valid
                                m_axis_tvalid <= 1'b1;
                                m_axis_tuser <= 1'b0;
                                m_axis_tlast <= 1'b1; // Last flit for this transmission
                                m_axis_tid <= P_NODE_ID;
                                m_axis_tdest <= r_target_node_id;
                            end
                            r_target_node_id <= r_target_node_id + 1;
                        end
                    end
                end
            end
            default: state <= S_IDLE;
        endcase
    end 
end

endmodule
