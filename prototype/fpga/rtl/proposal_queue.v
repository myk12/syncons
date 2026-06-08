`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Proposal queue
 */

module proposal_queue #
(
    /*
     * AXI-Lite interface configuration for control/status registers
     */
    parameter REG_ADDR_WIDTH = 12,
    parameter REG_DATA_WIDTH = 32,
    parameter REG_STRB_WIDTH = REG_DATA_WIDTH / 8,
    parameter RB_BASE_ADDR = 32'h0000_0000,

    /*
     * DMA descriptor interface configuration
     */
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,

    /*
     * DMA RAM interface configuration
     */
    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 16,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,

    /*
     * Proposal queue configuration
     *
     * With the default Corundum-style config:
     *   RAM_SEG_COUNT * RAM_SEG_DATA_WIDTH = 512 bits
     *   RAM_SEG_COUNT * RAM_SEG_BE_WIDTH   = 64 bytes
     *
     * Therefore one logical RAM row is one proposal entry.
     *
     * Default depth is 256 entries:
     *   256 * 64B = 16 KiB
     *
     * This fits in a 16-bit DMA length field.
     * If you want 1024 entries, increase DMA_LEN_WIDTH or split the transfer.
     */
    parameter PROP_ENTRY_WIDTH = RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH,
    parameter PROP_ENTRY_BYTES = RAM_SEG_COUNT*RAM_SEG_BE_WIDTH,
    parameter PROP_DEPTH = 256,
    parameter PROP_COUNT_WIDTH = $clog2(PROP_DEPTH+1),

    /*
     * Proposal RAM select value.
     *
     * This is placed in the DMA read descriptor.
     * The top-level DMA RAM demux should route dma_ram_wr_cmd_* with this
     * selector to this module's proposal_ram_wr_cmd_* port.
     */
    parameter RAM_SEL_PROP = 0,

    /*
     * Fixed DMA tag for proposal DMA read.
     */
    parameter DMA_TAG_PROP = 16'h5050
)
(
    input  wire                                     clk,
    input  wire                                     rst,

    // Register interface for starting a proposal DMA operation
    input  wire [REG_ADDR_WIDTH-1:0]                reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]                reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]                reg_wr_strb,
    input  wire                                     reg_wr_en,
    output wire                                     reg_wr_wait,
    output wire                                     reg_wr_ack,

    input  wire [REG_ADDR_WIDTH-1:0]                reg_rd_addr,
    output wire [REG_DATA_WIDTH-1:0]                reg_rd_data,
    input  wire                                     reg_rd_en,
    output wire                                     reg_rd_wait,
    output wire                                     reg_rd_ack,

    // DMA read descriptor output to DMA engine
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_dma_read_desc_tag,
    output wire                                     m_axis_dma_read_desc_valid,
    input  wire                                     m_axis_dma_read_desc_ready,

    // DMA read status input from DMA engine
    input  wire [DMA_TAG_WIDTH-1:0]                 s_axis_dma_read_desc_status_tag,
    input  wire [3:0]                               s_axis_dma_read_desc_status_error,
    input  wire                                     s_axis_dma_read_desc_status_valid,

    // DMA RAM write interface
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]           proposal_dma_ram_wr_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]        proposal_dma_ram_wr_cmd_be,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]      proposal_dma_ram_wr_cmd_addr,
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      proposal_dma_ram_wr_cmd_data,
    input  wire [RAM_SEG_COUNT-1:0]                         proposal_dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         proposal_dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                         proposal_dma_ram_wr_done
);

localparam integer RBB = RB_BASE_ADDR;

localparam integer PROP_ENTRY_BYTE_ADDR_WIDTH = $clog2(PROP_ENTRY_BYTES);
localparam integer PROP_RAM_SIZE = PROP_DEPTH*PROP_ENTRY_BYTES;
localparam integer DMA_LEN_MAX = (1 << DMA_LEN_WIDTH) - 1;

localparam [PROP_COUNT_WIDTH-1:0] PROP_DEPTH_COUNT = PROP_DEPTH;
localparam [DMA_LEN_WIDTH-1:0] PROP_RAM_SIZE_LEN = PROP_RAM_SIZE;

localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_PROP_VALUE = DMA_TAG_PROP;
localparam [RAM_SEL_WIDTH-1:0] RAM_SEL_PROP_VALUE = RAM_SEL_PROP;

/*
 * Configuration checks
 */
initial begin
    if (PROP_ENTRY_WIDTH != RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH) begin
        $error("PROP_ENTRY_WIDTH must equal RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH");
        $finish;
    end

    if (PROP_ENTRY_BYTES != RAM_SEG_COUNT*RAM_SEG_BE_WIDTH) begin
        $error("PROP_ENTRY_BYTES must equal RAM_SEG_COUNT*RAM_SEG_BE_WIDTH");
        $finish;
    end

    if (PROP_ENTRY_BYTES & (PROP_ENTRY_BYTES-1)) begin
        $error("PROP_ENTRY_BYTES must be a power of two");
        $finish;
    end

    if (PROP_RAM_SIZE > (1 << RAM_ADDR_WIDTH)) begin
        $error("Proposal RAM size exceeds RAM_ADDR_WIDTH address space");
        $finish;
    end

    if (PROP_RAM_SIZE > DMA_LEN_MAX) begin
        $error("Proposal RAM size exceeds DMA_LEN_WIDTH range");
        $finish;
    end
end

// -------------------------------------------------------------------------
//                  Register for Output Control and Status
// -------------------------------------------------------------------------
reg reg_wr_ack_reg = 1'b0, reg_wr_ack_next;
reg reg_rd_ack_reg = 1'b0, reg_rd_ack_next;
reg [REG_DATA_WIDTH-1:0] reg_rd_data_reg = {REG_DATA_WIDTH{1'b0}}, reg_rd_data_next;

reg [DMA_ADDR_WIDTH-1:0]    dma_read_desc_dma_addr_reg  = 0, dma_read_desc_dma_addr_next;
reg [RAM_ADDR_WIDTH-1:0]    dma_read_desc_ram_addr_reg  = 0, dma_read_desc_ram_addr_next;
reg [DMA_LEN_WIDTH-1:0]     dma_read_desc_len_reg       = 0, dma_read_desc_len_next;
reg [DMA_TAG_WIDTH-1:0]     dma_read_desc_tag_reg       = DMA_TAG_PROP_VALUE, dma_read_desc_tag_next;
reg                         dma_read_desc_valid_reg     = 1'b0, dma_read_desc_valid_next;

reg [DMA_TAG_WIDTH-1:0]     dma_read_desc_status_tag_reg    = 0, dma_read_desc_status_tag_next;
reg [3:0]                   dma_read_desc_status_error_reg  = 0, dma_read_desc_status_error_next;
reg                         dma_read_desc_status_valid_reg  = 0, dma_read_desc_status_valid_next;

reg [REG_DATA_WIDTH-1:0]    proposal_entry_counter_reg = 0, proposal_entry_counter_next;

// -------------------------------------------------------------------------
//                  Output assignments
// -------------------------------------------------------------------------

assign reg_wr_ack = reg_wr_ack_reg;
assign reg_rd_ack = reg_rd_ack_reg;
assign reg_rd_data = reg_rd_data_reg;
assign reg_wr_wait = 1'b0; // never wait, always ready to accept writes
assign reg_rd_wait = 1'b0; // never wait, always ready to accept reads

assign m_axis_dma_read_desc_dma_addr    = dma_read_desc_dma_addr_reg;
assign m_axis_dma_read_desc_ram_sel     = RAM_SEL_PROP_VALUE;
assign m_axis_dma_read_desc_ram_addr    = dma_read_desc_ram_addr_reg;
assign m_axis_dma_read_desc_len         = dma_read_desc_len_reg;
assign m_axis_dma_read_desc_tag         = dma_read_desc_tag_reg;
assign m_axis_dma_read_desc_valid       = dma_read_desc_valid_reg;

// -------------------------------------------------------------------------
//              Internal proposal RAM read interface
// -------------------------------------------------------------------------
wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] proposal_ram_rd_cmd_addr;
wire [RAM_SEG_COUNT-1:0]                    proposal_ram_rd_cmd_valid;
wire [RAM_SEG_COUNT-1:0]                    proposal_ram_rd_cmd_ready;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] proposal_ram_rd_resp_data;
wire [RAM_SEG_COUNT-1:0]                    proposal_ram_rd_resp_valid;
wire [RAM_SEG_COUNT-1:0]                    proposal_ram_rd_resp_ready;

assign proposal_ram_rd_cmd_addr = 0; // always read from address 0 for proposal RAM
assign proposal_ram_rd_cmd_valid = 0;
assign proposal_ram_rd_resp_ready = {RAM_SEG_COUNT{1'b1}};

// -------------------------------------------------------------------------
//                  Next-state logic
// -------------------------------------------------------------------------

always @* begin
    // default: hold current state
    reg_wr_ack_next     = 1'b0; // default no write acknowledge
    reg_rd_ack_next     = 1'b0; // default no read acknowledge
    reg_rd_data_next    = {REG_DATA_WIDTH{1'b0}}; // default read data is zero

    dma_read_desc_dma_addr_next = dma_read_desc_dma_addr_reg;
    dma_read_desc_ram_addr_next = dma_read_desc_ram_addr_reg;
    dma_read_desc_len_next      = dma_read_desc_len_reg;
    dma_read_desc_tag_next      = dma_read_desc_tag_reg;
    // deassert valid by default; it will be pulsed for one cycle when accepting a new descriptor
    dma_read_desc_valid_next    = dma_read_desc_valid_reg && !m_axis_dma_read_desc_ready;

    dma_read_desc_status_tag_next   = dma_read_desc_status_tag_reg;
    dma_read_desc_status_error_next = dma_read_desc_status_error_reg;
    dma_read_desc_status_valid_next = dma_read_desc_status_valid_reg;

    proposal_entry_counter_next = proposal_entry_counter_reg;

    if (reg_wr_en && !reg_wr_ack_reg) begin
        // write operation
        reg_wr_ack_next = 1'b1; // acknowledge the write
        case ({reg_wr_addr >> 2, 2'b00}) // align address to 4 bytes
            RBB + 12'h000: dma_read_desc_dma_addr_next[31:0] = reg_wr_data;
            RBB + 12'h004: dma_read_desc_dma_addr_next[63:32] = reg_wr_data;
            RBB + 12'h008: dma_read_desc_len_next = reg_wr_data[DMA_LEN_WIDTH-1:0];
            RBB + 12'h00c: begin
                dma_read_desc_tag_next = reg_wr_data[DMA_TAG_WIDTH-1:0];
                dma_read_desc_valid_next = 1'b1;
                dma_read_desc_ram_addr_next = {RAM_ADDR_WIDTH{1'b0}}; // always start at 0 for proposal RAM

                dma_read_desc_status_tag_next = {DMA_TAG_WIDTH{1'b0}};
                dma_read_desc_status_error_next = 4'b0000;
                dma_read_desc_status_valid_next = 1'b0;
            end
            default: begin
                reg_wr_ack_next = 1'b0;
            end
        endcase
    end

    if (reg_rd_en && !reg_rd_ack_reg) begin
        // read operation - decode address and return data
        reg_rd_ack_next = 1'b1; // acknowledge the read
        case ({reg_rd_addr >> 2, 2'b00}) // align address to 4 bytes
            RBB + 12'h000: reg_rd_data_next = dma_read_desc_dma_addr_reg[31:0];
            RBB + 12'h004: reg_rd_data_next = dma_read_desc_dma_addr_reg[63:32];
            RBB + 12'h008: reg_rd_data_next = dma_read_desc_len_reg;
            RBB + 12'h00c: reg_rd_data_next = {12'b0, dma_read_desc_tag_reg};
            RBB + 12'h010: reg_rd_data_next = proposal_entry_counter_reg;
            default: begin
                reg_rd_data_next = {REG_DATA_WIDTH{1'b0}};
                reg_rd_ack_next = 1'b0;
            end
        endcase
    end

    // store read response
    if (s_axis_dma_read_desc_status_valid) begin
        dma_read_desc_status_tag_next = s_axis_dma_read_desc_status_tag;
        dma_read_desc_status_error_next = s_axis_dma_read_desc_status_error;
        dma_read_desc_status_valid_next = s_axis_dma_read_desc_status_valid;
        
        proposal_entry_counter_next = proposal_entry_counter_reg + 1;
    end

end

// -------------------------------------------------------------------------
// Sequential logic
// -------------------------------------------------------------------------

always @(posedge clk) begin
    reg_wr_ack_reg <= reg_wr_ack_next;
    reg_rd_ack_reg <= reg_rd_ack_next;
    reg_rd_data_reg <= reg_rd_data_next;

    dma_read_desc_dma_addr_reg <= dma_read_desc_dma_addr_next;
    dma_read_desc_ram_addr_reg <= dma_read_desc_ram_addr_next;
    dma_read_desc_len_reg <= dma_read_desc_len_next;
    dma_read_desc_tag_reg <= dma_read_desc_tag_next;
    dma_read_desc_valid_reg <= dma_read_desc_valid_next;

    dma_read_desc_status_tag_reg <= dma_read_desc_status_tag_next;
    dma_read_desc_status_error_reg <= dma_read_desc_status_error_next;
    dma_read_desc_status_valid_reg <= dma_read_desc_status_valid_next;

    proposal_entry_counter_reg <= proposal_entry_counter_next;

    if (rst) begin
        reg_wr_ack_reg <= 1'b0;
        reg_rd_ack_reg <= 1'b0;
        reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};

        dma_read_desc_dma_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        dma_read_desc_ram_addr_reg <= {RAM_ADDR_WIDTH{1'b0}};
        dma_read_desc_len_reg <= {DMA_LEN_WIDTH{1'b0}};
        dma_read_desc_tag_reg <= DMA_TAG_PROP_VALUE;
        dma_read_desc_valid_reg <= 1'b0;

        dma_read_desc_status_tag_reg <= {DMA_TAG_WIDTH{1'b0}};
        dma_read_desc_status_error_reg <= 4'b0000;
        dma_read_desc_status_valid_reg <= 1'b0;

        proposal_entry_counter_reg <= {REG_DATA_WIDTH{1'b0}};
    end
end

// -------------------------------------------------------------------------
//                  Proposal RAM
// -------------------------------------------------------------------------

dma_psdpram #(
    .SIZE(PROP_RAM_SIZE),
    .SEG_COUNT(RAM_SEG_COUNT),
    .SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .PIPELINE(RAM_PIPELINE)
)
proposal_ram_inst (
    .clk(clk),
    .rst(rst),

    /*
     * Write port:
     * DMA read data from host lands here.
     */
    .wr_cmd_be(proposal_dma_ram_wr_cmd_be),
    .wr_cmd_addr(proposal_dma_ram_wr_cmd_addr),
    .wr_cmd_data(proposal_dma_ram_wr_cmd_data),
    .wr_cmd_valid(proposal_dma_ram_wr_cmd_valid),
    .wr_cmd_ready(proposal_dma_ram_wr_cmd_ready),
    .wr_done(proposal_dma_ram_wr_done),

    /*
     * Read port:
     * internal proposal reader -> ssr_core
     */
    .rd_cmd_addr(proposal_ram_rd_cmd_addr),
    .rd_cmd_valid(proposal_ram_rd_cmd_valid),
    .rd_cmd_ready(proposal_ram_rd_cmd_ready),
    .rd_resp_data(proposal_ram_rd_resp_data),
    .rd_resp_valid(proposal_ram_rd_resp_valid),
    .rd_resp_ready(proposal_ram_rd_resp_ready)
);

endmodule

`resetall
