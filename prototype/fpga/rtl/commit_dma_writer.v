`resetall
`timescale 1ns / 1ps
`default_nettype none

// Commit queue module
module commit_queue #
(
    // AXI-Lite interface parameters
    parameter REG_ADDR_WIDTH = 12,
    parameter REG_DATA_WIDTH = 32,
    parameter REG_STRB_WIDTH = (REG_DATA_WIDTH/8),
    parameter RB_BASE_ADDR = 32'h0000_0000,

    // DMA descriptor interface configuration
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_IMM_ENABLE = 0,
    parameter DMA_IMM_WIDTH = 32,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,

    // DMA RAM interface configuration
    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 16,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2
)
(
    input  wire                         clk,
    input  wire                         rst,

    // Register interface for control and status
    input  wire [REG_ADDR_WIDTH-1:0]    reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]    reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]    reg_wr_strb,
    input  wire                         reg_wr_en,
    output wire                         reg_wr_wait,
    output wire                         reg_wr_ack,

    input  wire [REG_ADDR_WIDTH-1:0]    reg_rd_addr,
    input  wire                         reg_rd_en,
    output wire [REG_DATA_WIDTH-1:0]    reg_rd_data,
    output wire                         reg_rd_wait,
    output wire                         reg_rd_ack,

    // DMA write descriptor output
    output wire [DMA_ADDR_WIDTH-1:0]    m_axis_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]     m_axis_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]    m_axis_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]     m_axis_dma_write_desc_imm,
    output wire                         m_axis_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]     m_axis_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]     m_axis_dma_write_desc_tag,
    output wire                         m_axis_dma_write_desc_valid,
    input  wire                         m_axis_dma_write_desc_ready,

    // DMA write status input from DAM engine
    input wire [DMA_TAG_WIDTH-1:0]      s_axis_dma_write_status_tag,
    input wire [3:0]                    s_axis_dma_write_status_error,
    input wire                          s_axis_dma_write_status_valid,

    // DMA RAM read interface
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]        dma_ram_rd_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]   dma_ram_rd_cmd_addr,
    input wire [RAM_SEG_COUNT-1:0]                      dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_resp_valid,
    input wire [RAM_SEG_COUNT-1:0]                      dma_ram_rd_resp_ready
);

localparam RBB = RB_BASE_ADDR;

// -----------------------------------------------------------------------------
//                    Control/Status register interface handling
// -----------------------------------------------------------------------------

// Register Map:
// - 0x000: COMMIT_QUEUE_MAGIC [0x636f6d71/comq] - Magic value to identify the commit queue
// - 0x004: COMMIT_QUEUE_VERSION [0x00010000/1.0] - Version number of the commit queue implementation (not implemented in this example, always returns 1.0)
// - 0x008: COMMIT_QUEUE_FEATURES [0x00000001] - Bitfield of supported features (not implemented in this example, always returns 1 to indicate basic functionality)
// - 0x00C: COMMIT_QUEUE_CTRL           - Control register for the commit queue (not implemented in this example, reserved for future use)
// - 0x010: COMMIT_QUEUE_STATUS         - Status register for the commit queue (not implemented in this example, reserved for future use)
// - 0x014: COMMIT_QUEUE_SCRATCH         - Scratch register for testing read/write access (not implemented in this example, always returns 0)

// DMA Descriptor Registers:
// - 0x104: COMMIT_QUEUE_DMA_DESC_ADDR_LO          - Lower 32 bits of DMA address for write descriptor
// - 0x108: COMMIT_QUEUE_DMA_DESC_ADDR_HI          - Upper 32 bits of DMA address for write descriptor
// - 0x10C: COMMIT_QUEUE_DMA_DESC_LEN              - Length of the DMA transfer in bytes
// - 0x110: COMMIT_QUEUE_DMA_DESC_TAG              - RAM tag for the DMA transfer
// - 0x114: COMMIT_QUEUE_DMA_DESC_STATUS_TAG       - Tag from the last DMA write status
// - 0x118: COMMIT_QUEUE_DMA_DESC_STATUS_ERROR     - Error code from the last DMA write status

// Internal registers
reg reg_wr_ack_reg = 1'b0, reg_wr_ack_next;
reg reg_rd_ack_reg = 1'b0, reg_rd_ack_next;
reg [REG_DATA_WIDTH-1:0] reg_rd_data_reg = {REG_DATA_WIDTH{1'b0}}, reg_rd_data_next;

reg [REG_DATA_WIDTH-1:0] scratch_reg = {REG_DATA_WIDTH{1'b0}};

reg [DMA_ADDR_WIDTH-1:0]    dma_write_desc_dma_addr_reg     = {DMA_ADDR_WIDTH{1'b0}}, dma_write_desc_dma_addr_next;
//reg [RAM_SEL_WIDTH-1:0]     dma_write_desc_ram_sel_reg    = {RAM_SEL_WIDTH{1'b0}}, dma_write_desc_ram_sel_next;
reg [RAM_ADDR_WIDTH-1:0]    dma_write_desc_ram_addr_reg     = {RAM_ADDR_WIDTH{1'b0}}, dma_write_desc_ram_addr_next;
//reg [DMA_IMM_WIDTH-1:0]     dma_write_desc_imm_reg        = {DMA_IMM_WIDTH{1'b0}}, dma_write_desc_imm_next;
//reg                         dma_write_desc_imm_en_reg     = 1'b0, dma_write_desc_imm_en_next;
reg [DMA_LEN_WIDTH-1:0]     dma_write_desc_len_reg          = {DMA_LEN_WIDTH{1'b0}}, dma_write_desc_len_next;
reg [DMA_TAG_WIDTH-1:0]     dma_write_desc_tag_reg          = {DMA_TAG_WIDTH{1'b0}}, dma_write_desc_tag_next;
reg                         dma_write_desc_valid_reg        = 1'b0, dma_write_desc_valid_next;

reg [DMA_TAG_WIDTH-1:0]     dma_write_status_tag_reg    = {DMA_TAG_WIDTH{1'b0}}, dma_write_status_tag_next;
reg [3:0]                   dma_write_status_error_reg  = 4'b0000, dma_write_status_error_next;
reg                         dma_write_status_valid_reg  = 1'b0, dma_write_status_valid_next;

// Output assignments
assign reg_wr_ack   = reg_wr_ack_reg;
assign reg_rd_ack   = reg_rd_ack_reg;
assign reg_rd_data  = reg_rd_data_reg;
assign reg_wr_wait  = 1'b0; // Always ready to accept writes
assign reg_rd_wait  = 1'b0; // Always ready to accept reads

assign m_axis_dma_write_desc_dma_addr   = dma_write_desc_dma_addr_reg;
assign m_axis_dma_write_desc_ram_sel    = {RAM_SEL_WIDTH{1'b0}}; // For simplicity, we use a fixed RAM selection in this example
assign m_axis_dma_write_desc_ram_addr   = dma_write_desc_ram_addr_reg;
assign m_axis_dma_write_desc_imm        = {DMA_IMM_WIDTH{1'b0}}; // No immediate data in this example
assign m_axis_dma_write_desc_imm_en     = 1'b0; // Immediate data not enabled
assign m_axis_dma_write_desc_len        = dma_write_desc_len_reg;
assign m_axis_dma_write_desc_tag        = dma_write_desc_tag_reg;
assign m_axis_dma_write_desc_valid      = dma_write_desc_valid_reg;

// Combinational logic for next state and output calculations
always @* begin
    // Default values for next state
    reg_wr_ack_next = 1'b0;
    reg_rd_ack_next = 1'b0;
    reg_rd_data_next = {REG_DATA_WIDTH{1'b0}};

    dma_write_desc_dma_addr_next    = dma_write_desc_dma_addr_reg;
    dma_write_desc_ram_addr_next    = dma_write_desc_ram_addr_reg;
    dma_write_desc_len_next         = dma_write_desc_len_reg;
    dma_write_desc_tag_next         = dma_write_desc_tag_reg;
    dma_write_desc_valid_next       = dma_write_desc_valid_reg && !m_axis_dma_write_desc_ready; // Clear valid when the descriptor is accepted

    dma_write_status_tag_next       = dma_write_status_tag_reg;
    dma_write_status_error_next     = dma_write_status_error_reg;
    dma_write_status_valid_next     = dma_write_status_valid_reg;

    // Handle register writes
    if (reg_wr_en && !reg_wr_ack_reg) begin
        reg_wr_ack_next = 1'b1; // Acknowledge the write
        case ({reg_wr_addr[REG_ADDR_WIDTH-1:2], 2'b00}) 
            // Header registers (read-only)
            RBB + 12'h000: ; // COMMIT_QUEUE_MAGIC is read-only
            RBB + 12'h004: ; // COMMIT_QUEUE_VERSION is read-only
            RBB + 12'h008: ; // COMMIT_QUEUE_FEATURES is read-only
            RBB + 12'h00C: ; // COMMIT_QUEUE_CTRL is reserved for future use
            RBB + 12'h010: ; // COMMIT_QUEUE_STATUS is reserved for future use
            RBB + 12'h014: scratch_reg <= reg_wr_data; // Write to scratch register for testing

            // DMA descriptor registers (write-only)
            RBB + 12'h104: dma_write_desc_dma_addr_next[31:0]   = reg_wr_data; // lower bits of DMA address
            RBB + 12'h108: dma_write_desc_dma_addr_next[63:32]  = reg_wr_data; // upper bits of DMA address
            RBB + 12'h10C: dma_write_desc_len_next              = reg_wr_data[DMA_LEN_WIDTH-1:0]; // DMA transfer length
            RBB + 12'h110: begin
                // start a new DMA write descriptor
                dma_write_desc_tag_next     = reg_wr_data[DMA_TAG_WIDTH-1:0]; // DMA tag
                dma_write_desc_valid_next   = 1'b1; // Set valid to indicate a new descriptor is ready

                // clear status
                dma_write_status_tag_next   = 0;   
                dma_write_status_valid_next = 1'b0;
                dma_write_status_error_next = 0;
            end
            default: begin
                reg_wr_ack_next = 1'b0; // No acknowledgment for undefined addresses
            end
        endcase
    end

    // Handle register reads
    if (reg_rd_en && !reg_rd_ack_reg) begin
        reg_rd_ack_next = 1'b1; // Acknowledge the read
        case ({reg_rd_addr[REG_ADDR_WIDTH-1:2], 2'b00})
            // Header registers
            RBB + 12'h000: reg_rd_data_next = 32'h636f6d71; // "comq" in ASCII - Magic value to identify the commit queue
            RBB + 12'h004: reg_rd_data_next = 32'h00000100; // Version 1.0
            RBB + 12'h008: reg_rd_data_next = 32'h00000001; // Bit 0 indicates basic functionality supported
            RBB + 12'h00C: reg_rd_data_next = {REG_DATA_WIDTH{1'b0}}; // COMMIT_QUEUE_CTRL is reserved for future use, return 0
            RBB + 12'h010: reg_rd_data_next = {REG_DATA_WIDTH{1'b0}}; // COMMIT_QUEUE_STATUS is reserved for future use, return 0
            RBB + 12'h014: reg_rd_data_next = scratch_reg; // Return the value of the scratch register

            // DMA descriptor registers
            RBB + 12'h104: reg_rd_data_next = dma_write_desc_dma_addr_reg[31:0]; // lower bits of DMA address
            RBB + 12'h108: reg_rd_data_next = dma_write_desc_dma_addr_reg[63:32]; // upper bits of DMA address
            RBB + 12'h10C: reg_rd_data_next = { {(REG_DATA_WIDTH-DMA_LEN_WIDTH){1'b0}}, dma_write_desc_len_reg }; // DMA transfer length
            RBB + 12'h110: reg_rd_data_next = { {(REG_DATA_WIDTH-DMA_TAG_WIDTH){1'b0}}, dma_write_desc_tag_reg }; // DMA tag
            RBB + 12'h114: reg_rd_data_next = { {(REG_DATA_WIDTH-DMA_TAG_WIDTH){1'b0}}, dma_write_status_tag_reg }; // Last status error
            RBB + 12'h118: reg_rd_data_next = { {(REG_DATA_WIDTH-4){1'b0}}, dma_write_status_error_reg }; // Last status error code
            default: begin
                reg_rd_ack_next = 1'b0; // No acknowledgment for undefined addresses
                reg_rd_data_next = {REG_DATA_WIDTH{1'b0}}; // Return zero for undefined addresses
            end
        endcase
    end

    // store write response
    if (s_axis_dma_write_status_valid) begin
        dma_write_status_tag_next   = s_axis_dma_write_status_tag;
        dma_write_status_error_next = s_axis_dma_write_status_error;
        dma_write_status_valid_next = 1'b1; // Set valid when a new status is received
    end
end

// Sequential logic for state updates
always @(posedge clk) begin
    // update registers with next state values
    reg_wr_ack_reg <= reg_wr_ack_next;
    reg_rd_ack_reg <= reg_rd_ack_next;
    reg_rd_data_reg <= reg_rd_data_next;

    dma_write_desc_dma_addr_reg <= dma_write_desc_dma_addr_next;
    dma_write_desc_ram_addr_reg <= dma_write_desc_ram_addr_next;
    dma_write_desc_len_reg <= dma_write_desc_len_next;
    dma_write_desc_tag_reg <= dma_write_desc_tag_next;
    dma_write_desc_valid_reg <= dma_write_desc_valid_next;

    dma_write_status_tag_reg <= dma_write_status_tag_next;
    dma_write_status_error_reg <= dma_write_status_error_next;
    dma_write_status_valid_reg <= dma_write_status_valid_next;

    scratch_reg <= scratch_reg; // hold the value of the scratch register

    if (rst) begin
        reg_wr_ack_reg <= 1'b0;
        reg_rd_ack_reg <= 1'b0;
        reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};

        dma_write_desc_dma_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        dma_write_desc_ram_addr_reg <= {RAM_ADDR_WIDTH{1'b0}};
        dma_write_desc_len_reg <= {DMA_LEN_WIDTH{1'b0}};
        dma_write_desc_tag_reg <= {DMA_TAG_WIDTH{1'b0}};
        dma_write_desc_valid_reg <= 1'b0;

        dma_write_status_tag_reg <= {DMA_TAG_WIDTH{1'b0}};
        dma_write_status_error_reg <= 4'b0000;
        dma_write_status_valid_reg <= 1'b0;

        scratch_reg <= {REG_DATA_WIDTH{1'b0}};
    end
end

// -----------------------------------------------------------------------------
//                      DMA RAM read interface handling
// -----------------------------------------------------------------------------

reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] commit_mem_reg = 0;
reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] dma_ram_rd_resp_data_reg = 0;
reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] dma_ram_rd_resp_data_next = 0;

reg [RAM_SEG_COUNT-1:0] dma_ram_rd_resp_valid_reg = 0;
reg [RAM_SEG_COUNT-1:0] dma_ram_rd_resp_valid_next = 0;

assign dma_ram_rd_cmd_ready = dma_ram_rd_resp_ready | ~dma_ram_rd_resp_valid_reg; // Ready if not currently processing a command or if the current response is valid
assign dma_ram_rd_resp_data = dma_ram_rd_resp_data_reg;
assign dma_ram_rd_resp_valid = dma_ram_rd_resp_valid_reg;

integer i;

always @(*) begin
   dma_ram_rd_resp_data_next = dma_ram_rd_resp_data_reg; // Default to retaining current response data
   dma_ram_rd_resp_valid_next = dma_ram_rd_resp_valid_reg; // Default to retaining

   for (i = 0; i < RAM_SEG_COUNT; i = i + 1) begin
       if (dma_ram_rd_resp_valid_reg[i] && dma_ram_rd_resp_ready[i]) begin
           // Clear valid bit when response is accepted
           dma_ram_rd_resp_valid_next[i] = 1'b0;
       end

       if (dma_ram_rd_cmd_valid[i] && dma_ram_rd_cmd_ready[i]) begin
           // Prepare response data based on the command address
           dma_ram_rd_resp_data_next[RAM_SEG_DATA_WIDTH*i +: RAM_SEG_DATA_WIDTH] = commit_mem_reg[RAM_SEG_DATA_WIDTH*i +: RAM_SEG_DATA_WIDTH];
           dma_ram_rd_resp_valid_next[i] = 1'b1; // Set valid to indicate a new response is ready
       end
   end
end

always @(posedge clk) begin
    dma_ram_rd_resp_data_reg <= dma_ram_rd_resp_data_next;
    dma_ram_rd_resp_valid_reg <= dma_ram_rd_resp_valid_next;
    commit_mem_reg <= commit_mem_reg; // Retain current values unless updated by read commands

    if (rst) begin
        commit_mem_reg <= {
            32'hdead_000f, 32'hdead_000e, 32'hdead_000d, 32'hdead_000c,
            32'hdead_000b, 32'hdead_000a, 32'hdead_0009, 32'hdead_0008,
            32'hdead_0007, 32'hdead_0006, 32'hdead_0005, 32'hdead_0004,
            32'hdead_0003, 32'hdead_0002, 32'hdead_0001, 32'hdead_0000
        };

        dma_ram_rd_resp_data_reg <= 0;
        dma_ram_rd_resp_valid_reg <= 0;
    end
end

endmodule
