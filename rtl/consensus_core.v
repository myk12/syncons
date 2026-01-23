`timescale 1ns / 1ps
/*
 * Synchronous Consensus Core Module:
 * Here we assume there is a synchronous distributed system with fixed time slots.
 * Each node sends and receives packets in its designated time slots.
 * Based on the assumptions, we implement a simple consensus core that processes
 * incoming packets and outputs data to the application layer.
 *
*/

module consensus_core #(
    parameter P_NODE_COUNT = 3,
    parameter P_DATA_WIDTH = 512,
    parameter P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter P_NODE_ID = 0,
    parameter P_SRC_MAC = 48'h00_00_00_00_00_00,
    parameter P_DEST_MAC = 48'hFF_FF_FF_FF_FF_FF
) (
    // clock and reset
    input wire                          clk,
    input wire                          rst_n,

    // control interface (from scheduler )
    input wire [63:0]                   i_current_slot_id,
    input wire                          i_commit_start_pulse,

    // data interface
    input wire                          i_rx_valid,
    input wire [7:0]                    i_rx_node_id,
    input wire [319:0]                  i_rx_payload,

    // host interface
    output reg [P_DATA_WIDTH-1:0]       m_axis_tdata,
    output reg [P_KEEP_WIDTH-1:0]       m_axis_tkeep,
    output reg                          m_axis_tvalid,
    input wire                          m_axis_tready,
    output reg                          m_axis_tlast
);

//------------------------------------------------
//         Internal Storage (Buffer)
//------------------------------------------------
// save received packets for current slot
reg [319:0]    r_payload_buffer [0:P_NODE_COUNT-1];
reg [P_NODE_COUNT-1:0] r_valid_bitmap;

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
//         State Machine for Consensus Processing
//------------------------------------------------
localparam S_COLLECT = 1'b0;
localparam S_COMMIT = 1'b1;

reg state, next_state;
reg [7:0] r_commit_idx;
reg [63:0] r_frozen_slot_id;
reg [15:0] r_ethertype;

localparam [319:0] MAGIC_NOP_PAYLOAD = {320{1'b1}}; // NOP payload

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_COLLECT;
        next_state <= S_COLLECT;
        r_valid_bitmap <= {P_NODE_COUNT{1'b0}};
        r_commit_idx <= 8'b0;
        r_frozen_slot_id <= 64'b0;
        m_axis_tvalid <= 1'b0;
        m_axis_tlast <= 1'b0;
   end else begin
       state <= next_state;

        case (state)
            S_COLLECT: begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast <= 1'b0;

               // Collect incoming packets
                if (i_rx_valid) begin
                    r_payload_buffer[i_rx_node_id] <= i_rx_payload;
                    r_valid_bitmap[i_rx_node_id] <= 1'b1;
                end

                // Transition to COMMIT state
                if (i_commit_start_pulse) begin
                    r_frozen_slot_id <= i_current_slot_id;
                    r_commit_idx <= 8'b0;
                    next_state <= S_COMMIT;
                end
           end
           S_COMMIT: begin
               // Commit logic
                if (!m_axis_tvalid || (m_axis_tvalid && m_axis_tready)) begin
                    // Prepare next packet to send
                    if (r_commit_idx < P_NODE_COUNT) begin
                        if (r_valid_bitmap[r_commit_idx]) begin
                            // Send valid packet
                            m_axis_tdata <= {
                                r_payload_buffer[r_commit_idx],    // Payload
                                8'h01,                             // Type: 0x01 for data packet
                                P_NODE_ID[7:0],                   // Node ID
                                to_big_endian_64(r_frozen_slot_id), // Current Macro Slot ID
                                P_SRC_MAC,                         // Source MAC
                                P_DEST_MAC                         // Destination MAC
                            };
                        end else begin
                            // Send NOP packet
                            m_axis_tdata <= {
                                MAGIC_NOP_PAYLOAD,                 // Payload
                                8'h01,                             // Type: 0x01 for data packet
                                P_NODE_ID[7:0],                   // Node ID
                                to_big_endian_64(r_frozen_slot_id), // Current Macro Slot ID
                                P_SRC_MAC,                         // Source MAC
                                P_DEST_MAC                         // Destination MAC
                            };
                        end
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast <= 1'b1;

                        r_commit_idx <= r_commit_idx + 1;
                    end else begin
                        // All packets committed, go back to COLLECT state
                        next_state <= S_COLLECT;
                        r_valid_bitmap <= {P_NODE_COUNT{1'b0}}; // Clear buffer
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast <= 1'b0;
                    end
                end
           end
       endcase
   end
end

endmodule
