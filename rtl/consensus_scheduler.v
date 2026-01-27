`timescale 1ns / 1ps

module consensus_scheduler #(
    parameter P_NODE_ID = 0,
    parameter P_SYS_CLOCK_FREQ_HZ = 250_000_000,  // 250 MHz
    parameter P_SLOT_DURATION_NS = 4000,  // 4 microseconds
    parameter P_GUARD_NS = 100,          // 100 nanoseconds
    parameter P_COMMIT_DURATION_NS = 1000 // 1 microsecond
)
(
    // clock and reset
    input  wire                         clk,
    input  wire                         rst_n,

    // Global control
    input wire                          i_enable,  // enable the scheduler

    // time source input
    input wire [63:0]                   i_ptp_time_ns,

    // status outputs
    output reg [63:0]                   o_current_slot_id,      // current slot id

    // control outputs
    output reg                          o_new_slot_pulse,       // indicate new slot start
    output reg                          o_commit_start_pulse,   // indicate commit start
    output reg                          o_slot_end_pulse,         // indicate slot end

    // transmit trigger
    output reg                          o_tx_allowed,           // allow transmission
    output reg                          o_rx_enabled          // enable receiving
);

localparam P_TX_START_NS        = P_GUARD_NS + P_NODE_ID * 200; // each node gets 200ns slot
localparam P_COMMIT_START_NS    = P_SLOT_DURATION_NS - P_COMMIT_DURATION_NS;

//-----------------------------------------------
//  Phase Calculation
//-----------------------------------------------
wire [63:0] w_calc_slot_id = i_ptp_time_ns / P_SLOT_DURATION_NS;
wire [63:0] w_calc_offset_ns = i_ptp_time_ns % P_SLOT_DURATION_NS;

reg [63:0] r_last_slot_id;
reg [63:0] r_last_offset_ns;

always @(posedge clk) begin
    if (!rst_n) begin
        o_current_slot_id       <= 64'b0;
        o_tx_allowed            <= 1'b0;
        o_commit_start_pulse    <= 1'b0;
        o_new_slot_pulse        <= 1'b0;
        o_slot_end_pulse        <= 1'b0;

        r_last_slot_id          <= 64'hFFFF_FFFF_FFFF_FFFF;
        r_last_offset_ns        <= 0;
    end else if (!i_enable) begin
        o_current_slot_id       <= 64'b0;
        o_tx_allowed            <= 1'b0;
        o_commit_start_pulse    <= 1'b0;
        o_new_slot_pulse        <= 1'b0;
        o_slot_end_pulse        <= 1'b0;

        r_last_slot_id          <= 64'hFFFF_FFFF_FFFF_FFFF;
        r_last_offset_ns        <= 0;
    end else begin
        // remember last time for edge detection
        o_current_slot_id       <= w_calc_slot_id;
        r_last_slot_id          <= w_calc_slot_id;
        r_last_offset_ns        <= w_calc_offset_ns;

        // Singal-1: Slot Start
        if (w_calc_slot_id != r_last_slot_id) begin
            o_new_slot_pulse        <= 1'b1;
        end else begin
            o_new_slot_pulse        <= 1'b0;
        end

        // Signal-2: Slot End
        if (w_calc_slot_id != r_last_slot_id && r_last_slot_id != 64'hFFFF_FFFF_FFFF_FFFF) begin
            o_slot_end_pulse        <= 1'b1;
        end else begin
            o_slot_end_pulse        <= 1'b0;
        end

        // Singal-3: TX Allow
        if (w_calc_offset_ns < P_COMMIT_START_NS && w_calc_offset_ns >= P_TX_START_NS) begin
            o_tx_allowed            <= 1'b1;
        end else begin
            o_tx_allowed            <= 1'b0;
        end

        // Singla-4: Commit Start, edge detection
        if (r_last_offset_ns < P_COMMIT_START_NS && w_calc_offset_ns >= P_COMMIT_START_NS) begin
            o_commit_start_pulse    <= 1'b1;
        end else begin
            o_commit_start_pulse    <= 1'b0;
        end

        // Signal-5: RX Enable
        if (w_calc_offset_ns < P_COMMIT_START_NS) begin
            o_rx_enabled            <= 1'b1;
        end else begin
            o_rx_enabled            <= 1'b0;
        end
    end
end

endmodule
