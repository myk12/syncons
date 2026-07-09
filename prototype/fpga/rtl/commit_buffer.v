`resetall
`timescale 1ns / 1ps
`default_nettype none

module commit_buffer #
(
    parameter DMA_LEN_WIDTH = 16,
    parameter RAM_SEL_WIDTH = 4,

    parameter RAM_ADDR_WIDTH = 16,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,

    parameter COMMIT_SLOT_BYTES = 1024,
    parameter COMMIT_SLOT_COUNT = 64
)
(
    input  wire                        clk,
    input  wire                        rst,

    // Commit stream input from rx_engine or test source
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      commit_in_data,
    input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]        commit_in_be,
    input  wire                                             commit_in_valid,
    input  wire                                             commit_in_last,
    output wire                                             commit_in_ready,

    // output to commit_dma_writer
    output wire                                             head_slot_valid,
    output wire [RAM_ADDR_WIDTH-1:0]                        head_slot_addr,
    output wire [DMA_LEN_WIDTH-1:0]                         head_slot_len,

    input  wire                                             head_slot_pop_valid,
    output wire                                             head_slot_pop_ready,

    output wire [31:0]                                      commit_error_count,

    // DMA RAM read interface
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]           dma_ram_rd_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]      dma_ram_rd_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                         dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         dma_ram_rd_cmd_ready,

    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                         dma_ram_rd_resp_valid,
    input  wire [RAM_SEG_COUNT-1:0]                         dma_ram_rd_resp_ready
);

// ===========================================================================
// local parameters
// ===========================================================================

// BEAT
localparam integer RAM_BEAT_BYTES                   = RAM_SEG_COUNT * RAM_SEG_BE_WIDTH;     // 2*64
localparam integer COMMIT_SLOT_BEAT_COUNT           = COMMIT_SLOT_BYTES / RAM_BEAT_BYTES;   // 1024/(2*64) = 8
localparam integer COMMIT_SLOT_BEAT_INDEX_WIDTH     = (COMMIT_SLOT_BEAT_COUNT > 1) ? $clog2(COMMIT_SLOT_BEAT_COUNT) : 1;
localparam [COMMIT_SLOT_BEAT_INDEX_WIDTH-1:0] COMMIT_LAST_BEAT_INDEX = COMMIT_SLOT_BEAT_COUNT -1;

// SLOT
localparam integer COMMIT_SLOT_BYTE_ADDR_WIDTH  = $clog2(COMMIT_SLOT_BYTES);
localparam integer COMMIT_SLOT_PTR_WIDTH   = COMMIT_SLOT_COUNT > 1 ? $clog2(COMMIT_SLOT_COUNT) : 1;
localparam integer COMMIT_SLOT_COUNT_WIDTH = $clog2(COMMIT_SLOT_COUNT + 1);
localparam [DMA_LEN_WIDTH-1:0] COMMIT_SLOT_BYTES_LEN = COMMIT_SLOT_BYTES;
localparam [COMMIT_SLOT_COUNT_WIDTH-1:0] COMMIT_SLOT_COUNT_VALUE = COMMIT_SLOT_COUNT;

localparam integer BUFFER_RAM_SIZE = COMMIT_SLOT_BYTES * COMMIT_SLOT_COUNT;
localparam [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0] FULL_BE = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};

initial begin
    if (COMMIT_SLOT_BYTES == 0 || 
        COMMIT_SLOT_BYTES % RAM_BEAT_BYTES != 0 || 
        COMMIT_SLOT_BYTES & (COMMIT_SLOT_BYTES - 1)) begin
        $error("Error: COMMIT_SLOT_BYTES must be a non-zero multiple of RAM_BEAT_BYTES and a power of 2 (COMMIT_SLOT_BYTES=%d, RAM_BEAT_BYTES=%d)", COMMIT_SLOT_BYTES, RAM_BEAT_BYTES);
        $finish;
    end
    if (COMMIT_SLOT_COUNT == 0 || 
        COMMIT_SLOT_COUNT & (COMMIT_SLOT_COUNT - 1)) begin
        $error("Error: COMMIT_SLOT_COUNT must be a non-zero power of 2 (COMMIT_SLOT_COUNT=%d)", COMMIT_SLOT_COUNT);
        $finish;
    end
end

// ===========================================================================
//              Internal state
// ===========================================================================
reg [COMMIT_SLOT_PTR_WIDTH-1:0] head_ptr_reg = 0, head_ptr_next;
reg [COMMIT_SLOT_PTR_WIDTH-1:0] tail_ptr_reg = 0, tail_ptr_next;
reg [COMMIT_SLOT_COUNT_WIDTH-1:0] slot_count_reg = 0, slot_count_next;
reg [COMMIT_SLOT_BEAT_INDEX_WIDTH-1:0] write_beat_index_reg = 0, write_beat_index_next;

wire buffer_empty   = (slot_count_reg == 0);
wire buffer_full    = (slot_count_reg == COMMIT_SLOT_COUNT_VALUE);

assign head_slot_valid  = !buffer_empty;
assign head_slot_addr   = ({{(RAM_ADDR_WIDTH-COMMIT_SLOT_PTR_WIDTH){1'b0}}, head_ptr_reg} << COMMIT_SLOT_BYTE_ADDR_WIDTH);

assign head_slot_len = COMMIT_SLOT_BYTES_LEN;
assign head_slot_pop_ready = !buffer_empty;

wire head_slot_pop_fire = head_slot_pop_valid && head_slot_pop_ready;

reg  [31:0] commit_error_count_reg = 32'd0;
assign commit_error_count = commit_error_count_reg;

wire commit_in_fire = commit_in_valid && commit_in_ready;
wire commit_be_error = commit_in_fire && commit_in_be != FULL_BE;
wire commit_last_missing_error = commit_in_fire && write_beat_index_reg == COMMIT_LAST_BEAT_INDEX && !commit_in_last;
wire commit_last_early_error = commit_in_fire && write_beat_index_reg != COMMIT_LAST_BEAT_INDEX && commit_in_last;
wire [31:0] commit_error_inc = (commit_be_error ? 32'd1 : 32'd0) + (commit_last_missing_error ? 32'd1 : 32'd0) + (commit_last_early_error ? 32'd1 : 32'd0);

// ----------------------------------------------------------
//              Internal RAM writer interface
// ----------------------------------------------------------
wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]       ram_wr_cmd_be;
wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]     ram_wr_cmd_addr;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]     ram_wr_cmd_data;
wire [RAM_SEG_COUNT-1:0]                        ram_wr_cmd_valid;
wire [RAM_SEG_COUNT-1:0]                        ram_wr_cmd_ready;
wire [RAM_SEG_COUNT-1:0]                        ram_wr_done;

assign commit_in_ready = !buffer_full && (&ram_wr_cmd_ready);

assign ram_wr_cmd_be = commit_in_be;
assign ram_wr_cmd_data = commit_in_data;
wire [RAM_SEG_ADDR_WIDTH-1:0] commit_tail_base_row_addr;
wire [RAM_SEG_ADDR_WIDTH-1:0] commit_wr_row_addr;

assign commit_tail_base_row_addr = tail_ptr_reg * COMMIT_SLOT_BEAT_COUNT;
assign commit_wr_row_addr = commit_tail_base_row_addr + write_beat_index_reg;
assign ram_wr_cmd_addr = {RAM_SEG_COUNT{commit_wr_row_addr}};
wire commit_in_ram_valid = commit_in_valid && !buffer_full;
assign ram_wr_cmd_valid = {RAM_SEG_COUNT{commit_in_ram_valid}};

wire tail_slot_push_fire = commit_in_fire && (write_beat_index_reg == COMMIT_LAST_BEAT_INDEX);

// ===========================================================================
//                 Combinatorial logic
// ===========================================================================

// RAM Buffer Write Logic
always @* begin
    head_ptr_next = head_ptr_reg;
    tail_ptr_next = tail_ptr_reg;
    slot_count_next = slot_count_reg;
    write_beat_index_next = write_beat_index_reg;

    if (commit_in_fire) begin
        if (write_beat_index_reg == COMMIT_LAST_BEAT_INDEX) begin
            write_beat_index_next = 0;
        end else begin
            write_beat_index_next = write_beat_index_reg + 1;
        end
    end

    if (tail_slot_push_fire) begin
        tail_ptr_next = tail_ptr_reg + 1;
    end

    if (head_slot_pop_fire) begin
        head_ptr_next = head_ptr_reg + 1;
    end

    case ({tail_slot_push_fire, head_slot_pop_fire})
        2'b00: slot_count_next = slot_count_reg;
        2'b01: slot_count_next = slot_count_reg - 1;
        2'b10: slot_count_next = slot_count_reg + 1;
        2'b11: slot_count_next = slot_count_reg;
        default: slot_count_next = slot_count_reg;
    endcase
end

// ===========================================================================
//              Sequential logic
// ===========================================================================
always @(posedge clk) begin
    if (rst) begin
        head_ptr_reg <= 0;
        tail_ptr_reg <= 0;
        slot_count_reg <= 0;
        write_beat_index_reg <= 0;
        commit_error_count_reg <= 32'd0;
    end else begin
        head_ptr_reg <= head_ptr_next;
        tail_ptr_reg <= tail_ptr_next;
        slot_count_reg <= slot_count_next;
        write_beat_index_reg <= write_beat_index_next;
        
        if (commit_in_fire) begin
            commit_error_count_reg <= commit_error_count_reg + commit_error_inc;
        end
    end
end

// ===========================================================================
//                      Internal RAM
// ===========================================================================
dma_psdpram #(
    .SIZE(BUFFER_RAM_SIZE),
    .SEG_COUNT(RAM_SEG_COUNT),
    .SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .PIPELINE(RAM_PIPELINE)
)
commit_ram_inst (
    .clk(clk),
    .rst(rst),

    // Write interface
    .wr_cmd_be(ram_wr_cmd_be),
    .wr_cmd_addr(ram_wr_cmd_addr),
    .wr_cmd_data(ram_wr_cmd_data),
    .wr_cmd_valid(ram_wr_cmd_valid),
    .wr_cmd_ready(ram_wr_cmd_ready),
    .wr_done(ram_wr_done),

    // Read interface
    .rd_cmd_addr(dma_ram_rd_cmd_addr),
    .rd_cmd_valid(dma_ram_rd_cmd_valid),
    .rd_cmd_ready(dma_ram_rd_cmd_ready),
    .rd_resp_data(dma_ram_rd_resp_data),
    .rd_resp_valid(dma_ram_rd_resp_valid),
    .rd_resp_ready(dma_ram_rd_resp_ready)
);

endmodule

`resetall
