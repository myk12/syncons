`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Test-only commit generator.
 *
 * Role:
 *   - Generate fixed-size commit slots.
 *   - Replace rx_engine in ssr_dataplane shadow test.
 *
 * One generated commit slot has:
 *   - COMMIT_SLOT_BYTES bytes
 *   - full byte enable
 *   - commit_in_last asserted on the final beat
 */

module commit_generator #
(
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,

    parameter COMMIT_SLOT_BYTES = 1024
)
(
    input  wire                                             clk,
    input  wire                                             rst,

    /*
     * Control
     */
    input  wire                                             start,
    input  wire                                             stop,
    input  wire                                             clear,
    input  wire [31:0]                                      commit_count,

    /*
     * Status
     */
    output wire                                             busy,
    output wire                                             done,
    output wire [31:0]                                      generated_count,
    output wire [31:0]                                      generated_beat_count,

    /*
     * Commit stream output to commit_buffer
     */
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      commit_in_data,
    output wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]        commit_in_be,
    output wire                                             commit_in_valid,
    input  wire                                             commit_in_ready,
    output wire                                             commit_in_last
);

localparam integer RAM_BEAT_BYTES =
    RAM_SEG_COUNT * RAM_SEG_BE_WIDTH;

localparam integer COMMIT_SLOT_BEAT_COUNT =
    COMMIT_SLOT_BYTES / RAM_BEAT_BYTES;

localparam integer COMMIT_SLOT_BEAT_INDEX_WIDTH =
    COMMIT_SLOT_BEAT_COUNT > 1 ? $clog2(COMMIT_SLOT_BEAT_COUNT) : 1;

localparam [COMMIT_SLOT_BEAT_INDEX_WIDTH-1:0] COMMIT_LAST_BEAT_INDEX =
    COMMIT_SLOT_BEAT_COUNT - 1;

localparam integer DATA_WORD_COUNT =
    RAM_SEG_COUNT * RAM_SEG_DATA_WIDTH / 32;

localparam [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0] FULL_BE =
    {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};

initial begin
    if (COMMIT_SLOT_BYTES == 0) begin
        $error("COMMIT_SLOT_BYTES must be nonzero");
        $finish;
    end

    if (COMMIT_SLOT_BYTES % RAM_BEAT_BYTES != 0) begin
        $error("COMMIT_SLOT_BYTES must be a multiple of RAM_BEAT_BYTES");
        $finish;
    end

    if ((RAM_SEG_COUNT * RAM_SEG_DATA_WIDTH) % 32 != 0) begin
        $error("commit_generator data width must be a multiple of 32");
        $finish;
    end
end

reg busy_reg = 1'b0;
reg done_reg = 1'b0;

reg [31:0] target_count_reg = 32'd0;
reg [31:0] generated_count_reg = 32'd0;
reg [31:0] generated_beat_count_reg = 32'd0;

reg [COMMIT_SLOT_BEAT_INDEX_WIDTH-1:0] beat_index_reg = 0;

assign busy = busy_reg;
assign done = done_reg;
assign generated_count = generated_count_reg;
assign generated_beat_count = generated_beat_count_reg;

assign commit_in_valid =
    busy_reg && generated_count_reg < target_count_reg;

assign commit_in_be =
    FULL_BE;

assign commit_in_last =
    beat_index_reg == COMMIT_LAST_BEAT_INDEX;

wire commit_in_fire =
    commit_in_valid && commit_in_ready;

wire [31:0] beat_index_word =
    beat_index_reg;

wire [31:0] pattern_word =
    32'hc000_0000 ^
    generated_count_reg ^
    (beat_index_word << 16);

assign commit_in_data =
    {DATA_WORD_COUNT{pattern_word}};

always @(posedge clk) begin
    if (rst) begin
        busy_reg <= 1'b0;
        done_reg <= 1'b0;

        target_count_reg <= 32'd0;
        generated_count_reg <= 32'd0;
        generated_beat_count_reg <= 32'd0;

        beat_index_reg <= 0;
    end else begin
        if (clear) begin
            busy_reg <= 1'b0;
            done_reg <= 1'b0;

            target_count_reg <= 32'd0;
            generated_count_reg <= 32'd0;
            generated_beat_count_reg <= 32'd0;

            beat_index_reg <= 0;
        end else if (start) begin
            target_count_reg <= commit_count;
            generated_count_reg <= 32'd0;
            generated_beat_count_reg <= 32'd0;
            beat_index_reg <= 0;

            if (commit_count == 0) begin
                busy_reg <= 1'b0;
                done_reg <= 1'b1;
            end else begin
                busy_reg <= 1'b1;
                done_reg <= 1'b0;
            end
        end else if (stop) begin
            busy_reg <= 1'b0;
        end else if (commit_in_fire) begin
            generated_beat_count_reg <= generated_beat_count_reg + 1'b1;

            if (beat_index_reg == COMMIT_LAST_BEAT_INDEX) begin
                beat_index_reg <= 0;
                generated_count_reg <= generated_count_reg + 1'b1;

                if (generated_count_reg + 1 >= target_count_reg) begin
                    busy_reg <= 1'b0;
                    done_reg <= 1'b1;
                end
            end else begin
                beat_index_reg <= beat_index_reg + 1'b1;
            end
        end
    end
end

endmodule

`resetall
