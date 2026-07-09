`resetall
`timescale 1ns / 1ps
`default_nettype none

// Temporary proposal buffer sink.
//
// This module consumes proposal_buffer TX stream output.
// It is used only for simulation/integration validation.
//

module proposal_buffer_sink #
(
    parameter DMA_LEN_WIDTH = 16,

    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,

    parameter PROPOSAL_SLOT_BYTES = 1024
)
(
    input  wire                        clk,
    input  wire                        rst,

    // Stream input from proposal_buffer
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      buf_rd_data,
    input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]        buf_rd_be,
    input  wire                                             buf_rd_valid,
    output wire                                             buf_rd_ready,
    input  wire                                             buf_tx_last,
    input  wire [DMA_LEN_WIDTH-1:0]                         buf_tx_len,

    // Control
    input  wire                                             sink_enable,
    input  wire                                             sink_clear,

    // Status outputs
    output wire [31:0]                                      sink_slot_count,
    output wire [31:0]                                      sink_beat_count,
    output wire [31:0]                                      sink_error_count
);

localparam integer RAM_BEAT_BYTES                   = RAM_SEG_COUNT * RAM_SEG_BE_WIDTH;
localparam integer PROPOSAL_SLOT_BEAT_COUNT         = PROPOSAL_SLOT_BYTES / RAM_BEAT_BYTES;
localparam integer BEAT_INDEX_WIDTH                 = PROPOSAL_SLOT_BEAT_COUNT > 1 ? $clog2(PROPOSAL_SLOT_BEAT_COUNT) : 1;
localparam [BEAT_INDEX_WIDTH-1:0] LAST_BEAT_INDEX   = PROPOSAL_SLOT_BEAT_COUNT - 1;
localparam [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0] FULL_BE = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};

// =====================================================================
//              Internal signals and registers
// =====================================================================
// For now, always consume data when enabled.
assign buf_rd_ready = sink_enable && !sink_clear && !rst;

reg [31:0] sink_slot_count_reg = 32'd0;
reg [31:0] sink_beat_count_reg = 32'd0;
reg [31:0] sink_error_count_reg = 32'd0;

reg [BEAT_INDEX_WIDTH-1:0] beat_index_reg = {BEAT_INDEX_WIDTH{1'b0}};

wire stream_fire = buf_rd_valid && buf_rd_ready;
wire be_error = stream_fire && (buf_rd_be != FULL_BE);
wire last_missing_error = stream_fire && (beat_index_reg == LAST_BEAT_INDEX) && !buf_tx_last;
wire last_early_error = stream_fire && (beat_index_reg != LAST_BEAT_INDEX) && buf_tx_last;
wire [31:0] error_inc = (be_error ? 32'd1 : 32'd0) + (last_missing_error ? 32'd1 : 32'd0) + (last_early_error ? 32'd1 : 32'd0);

// Status counters
assign sink_slot_count  = sink_slot_count_reg;
assign sink_beat_count  = sink_beat_count_reg;
assign sink_error_count = sink_error_count_reg;


// =====================================================================
//              Sequential logic
// =====================================================================

always @(posedge clk) begin
    if (rst || sink_clear) begin
        sink_slot_count_reg  <= 32'd0;
        sink_beat_count_reg  <= 32'd0;
        sink_error_count_reg <= 32'd0;
        beat_index_reg       <= {BEAT_INDEX_WIDTH{1'b0}};
    end else begin
        if (stream_fire) begin

            sink_beat_count_reg <= sink_beat_count_reg + 1;

            if (beat_index_reg == LAST_BEAT_INDEX) begin

                sink_slot_count_reg <= sink_slot_count_reg + 1;
                beat_index_reg <= {BEAT_INDEX_WIDTH{1'b0}};

            end else begin

                beat_index_reg <= beat_index_reg + 1;

            end

            sink_error_count_reg <= sink_error_count_reg + error_inc;
        end
    end
end

endmodule
