`timescale 1ns / 1ps

module consensus_scheduler #(
    parameter P_NODE_ID = 0,
    parameter P_SYS_CLOCK_FREQ_HZ = 250_000_000,  // 250 MHz
    parameter P_SLOT_DURATION_NS = 4000,  // 4 microseconds
    parameter P_GUARD_NS = 100,          // 100 nanoseconds
    parameter P_COMMIT_DURATION_NS = 1000 // 1 microsecond
    parameter PTP_TS_FMT_TOD = 1,
    parameter PTP_TS_WIDTH = PTP_TS_FMT_TOD ? 96 : 64
)
(
    // clock and reset
    input  wire                         clk,
    input  wire                         rst_n,

    // Global control
    input wire                          i_enable,  // enable the scheduler

    // time source input
    input wire [PTP_TS_WIDTH-1:0]       ptp_sync_ts_tod,

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
reg [PTP_TS_WIDTH-1:0] i_ptp_start_time_ns;
reg last_enable;

wire enable_rising_edge = i_enable && !last_enable;

wire [63:0] w_calc_slot_id;
wire [63:0] w_calc_offset_ns;

assign w_calc_slot_id = i_enable ? (ptp_sync_ts_tod - i_ptp_start_time_ns) / P_SLOT_DURATION_NS : 64'b0;
assign w_calc_offset_ns = i_enable ? (ptp_sync_ts_tod - i_ptp_start_time_ns) % P_SLOT_DURATION_NS : 64'b0;

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
        last_enable             <= 1'b0;
        i_ptp_start_time_ns     <= 0;
    end else if (!i_enable) begin
        o_current_slot_id       <= 64'b0;
        o_tx_allowed            <= 1'b0;
        o_commit_start_pulse    <= 1'b0;
        o_new_slot_pulse        <= 1'b0;
        o_slot_end_pulse        <= 1'b0;

        r_last_slot_id          <= 64'hFFFF_FFFF_FFFF_FFFF;
        r_last_offset_ns        <= 0;
        last_enable             <= i_enable;
        i_ptp_start_time_ns     <= 0;
    end else begin
        // remember last time for edge detection
        o_current_slot_id       <= w_calc_slot_id;
        r_last_slot_id          <= w_calc_slot_id;
        r_last_offset_ns        <= w_calc_offset_ns;

        last_enable             <= i_enable;

        if (enable_rising_edge) begin
            i_ptp_start_time_ns <= ptp_sync_ts_tod;
        end

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
