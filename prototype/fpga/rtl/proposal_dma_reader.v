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
    input  wire                                     tail_slot_valid,
    input  wire [RAM_ADDR_WIDTH-1:0]                tail_slot_addr,
    output wire                                     tail_slot_commit
);

// =========================================================================
//                  Register for Output Control and Status
// =========================================================================
// Register Map:
// --- Read-only Identification and configuration registers
// - 0x000: MAGIC           [0x70717565/proq]   - Magic value to identify the proposal queue
// - 0x004: VERSION         [0x00010000/1.0]    - Version number of the proposal queue implementation 
// - 0x008: FEATURES        [0x00000001]        - Bitfield of supported features 
// - 0x00C: SLOT_BYTES      [0x00000400/1024] - Size of each proposal slot in bytes 
//
// --- Control and status registers
// - 0x010: CONTROL             [0x00000000]        - Control register for the proposal queue (reserved for future use)
// - 0x014: STATUS              [0x00000000]        - Status register for the proposal queue
// - 0x018: ENTRY_COUNTER_LO    [0x00000000]        - Lower 32 bits of the proposal entry counter
// - 0x01C: ENTRY_COUNTER_HI    [0x00000000]        - Upper 32 bits of the proposal entry counter
//
// -- DMA descriptor registers
// - 0x100: DMA_ADDR_LO          - Lower 32 bits of base address for proposal batch DMA
// - 0x104: DMA_ADDR_HI          - Upper 32 bits of base address for proposal batch DMA
// - 0x108: DMA_LEN              - Length of each proposal entry in bytes
// - 0x10C: DMA_STRIDE_LO       - Lower 32 bits of stride between proposal entries
// - 0x110: DMA_STRIDE_HI       - Upper 32 bits of stride between proposal entries
// - 0x114: DMA_COUNT            - Number of proposal entries to fetch in the batch
// - 0x118: DMA_CONTROL           - Control register for starting/stopping the proposal batch DMA
//      bit 0: start
//      bit 1: clear done
//      bit 2: clear error
// - 0x11C: DMA_STATUS            - Status register for the proposal batch DMA
//      bit 0: running
//      bit 1: done
//      bit 2: error
// - 0x120: DMA_ACTIVE_INDEX      - Index of the currently active proposal entry in the batch
// - 0x124: DMA_STATE             - Current state of the proposal batch DMA operation
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
// --- Identification and configuration registers
localparam REG_MAGIC            = RBB + 12'h000;
localparam REG_VERSION          = RBB + 12'h004;
localparam REG_FEATURES         = RBB + 12'h008;
localparam REG_SLOT_BYTES       = RBB + 12'h00C;

// --- Control and status registers
localparam REG_CONTROL          = RBB + 12'h010;
localparam REG_STATUS           = RBB + 12'h014;
localparam REG_ENTRY_COUNTER_LO = RBB + 12'h018;
localparam REG_ENTRY_COUNTER_HI = RBB + 12'h01C;

// --- DMA descriptor registers
localparam REG_DMA_ADDR_LO      = RBB + 12'h100;
localparam REG_DMA_ADDR_HI      = RBB + 12'h104;
localparam REG_DMA_LEN          = RBB + 12'h108;
localparam REG_DMA_STRIDE_LO    = RBB + 12'h10C;
localparam REG_DMA_STRIDE_HI    = RBB + 12'h110;
localparam REG_DMA_COUNT        = RBB + 12'h114;
localparam REG_DMA_CONTROL      = RBB + 12'h118;
localparam REG_DMA_STATUS       = RBB + 12'h11C;
localparam REG_DMA_ACTIVE_INDEX = RBB + 12'h120;
localparam REG_DMA_STATE        = RBB + 12'h124;
localparam REG_DMA_STATUS_TAG     = RBB + 12'h128;
localparam REG_DMA_STATUS_ERROR   = RBB + 12'h12C;
localparam REG_DMA_STATUS_VALID   = RBB + 12'h130;

// state machine states
localparam [2:0]
    STATE_IDLE  = 3'd0,
    STATE_ISSUE_DMA = 3'd1,
    STATE_WAIT_DMA = 3'd2,
    STATE_COMMIT_SLOT = 3'd3,
    STATE_ERROR = 3'd5;

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

reg     tail_slot_commit_reg = 1'b0, tail_slot_commit_next;

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
    tail_slot_commit_next = 1'b0;

    // ----------------------------------------------------------
    //       Control and status register read/write handling
    // ----------------------------------------------------------
    if (reg_wr_en && !reg_wr_ack_reg) begin
        // write operation
        reg_wr_ack_next = 1'b1; // acknowledge the write
        case ({reg_wr_addr[REG_ADDR_WIDTH-1:2], 2'b00}) // align address to 4 bytes
            // Header registers (read-only)
            REG_MAGIC: ; // read-only
            REG_VERSION: ; // read-only
            REG_FEATURES: ; // read-only
            REG_SLOT_BYTES: ; // read-only

            // Control and status registers
            REG_CONTROL: ; // reserved, writes ignored
            REG_STATUS: ; // read-only
            REG_ENTRY_COUNTER_LO: ; // read-only
            REG_ENTRY_COUNTER_HI: ; // read-only

            // DMA descriptor registers
            REG_DMA_ADDR_LO: prop_batch_base_addr_next[31:0] = reg_wr_data;
            REG_DMA_ADDR_HI: prop_batch_base_addr_next[63:32] = reg_wr_data;
            REG_DMA_LEN: ; // fixed slot length in v1, writes ignored
            REG_DMA_STRIDE_LO: prop_batch_stride_next[31:0] = reg_wr_data;
            REG_DMA_STRIDE_HI: prop_batch_stride_next[63:32] = reg_wr_data;
            REG_DMA_COUNT: prop_batch_count_next = reg_wr_data;
            REG_DMA_CONTROL: begin
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
            REG_DMA_STATUS: ; // read-only
            REG_DMA_ACTIVE_INDEX: ; // read-only
            REG_DMA_STATE: ; // read-only
            
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
            REG_SLOT_BYTES: reg_rd_data_next = PROPOSAL_SLOT_BYTES_LEN; // size of each proposal slot in bytes

            REG_CONTROL: reg_rd_data_next = 32'h00000000; // control register (reserved, returns 0)
            REG_STATUS: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, prop_batch_error_reg, prop_batch_done_reg, prop_batch_run_reg}; // status register
            REG_ENTRY_COUNTER_LO: reg_rd_data_next = proposal_entry_counter_reg[31:0];
            REG_ENTRY_COUNTER_HI: reg_rd_data_next = 32'h0; //TODO: Implement high word read

            // DMA descriptor registers
            REG_DMA_ADDR_LO: reg_rd_data_next = prop_batch_base_addr_reg[31:0];
            REG_DMA_ADDR_HI: reg_rd_data_next = prop_batch_base_addr_reg[63:32];
            REG_DMA_LEN: reg_rd_data_next = {{(REG_DATA_WIDTH - DMA_LEN_WIDTH){1'b0}}, PROPOSAL_SLOT_BYTES_LEN}; // fixed slot length in v1
            REG_DMA_STRIDE_LO: reg_rd_data_next = prop_batch_stride_reg[31:0];
            REG_DMA_STRIDE_HI: reg_rd_data_next = prop_batch_stride_reg[63:32];
            REG_DMA_COUNT: reg_rd_data_next = prop_batch_count_reg;

            REG_DMA_CONTROL: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, prop_batch_error_reg, prop_batch_done_reg, prop_batch_run_reg};
            REG_DMA_STATUS: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, prop_batch_error_reg, prop_batch_done_reg, prop_batch_run_reg};
            REG_DMA_ACTIVE_INDEX: reg_rd_data_next = prop_batch_active_index_reg;
            REG_DMA_STATE: reg_rd_data_next = {{(REG_DATA_WIDTH - 3){1'b0}}, state_reg};
            
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
                    // invalid batch count, stay in idle state and clear the run flag
                    prop_batch_run_next = 1'b0;
                    prop_batch_done_next = 1'b1;
                    state_next = STATE_IDLE;
                end
            end
        end

        // Issue DMA read descriptor for the current proposal entry
        STATE_ISSUE_DMA: begin
            // !tail_slot_commit_reg is load-bearing. STATE_COMMIT_SLOT sets both
            // tail_slot_commit_next and state_next=STATE_ISSUE_DMA, so they take
            // effect on the SAME edge: the cycle we first arrive here is the
            // cycle our own commit pulse is being presented to proposal_buffer,
            // and its tail_ptr_reg has not moved yet. Sampling tail_slot_addr
            // then aims the next descriptor at the slot we just committed, and
            // the DMA overwrites a proposal that is already queued to transmit.
            // Waiting one cycle lets the buffer retire the commit first.
            if (tail_slot_valid && !tail_slot_commit_reg &&
                (!dma_read_desc_valid_reg || m_axis_dma_read_desc_ready)) 
            begin
                dma_read_desc_dma_addr_next = prop_batch_base_addr_reg + prop_batch_offset_reg;
                dma_read_desc_ram_addr_next = tail_slot_addr;
                dma_read_desc_len_next      = PROPOSAL_SLOT_BYTES_LEN;
                dma_read_desc_tag_next      = DMA_TAG_PROP_VALUE + prop_batch_active_index_reg[DMA_TAG_WIDTH-1:0];
                dma_read_desc_valid_next    = 1'b1;

                state_next = STATE_WAIT_DMA;
            end else begin
                // Wait for a valid tail slot from proposal_buffer
                dma_read_desc_valid_next = 1'b0;
                state_next = STATE_ISSUE_DMA;
            end
        end

        // Wait for DMA read completion status
        STATE_WAIT_DMA: begin
            if (dma_read_status_match) begin
                dma_read_desc_status_tag_next   = s_axis_dma_read_desc_status_tag;
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
                    state_next = STATE_ERROR; // something went wrong, go to error state
                end
            end
        end

        // Commit the slot in proposal_buffer after successful DMA completion
        STATE_COMMIT_SLOT: begin
            tail_slot_commit_next       = 1'b1; // signal to commit the tail slot

            proposal_entry_counter_next = proposal_entry_counter_reg + 1'b1;
            prop_batch_offset_next      = prop_batch_offset_reg + prop_batch_stride_reg;
            prop_batch_active_index_next = prop_batch_active_index_reg + 1'b1;
            prop_batch_count_next       = prop_batch_count_reg - 1'b1;

            if (prop_batch_count_reg == 1) begin
                // Last proposal entry in the batch
                prop_batch_run_next     = 1'b0;
                prop_batch_done_next    = 1'b1;

                state_next = STATE_IDLE;
            end else begin
                // More proposal entries to fetch
                state_next = STATE_ISSUE_DMA;
            end
        end

        STATE_ERROR: begin
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

    tail_slot_commit_reg <= tail_slot_commit_next;

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

        tail_slot_commit_reg <= 1'b0;
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

assign tail_slot_commit = tail_slot_commit_reg;

endmodule

`resetall
