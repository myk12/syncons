`timescale 1ns / 1ps

module consensus_scheduler #(
    parameter P_NODE_ID = 0,  
    parameter P_NODE_COUNT = 3,
    parameter P_SLOT_LEN_NS = 10000,  // 10us slot length
    parameter P_GUARD_BAND_NS = 100,
    parameter P_COMMIT_TIME_NS = 1000   // save some time for commit
)
(
    // clock and reset
    input  wire                         clk,
    input  wire                         rst_n,

    // time source
    input wire [63:0]                   i_ptp_ns,

    // status outputs
    output reg [63:0]                   o_current_slot_id,    // current slot id

    // control outputs
    output reg                          o_tx_trigger_pulse,  // trigger to send packet
    //output reg                          o_rx_window_valid,  // indicate receiving window is valid
    output reg                          o_commit_start_pulse,   // indicate commit start
    output reg                          o_new_slot_pulse  // indicate new slot start
);

//-----------------------------------------------
//  Calculations of key time points
//-----------------------------------------------
// when to trigger sending
localparam [31:0] TIME_TX_START = P_GUARD_BAND_NS;
localparam [31:0] TIME_COMMIT_START = P_SLOT_LEN_NS - P_COMMIT_TIME_NS;

//-----------------------------------------------
//  Phase Calculation
//-----------------------------------------------
wire [63:0] calc_slot_id = i_ptp_ns / P_SLOT_LEN_NS;
wire [31:0] calc_offset_ns = i_ptp_ns % P_SLOT_LEN_NS;

reg [31:0] r_last_offset_ns;
reg [63:0] r_last_slot_id;

always @(posedge clk) begin
    if (!rst_n) begin
        o_current_slot_id <= 64'b0;
        o_tx_trigger_pulse <= 1'b0;
        //o_rx_window_valid <= 1'b0;
        o_commit_start_pulse <= 1'b0;
        o_new_slot_pulse <= 1'b0;
        r_last_offset_ns <= 32'b0;
        r_last_slot_id <= 64'b0;
    end else begin
        r_last_slot_id <= calc_slot_id;
        r_last_offset_ns <= calc_offset_ns;
        o_current_slot_id <= calc_slot_id;

        // Singal-1: Send Trigger
        if (r_last_offset_ns < TIME_TX_START && calc_offset_ns >= TIME_TX_START) begin
            o_tx_trigger_pulse <= 1'b1;
        end else begin
            o_tx_trigger_pulse <= 1'b0;
        end

        // Signal-2: Commit Start
        if (r_last_offset_ns < TIME_COMMIT_START && calc_offset_ns >= TIME_COMMIT_START) begin
            o_commit_start_pulse <= 1'b1;
        end else begin
            o_commit_start_pulse <= 1'b0;
        end

        // Signal-3: New Slot
        if (r_last_slot_id != calc_slot_id) begin
            o_new_slot_pulse <= 1'b1;
        end else begin
            o_new_slot_pulse <= 1'b0;
        end
    end
end

endmodule
