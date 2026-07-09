`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 *
 * Proposal DMA reader
 *
 * Responsibilities:
 *   1. Receive host proposal batch configuration through CSR.
 *   2. Obtain the current writable tail slot from proposal_buffer.
 *   3. Issue DMA read descriptors:
 *       Host memory -> proposal_buffer RAM.
 *   4. Wait for DMA read completion status.
 *   5. Commit the completed tail slot in proposal_buffer.
 *
 * This module does not handle DMA RAM write data directly.
 * porposal_buffer is the DMA RAM write endpoint.
 */


module proposal_dma_reader #
(   
    // AXI-Lite interface configuration for control/status registers
    parameter REG_ADDR_WIDTH = 12,
    parameter REG_DATA_WIDTH = 32,
    parameter REG_STRB_WIDTH = REG_DATA_WIDTH / 8,
    parameter RB_BASE_ADDR = 32'h0000_0000,

    // DMA descriptor interface configuration
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,

    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 16,

    parameter RAM_SEL_PROP = 0,
    parameter DMA_TAG_PROP = 0,

    parameter PROPOSAL_SLOT_BYTES = 1024
)
(
    input  wire                                     clk,
    input  wire                                     rst,

    // Register interface
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

    // Tail slot interface from proposal_buffer
    input  wire                                             tail_slot_valid,
    input  wire [RAM_ADDR_WIDTH-1:0]                        tail_slot_addr,
    input  wire [DMA_LEN_WIDTH-1:0]                         tail_slot_len,

    // Slot commit interface to proposal_buffer
    output wire                                             commit_valid,
    input  wire                                             commit_ready
);

// =========================================================================
//                  Register for Output Control and Status
// =========================================================================
// Register Map:
// - 0x000: MAGIC           [0x70717565/proq]   - Magic value to identify the proposal queue
// - 0x004: VERSION         [0x00010000/1.0]    - Version number of the proposal queue implementation (not implemented in this example, always returns 1.0)
// - 0x008: FEATURES        [0x00000001]        - Bitfield of supported features (not implemented in this example, always returns 1 to indicate basic functionality)
// - 0x00C: CONTROL         
// - 0x010: STATUS
// - 0x014: SCRATCH
// - 0x018: ENTRY_COUNTER
//
// - 0x100: BATCH_ADDR_LO          - Lower 32 bits of base address for proposal batch DMA
// - 0x104: BATCH_ADDR_HI          - Upper 32 bits of base address for proposal batch DMA
// - 0x108: BATCH_LEN              - Length of each proposal entry in bytes
// - 0x10C: BATCH_STRIDE_LO       - Lower 32 bits of stride between proposal entries
// - 0x110: BATCH_STRIDE_HI       - Upper 32 bits of stride between proposal entries
// - 0x114: BATCH_COUNT            - Number of proposal entries to fetch in the batch
// - 0x118: BATCH_CONTROL           - Control register for starting/stopping the proposal batch DMA
//      bit 0: start
//      bit 1: clear done
//      bit 2: clear error
// - 0x11C: BATCH_STATUS            - Status register for the proposal batch DMA
//      bit 0: running
//      bit 1: done
//      bit 2: error
// - 0x120: BATCH_ACTIVE_INDEX      - Index of the currently active proposal entry in the batch
// - 0x124: BATCH_STATE             - Current state of the proposal batch DMA operation
// - 0x128: DMA_STATUS_TAG              - Tag of the last completed DMA read descriptor
// - 0x12C: DMA_STATUS_ERROR            - Error code of the last completed DMA read descriptor
// - 0x130: DMA_STATUS_VALID            - Valid flag for the last completed DMA read descriptor

localparam integer DMA_LEN_LIMIT = 1 << 20;

localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_PROP_VALUE = DMA_TAG_PROP;
localparam [RAM_SEL_WIDTH-1:0] RAM_SEL_PROP_VALUE = RAM_SEL_PROP;
localparam [DMA_LEN_WIDTH-1:0] PROPOSAL_SLOT_BYTES_LEN = PROPOSAL_SLOT_BYTES;

// Configuration checks
initial begin
    if (PROPOSAL_SLOT_BYTES > DMA_LEN_LIMIT) begin
        $error("PROPOSAL_SLOT_BYTES (%0d) exceeds DMA_LEN_LIMIT (%0d)", PROPOSAL_SLOT_BYTES, DMA_LEN_LIMIT);
        $finish;
    end

    if (PROPOSAL_SLOT_BYTES & (PROPOSAL_SLOT_BYTES - 1)) begin
        $error("PROPOSAL_SLOT_BYTES (%0d) is not a power of 2", PROPOSAL_SLOT_BYTES);
        $finish;
    end
end

// =========================================================================
//                  Internal signals and registers
// =========================================================================
localparam integer RBB = RB_BASE_ADDR;
// global
localparam REG_MAGIC            = RBB + 12'h000;
localparam REG_VERSION          = RBB + 12'h004;
localparam REG_FEATURES         = RBB + 12'h008;
localparam REG_CONTROL          = RBB + 12'h00C;
localparam REG_STATUS           = RBB + 12'h010;
localparam REG_SCRATCH          = RBB + 12'h014;
localparam REG_ENTRY_COUNTER    = RBB + 12'h018;
// DMA descriptor registers
localparam REG_BATCH_BASE_ADDR_LO      = RBB + 12'h100;
localparam REG_BATCH_BASE_ADDR_HI      = RBB + 12'h104;
localparam REG_BATCH_SLOT_LEN          = RBB + 12'h108;
localparam REG_BATCH_STRIDE_LO    = RBB + 12'h10C;
localparam REG_BATCH_STRIDE_HI    = RBB + 12'h110;
localparam REG_BATCH_COUNT        = RBB + 12'h114;
localparam REG_BATCH_CONTROL      = RBB + 12'h118;
localparam REG_BATCH_STATUS       = RBB + 12'h11C;
localparam REG_BATCH_ACTIVE_INDEX = RBB + 12'h120;
localparam REG_BATCH_STATE        = RBB + 12'h124;
localparam REG_DMA_STATUS_TAG     = RBB + 12'h128;
localparam REG_DMA_STATUS_ERROR   = RBB + 12'h12C;
localparam REG_DMA_STATUS_VALID   = RBB + 12'h130;

localparam [2:0]
    STATE_IDLE  = 3'd0,
    STATE_ISSUE_DMA = 3'd1,
    STATE_WAIT_DMA = 3'd2,
    STATE_COMMIT_SLOT = 3'd3,
    STATE_DONE = 3'd4;

reg [2:0] state_reg = STATE_IDLE, state_next;

// CSR register state
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

reg [REG_DATA_WIDTH-1:0]    scratch_reg = {REG_DATA_WIDTH{1'b0}}, scratch_reg_next; // scratch register for testing read/write access
reg [REG_DATA_WIDTH-1:0]    proposal_entry_counter_reg = 0, proposal_entry_counter_next;

reg                         prop_batch_run_reg = 1'b0, prop_batch_run_next;
reg                         prop_batch_done_reg = 1'b0, prop_batch_done_next;
reg                         prop_batch_error_reg = 1'b0, prop_batch_error_next;
reg [DMA_ADDR_WIDTH-1:0]    prop_batch_base_addr_reg = 0, prop_batch_base_addr_next;
reg [DMA_ADDR_WIDTH-1:0]    prop_batch_offset_reg = 0, prop_batch_offset_next;
reg [DMA_ADDR_WIDTH-1:0]    prop_batch_stride_reg = 0, prop_batch_stride_next;
//reg [DMA_LEN_WIDTH-1:0]     prop_batch_len_reg = 0, prop_batch_len_next;
reg [31:0]                  prop_batch_count_reg = 0, prop_batch_count_next;
reg [31:0]                  prop_batch_active_index_reg = 0, prop_batch_active_index_next;

assign commit_valid = (state_reg == STATE_COMMIT_SLOT);

wire dma_read_status_match = s_axis_dma_read_desc_status_valid && (s_axis_dma_read_desc_status_tag == dma_read_desc_tag_reg);

// =========================================================================
//                  DMA Reader State Machine
// =========================================================================
always @* begin
    state_next = state_reg;

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

    prop_batch_run_next = prop_batch_run_reg;
    prop_batch_done_next = prop_batch_done_reg;
    prop_batch_error_next = prop_batch_error_reg;

    prop_batch_base_addr_next = prop_batch_base_addr_reg;
    prop_batch_offset_next = prop_batch_offset_reg;
    prop_batch_stride_next = prop_batch_stride_reg;
    //prop_batch_len_next = prop_batch_len_reg;
    prop_batch_count_next = prop_batch_count_reg;
    prop_batch_active_index_next = prop_batch_active_index_reg;
    
    scratch_reg_next = scratch_reg;
    proposal_entry_counter_next = proposal_entry_counter_reg;

    // ----------------------------------------------------------
    //       Control and status register read/write handling
    // ----------------------------------------------------------
    if (reg_wr_en && !reg_wr_ack_reg) begin
        // write operation
        reg_wr_ack_next = 1'b1; // acknowledge the write
        case ({reg_wr_addr[REG_ADDR_WIDTH-1:2], 2'b00}) // align address to 4 bytes
            // Header registers (read-only)
            REG_MAGIC: ; // PROP_FETCH_MAGIC is read-only
            REG_VERSION: ; // PROP_FETCH_VERSION is read-only
            REG_FEATURES: ; // PROP_FETCH_FEATURES is read-only
            REG_CONTROL: ; // PROP_FETCH_CTRL is reserved for future use
            REG_STATUS: ; // PROP_FETCH_STATUS is reserved for future use
            REG_SCRATCH: scratch_reg_next = reg_wr_data; // Write to scratch register for testing
            REG_ENTRY_COUNTER: ; // PROP_FETCH_PROPOSAL_ENTRY_COUNTER is read-only

            // DMA descriptor registers
            REG_BATCH_BASE_ADDR_LO: begin
                if (!prop_batch_run_reg && state_reg == STATE_IDLE) begin
                    prop_batch_base_addr_next[31:0] = reg_wr_data;
                end
            end
            REG_BATCH_BASE_ADDR_HI: begin
                if (!prop_batch_run_reg && state_reg == STATE_IDLE) begin
                    prop_batch_base_addr_next[63:32] = reg_wr_data;
                end
            end
            REG_BATCH_SLOT_LEN: ; // fixed slot length in v1, writes ignored
            REG_BATCH_STRIDE_LO: begin
                if (!prop_batch_run_reg && state_reg == STATE_IDLE) begin
                    prop_batch_stride_next[31:0] = reg_wr_data;
                end
            end
            REG_BATCH_STRIDE_HI: begin
                if (!prop_batch_run_reg && state_reg == STATE_IDLE) begin
                    prop_batch_stride_next[63:32] = reg_wr_data;
                end
            end
            REG_BATCH_COUNT: begin
                if (!prop_batch_run_reg && state_reg == STATE_IDLE) begin
                    prop_batch_count_next = reg_wr_data;
                end
            end
            REG_BATCH_CONTROL: begin
                // bit 0: start
                if (reg_wr_data[0]) begin
                    if (!prop_batch_run_reg && state_reg == STATE_IDLE) begin
                        // start a new proposal batch DMA operation
                        prop_batch_run_next = 1'b1;
                        prop_batch_done_next = 1'b0;
                        prop_batch_error_next = 1'b0;

                        // Initialize runtime state for a new batch
                        prop_batch_offset_next = {DMA_ADDR_WIDTH{1'b0}};
                        prop_batch_active_index_next = 32'd0;

                        // Clear old DMA status
                        dma_read_desc_status_tag_next = {DMA_TAG_WIDTH{1'b0}};
                        dma_read_desc_status_error_next = 4'b0000;
                        dma_read_desc_status_valid_next = 1'b0;
                    end
                end

                // bit 1: clear done
                if (reg_wr_data[1]) begin
                    prop_batch_done_next = 1'b0;
                end

                // bit 2: clear error
                if (reg_wr_data[2]) begin
                    prop_batch_error_next = 1'b0;
                end
            end
            REG_BATCH_STATUS: ; // read-only
            REG_BATCH_ACTIVE_INDEX: ; // read-only
            REG_BATCH_STATE: ; // read-only
            
            REG_DMA_STATUS_TAG: ; // read-only
            REG_DMA_STATUS_ERROR: ; // read-only
            REG_DMA_STATUS_VALID: ; // read-only

            default: begin
                reg_wr_ack_next = 1'b0;
            end
        endcase
    end

    if (reg_rd_en && !reg_rd_ack_reg) begin
        // read operation - decode address and return data
        reg_rd_ack_next = 1'b1; // acknowledge the read
        case ({reg_rd_addr[REG_ADDR_WIDTH-1:2], 2'b00}) // align address to 4 bytes
            REG_MAGIC: reg_rd_data_next = 32'h70726f71; // "proq"
            REG_VERSION: reg_rd_data_next = 32'h00000100; // version 1.0
            REG_FEATURES: reg_rd_data_next = 32'h00000001; // features (bit 0: basic functionality)
            REG_CONTROL: reg_rd_data_next = 32'h00000000; // control register (reserved, returns 0)
            REG_STATUS: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, prop_batch_error_reg, prop_batch_done_reg, prop_batch_run_reg}; // status register
            REG_SCRATCH: reg_rd_data_next = scratch_reg; // read from scratch register for testing
            REG_ENTRY_COUNTER: reg_rd_data_next = proposal_entry_counter_reg; // read from proposal entry counter

            // DMA descriptor registers
            REG_BATCH_BASE_ADDR_LO: reg_rd_data_next = prop_batch_base_addr_reg[31:0];
            REG_BATCH_BASE_ADDR_HI: reg_rd_data_next = prop_batch_base_addr_reg[63:32];
            REG_BATCH_SLOT_LEN: reg_rd_data_next = {{(REG_DATA_WIDTH - DMA_LEN_WIDTH){1'b0}}, PROPOSAL_SLOT_BYTES_LEN}; // fixed slot length in v1
            REG_BATCH_STRIDE_LO: reg_rd_data_next = prop_batch_stride_reg[31:0];
            REG_BATCH_STRIDE_HI: reg_rd_data_next = prop_batch_stride_reg[63:32];
            REG_BATCH_COUNT: reg_rd_data_next = prop_batch_count_reg;

            REG_BATCH_CONTROL: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, prop_batch_error_reg, prop_batch_done_reg, prop_batch_run_reg};
            REG_BATCH_STATUS: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, prop_batch_error_reg, prop_batch_done_reg, prop_batch_run_reg};
            REG_BATCH_ACTIVE_INDEX: reg_rd_data_next = prop_batch_active_index_reg;
            REG_BATCH_STATE: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, state_reg};
            
            REG_DMA_STATUS_TAG: reg_rd_data_next = {{(REG_DATA_WIDTH - DMA_TAG_WIDTH){1'b0}}, dma_read_desc_status_tag_reg};
            REG_DMA_STATUS_ERROR: reg_rd_data_next = {{(REG_DATA_WIDTH - 4){1'b0}}, dma_read_desc_status_error_reg};
            REG_DMA_STATUS_VALID: reg_rd_data_next = {{(REG_DATA_WIDTH - 1){1'b0}}, dma_read_desc_status_valid_reg};
            default: begin
                reg_rd_ack_next = 1'b0;
                reg_rd_data_next = {REG_DATA_WIDTH{1'b0}};
            end
        endcase
    end

    // ----------------------------------------------------------
    //                          State machine
    // ----------------------------------------------------------
    case (state_reg)
        // Wait for a new proposal batch DMA operation to start
        STATE_IDLE: begin
            if (prop_batch_run_reg) begin
                if (prop_batch_count_reg != 0) begin
                    state_next = STATE_ISSUE_DMA;
                end else begin
                    prop_batch_run_next = 1'b0;
                    prop_batch_done_next = 1'b1;
                    state_next = STATE_DONE;
                end
            end
        end

        // Issue DMA read descriptor for the current proposal entry
        STATE_ISSUE_DMA: begin
            if (tail_slot_valid &&
                tail_slot_len != {DMA_LEN_WIDTH{1'b0}} &&
                (!dma_read_desc_valid_reg || m_axis_dma_read_desc_ready)) begin
            
            dma_read_desc_dma_addr_next = prop_batch_base_addr_reg + prop_batch_offset_reg;
            dma_read_desc_ram_addr_next = tail_slot_addr;
            dma_read_desc_len_next = tail_slot_len;
            dma_read_desc_tag_next = DMA_TAG_PROP_VALUE + prop_batch_active_index_reg[DMA_TAG_WIDTH-1:0];
            dma_read_desc_valid_next = 1'b1;

            state_next = STATE_WAIT_DMA;
            end
        end

        // Wait for DMA read completion status
        STATE_WAIT_DMA: begin
            if (dma_read_status_match) begin
                dma_read_desc_status_tag_next = s_axis_dma_read_desc_status_tag;
                dma_read_desc_status_error_next = s_axis_dma_read_desc_status_error;
                dma_read_desc_status_valid_next = 1'b1;

                if (s_axis_dma_read_desc_status_error == 4'd0) begin
                    // DMA read completed successfully
                    state_next = STATE_COMMIT_SLOT;
                end else begin
                    // DMA read completed with error
                    prop_batch_run_next = 1'b0;
                    prop_batch_done_next = 1'b1;
                    prop_batch_error_next = 1'b1;
                    state_next = STATE_DONE;
                end
            end
        end

        // Commit the slot in proposal_buffer after successful DMA completion
        STATE_COMMIT_SLOT: begin
            if (commit_ready) begin
                proposal_entry_counter_next = proposal_entry_counter_reg + 1'b1;
                prop_batch_offset_next = prop_batch_offset_reg + prop_batch_stride_reg;
                prop_batch_active_index_next = prop_batch_active_index_reg + 1'b1;
                prop_batch_count_next = prop_batch_count_reg - 1'b1;

                if (prop_batch_count_reg == 1) begin
                    // Last proposal entry in the batch
                    prop_batch_run_next = 1'b0;
                    prop_batch_done_next = 1'b1;
                    state_next = STATE_DONE;
                end else begin
                    // More proposal entries to fetch
                    state_next = STATE_ISSUE_DMA;
                end
            end
        end

        // Batch operation completed (either successfully or with error)
        STATE_DONE: begin
            state_next = STATE_IDLE;
        end

        default: begin
            state_next = STATE_IDLE;
        end
    endcase
end

// -------------------------------------------------------------------------
// Sequential logic
// -------------------------------------------------------------------------
always @(posedge clk) begin
    state_reg <= state_next;

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
    scratch_reg <= scratch_reg_next; // hold the value of the scratch register

    prop_batch_run_reg <= prop_batch_run_next;
    prop_batch_done_reg <= prop_batch_done_next;
    prop_batch_error_reg <= prop_batch_error_next;

    prop_batch_base_addr_reg <= prop_batch_base_addr_next;
    prop_batch_offset_reg <= prop_batch_offset_next;
    prop_batch_stride_reg <= prop_batch_stride_next;
    //prop_batch_len_reg <= prop_batch_len_next;
    prop_batch_count_reg <= prop_batch_count_next;
    prop_batch_active_index_reg <= prop_batch_active_index_next;

    if (rst) begin
        state_reg <= STATE_IDLE;

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
        scratch_reg <= {REG_DATA_WIDTH{1'b0}};

        prop_batch_run_reg <= 1'b0;
        prop_batch_done_reg <= 1'b0;
        prop_batch_error_reg <= 1'b0;

        prop_batch_base_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        prop_batch_offset_reg <= {DMA_ADDR_WIDTH{1'b0}};
        prop_batch_stride_reg <= {DMA_ADDR_WIDTH{1'b0}};
        //prop_batch_len_reg <= {DMA_LEN_WIDTH{1'b0}};
        prop_batch_count_reg <= 32'b0;
        prop_batch_active_index_reg <= 32'b0;
    end
end

// =========================================================================
//                  Output assignments
// =========================================================================
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

endmodule

`resetall
