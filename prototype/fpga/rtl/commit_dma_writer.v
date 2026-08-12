`resetall
`timescale 1ns /1ps
`default_nettype none

/*
 * Commit DMA writer
 *
 * Role:
 *   - Read host destination base/stride/count from CSR.
 *   - Wait for a valid head slot from commit_buf.
 *   - Issue DMA write descriptor:
 *        FPGA commit_buf RAM -> Host memory
 *   - Wait for DMA write completion.
 *   - Pop commit_buf head slot after successful completion.
 *
 * Host software contract:
 *   - Configure base address, stride, and capacity before arming.
 *   - Do not modify an active buffer while it is being written.
 *   - Do not clear or re-arm an active buffer.
 *   - CSR writes are aligned full-width 32-bit writes.
 *
 * This module does not handle RAM read data directly.
 * commit_buf is the DAM RAM read endpoint
 */

module commit_dma_writer #
(
    parameter REG_ADDR_WIDTH = 24,
    parameter REG_DATA_WIDTH = 32,
    parameter REG_STRB_WIDTH = (REG_DATA_WIDTH/8),
    parameter RB_BASE_ADDR = 0,

    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_IMM_ENABLE = 0,
    parameter DMA_IMM_WIDTH = 32,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,

    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 16,

    parameter RAM_SEL_COMMIT = 1,
    parameter DMA_TAG_COMMIT = 0
)
(
    input  wire                                            clk,
    input  wire                                            rst,

    // CSR interface
    input  wire [REG_ADDR_WIDTH-1:0]                        reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]                        reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]                        reg_wr_strb,
    input  wire                                             reg_wr_en,
    output wire                                             reg_wr_wait,
    output wire                                             reg_wr_ack,

    input  wire [REG_ADDR_WIDTH-1:0]                        reg_rd_addr,
    input  wire                                             reg_rd_en,
    output wire [REG_DATA_WIDTH-1:0]                        reg_rd_data,
    output wire                                             reg_rd_wait,
    output wire                                             reg_rd_ack,

    // DMA write descriptor output 
    output wire [DMA_ADDR_WIDTH-1:0]                        m_axis_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                         m_axis_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                        m_axis_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                         m_axis_dma_write_desc_imm,
    output wire                                             m_axis_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                         m_axis_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                         m_axis_dma_write_desc_tag,
    output wire                                             m_axis_dma_write_desc_valid,
    input  wire                                             m_axis_dma_write_desc_ready,

    // DMA write descriptor status input
    input  wire [DMA_TAG_WIDTH-1:0]                         s_axis_dma_write_desc_status_tag,
    input  wire [3:0]                                       s_axis_dma_write_desc_status_error,
    input  wire                                             s_axis_dma_write_desc_status_valid,

    // Head slot interface from commit_buf
    input  wire                                             head_slot_valid,
    input  wire [RAM_ADDR_WIDTH-1:0]                        head_slot_addr,
    input  wire [DMA_LEN_WIDTH-1:0]                         head_slot_len,

    output wire                                             head_slot_pop_valid,
    input  wire                                             head_slot_pop_ready
);
// ======================================================================
// Register map
// ======================================================================
//
// Global configuration/status
//  - 0x000: COMMIT_STRIDE_LO       RW
//  - 0x004: COMMIT_STRIDE_HI       RW
//  - 0x008: COMMIT_GLOBAL_CONTROL  WO
//           bit 0: start
//           bit 1: stop
//  - 0x00C: COMMIT_GLOBAL_STATUS   RO
//           bit 0: busy
//           bit 1: waiting for commit slot
//           bit 2: waiting for armed buf
//  - 0x010: COMMIT_ACTIVE_BUFFER   RO
//           bit 0: current active buffer (0 or 1)
//
//  Buffer 0
//  - 0x100: COMMIT_BUF0_ADDR_LO        RW
//  - 0x104: COMMIT_BUF0_ADDR_HI        RW
//  - 0x108: COMMIT_BUF0_SLOT_CAPACITY  RW
//  - 0x12C: COMMIT_BUF0_CONTROL        WO
//           bit 0: arm
//           bit 1: clear status
//  - 0x130: COMMIT_BUF0_STATUS         RO
//           bit 0: armed
//           bit 1: done
//           bit 2: error
//  - 0x134: COMMIT_BUF0_COMPLETED_COUNT    RO
//  - 0x138: COMMIT_BUF0_ERROR_COUNT        RO
//
//  Buffer 1
//  - 0x200: COMMIT_BUF1_ADDR_LO        RW
//  - 0x204: COMMIT_BUF1_ADDR_HI        RW
//  - 0x208: COMMIT_BUF1_SLOT_CAPACITY  RW
//  - 0x22C: COMMIT_BUF1_CONTROL        WO
//           bit 0: arm
//           bit 1: clear status
//  - 0x230: COMMIT_BUF1_STATUS         RO
//           bit 0: armed
//           bit 1: done
//           bit 2: error
//  - 0x234: COMMIT_BUF1_COMPLETED_COUNT    RO
//  - 0x238: COMMIT_BUF1_ERROR_COUNT        RO

// ======================================================================
//                      CSR write logic
// ======================================================================
// Global
localparam REG_COMMIT_MAGIC        = RB_BASE_ADDR + 24'h000000;
localparam REG_COMMIT_VERSION      = RB_BASE_ADDR + 24'h000004;
localparam REG_COMMIT_FEATURES     = RB_BASE_ADDR + 24'h000008;
localparam REG_COMMIT_CONTROL      = RB_BASE_ADDR + 24'h00000C;
localparam REG_COMMIT_STATUS       = RB_BASE_ADDR + 24'h000010;
localparam REG_COMMIT_STRIDE_LO     = RB_BASE_ADDR + 24'h000014;
localparam REG_COMMIT_STRIDE_HI     = RB_BASE_ADDR + 24'h000018;
localparam REG_COMMIT_ACTIVE_BUFFER = RB_BASE_ADDR + 24'h00001C;

// Buffer 0
localparam REG_BUF0_ADDR_LO        = RB_BASE_ADDR + 24'h000100;
localparam REG_BUF0_ADDR_HI        = RB_BASE_ADDR + 24'h000104;
localparam REG_BUF0_SLOT_CAPACITY  = RB_BASE_ADDR + 24'h000108;
localparam REG_BUF0_CONTROL        = RB_BASE_ADDR + 24'h00010C;
localparam REG_BUF0_STATUS         = RB_BASE_ADDR + 24'h000110;
localparam REG_BUF0_COMPLETED_COUNT = RB_BASE_ADDR + 24'h000114;
localparam REG_BUF0_ERROR_COUNT     = RB_BASE_ADDR + 24'h000118;

// Buffer 1
localparam REG_BUF1_ADDR_LO        = RB_BASE_ADDR + 24'h000200;
localparam REG_BUF1_ADDR_HI        = RB_BASE_ADDR + 24'h000204;
localparam REG_BUF1_SLOT_CAPACITY  = RB_BASE_ADDR + 24'h000208;
localparam REG_BUF1_CONTROL        = RB_BASE_ADDR + 24'h00020C;
localparam REG_BUF1_STATUS         = RB_BASE_ADDR + 24'h000210;
localparam REG_BUF1_COMPLETED_COUNT = RB_BASE_ADDR + 24'h000214;
localparam REG_BUF1_ERROR_COUNT     = RB_BASE_ADDR + 24'h000218;

reg reg_wr_ack_reg = 1'b0;
reg reg_rd_ack_reg = 1'b0;
reg [REG_DATA_WIDTH-1:0] reg_rd_data_reg = {REG_DATA_WIDTH{1'b0}};

reg [31:0] scratch_reg = 32'd0;
reg [31:0] error_reg = 32'd0;
reg [31:0] control_reg = 32'd0;

reg [DMA_ADDR_WIDTH-1:0] commit_stride_reg = {DMA_ADDR_WIDTH{1'b0}};
reg [DMA_ADDR_WIDTH-1:0] commit_buf0_addr_reg = {DMA_ADDR_WIDTH{1'b0}};
reg [DMA_ADDR_WIDTH-1:0] commit_buf1_addr_reg = {DMA_ADDR_WIDTH{1'b0}};
reg [31:0] commit_buf0_slot_capacity_reg = 32'd0;
reg [31:0] commit_buf1_slot_capacity_reg = 32'd0;

reg start_pulse_reg = 1'b0;
reg stop_pulse_reg = 1'b0;
reg buf0_arm_pulse_reg = 1'b0;
reg buf1_arm_pulse_reg = 1'b0;
reg buf0_clear_pulse_reg = 1'b0;
reg buf1_clear_pulse_reg = 1'b0;

// read only for CSR
reg busy_reg = 1'b0, busy_next;
reg active_buf_reg = 1'b0, active_buf_next;

reg waiting_slot_reg = 1'b0, waiting_slot_next;
reg waiting_armed_buf_reg = 1'b0, waiting_armed_buf_next;

reg stop_pending_reg = 1'b0, stop_pending_next;

// Buffer 0 runtime state
reg buf0_armed_reg = 1'b0, buf0_armed_next;
reg buf0_done_reg = 1'b0, buf0_done_next;
reg [31:0] buf0_completed_count_reg = 32'd0, buf0_completed_count_next;
reg [31:0] buf0_error_count_reg = 32'd0, buf0_error_count_next;

// Buffer 1 runtime state
reg buf1_armed_reg = 1'b0, buf1_armed_next;
reg buf1_done_reg = 1'b0, buf1_done_next;
reg [31:0] buf1_completed_count_reg = 32'd0, buf1_completed_count_next;
reg [31:0] buf1_error_count_reg = 32'd0, buf1_error_count_next;

// assistant signal
wire [31:0] commit_global_status_word = {
    29'd0,
    waiting_armed_buf_reg,  // bit 2
    waiting_slot_reg,       // bit 1
    busy_reg                // bit 0
};

wire [31:0] commit_buf0_status_word = {
    29'd0,
    buf0_error_count_reg != 32'd0, // bit 2
    buf0_done_reg,                 // bit 1
    buf0_armed_reg                 // bit 0
};

wire [31:0] commit_buf1_status_word = {
    29'd0,
    buf1_error_count_reg != 32'd0, // bit 2
    buf1_done_reg,                 // bit 1
    buf1_armed_reg                 // bit 0
};

// -----------------------------------------
//          CSR read/write logic
// -----------------------------------------
always @(posedge clk) begin
    reg_wr_ack_reg <= 1'b0;
    reg_rd_ack_reg <= 1'b0;
    reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};

    start_pulse_reg <= 1'b0;
    stop_pulse_reg <= 1'b0;

    buf0_arm_pulse_reg <= 1'b0;
    buf1_arm_pulse_reg <= 1'b0;
    buf0_clear_pulse_reg <= 1'b0;
    buf1_clear_pulse_reg <= 1'b0;

    // write logic
    if (reg_wr_en && !reg_wr_ack_reg) begin
        reg_wr_ack_reg <= 1'b1;

        case ({reg_wr_addr[REG_ADDR_WIDTH-1:2], 2'b00}) 
            // global
            REG_COMMIT_STRIDE_LO: commit_stride_reg[31:0] <= reg_wr_data[31:0];
            REG_COMMIT_STRIDE_HI: commit_stride_reg[63:32] <= reg_wr_data[31:0];
            REG_COMMIT_CONTROL: begin
                start_pulse_reg <= reg_wr_data[0];
                stop_pulse_reg <= reg_wr_data[1];
            end

            // buffer 0
            REG_BUF0_ADDR_LO: commit_buf0_addr_reg[31:0] <= reg_wr_data[31:0];
            REG_BUF0_ADDR_HI: commit_buf0_addr_reg[63:32] <= reg_wr_data[31:0];
            REG_BUF0_SLOT_CAPACITY: commit_buf0_slot_capacity_reg <= reg_wr_data[31:0];
            REG_BUF0_CONTROL: begin
                buf0_arm_pulse_reg <= reg_wr_data[0];
                buf0_clear_pulse_reg <= reg_wr_data[1];
            end

            // buffer 1
            REG_BUF1_ADDR_LO: commit_buf1_addr_reg[31:0] <= reg_wr_data[31:0];
            REG_BUF1_ADDR_HI: commit_buf1_addr_reg[63:32] <= reg_wr_data[31:0];
            REG_BUF1_SLOT_CAPACITY: commit_buf1_slot_capacity_reg <= reg_wr_data[31:0];
            REG_BUF1_CONTROL: begin
                buf1_arm_pulse_reg <= reg_wr_data[0];
                buf1_clear_pulse_reg <= reg_wr_data[1];
            end

            default: begin
                // acknowlege but ignore writes to other addresses
                reg_wr_ack_reg <= 1'b1; 
            end
        endcase
    end

    // read logic
    if (reg_rd_en && !reg_rd_ack_reg) begin

        reg_rd_ack_reg <= 1'b1;
        reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};

        case ({reg_rd_addr[REG_ADDR_WIDTH-1:2], 2'b00})
            // global
            REG_COMMIT_MAGIC: reg_rd_data_reg <= 32'h636f6d71; // "comq"
            REG_COMMIT_VERSION: reg_rd_data_reg <= 32'h00000100; // version 1.0
            REG_COMMIT_FEATURES: reg_rd_data_reg <= 32'h00000001; // feature bits
            REG_COMMIT_CONTROL: reg_rd_data_reg <= control_reg;
            REG_COMMIT_STATUS: reg_rd_data_reg <= commit_global_status_word;
            REG_COMMIT_ACTIVE_BUFFER: reg_rd_data_reg <= {31'd0, active_buf_reg};

            REG_COMMIT_STRIDE_LO: reg_rd_data_reg <= commit_stride_reg[31:0];
            REG_COMMIT_STRIDE_HI: reg_rd_data_reg <= commit_stride_reg[63:32];
            REG_COMMIT_CONTROL: reg_rd_data_reg <= control_reg;

            // buffer 0
            REG_BUF0_ADDR_LO: reg_rd_data_reg <= commit_buf0_addr_reg[31:0];
            REG_BUF0_ADDR_HI: reg_rd_data_reg <= commit_buf0_addr_reg[63:32];
            REG_BUF0_SLOT_CAPACITY: reg_rd_data_reg <= commit_buf0_slot_capacity_reg;
            REG_BUF0_STATUS: reg_rd_data_reg <= commit_buf0_status_word;
            REG_BUF0_COMPLETED_COUNT: reg_rd_data_reg <= buf0_completed_count_reg;
            REG_BUF0_ERROR_COUNT: reg_rd_data_reg <= buf0_error_count_reg;

            // buffer 1
            REG_BUF1_ADDR_LO: reg_rd_data_reg <= commit_buf1_addr_reg[31:0];
            REG_BUF1_ADDR_HI: reg_rd_data_reg <= commit_buf1_addr_reg[63:32];
            REG_BUF1_SLOT_CAPACITY: reg_rd_data_reg <= commit_buf1_slot_capacity_reg;
            REG_BUF1_STATUS: reg_rd_data_reg <= commit_buf1_status_word;
            REG_BUF1_COMPLETED_COUNT: reg_rd_data_reg <= buf1_completed_count_reg;
            REG_BUF1_ERROR_COUNT: reg_rd_data_reg <= buf1_error_count_reg;

            default: begin
                // Ignore reads from other addresses
                reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};
                reg_rd_ack_reg <= 1'b1;
            end
        endcase
    end

    if (rst) begin
        reg_wr_ack_reg <= 1'b0;
        reg_rd_ack_reg <= 1'b0;
        reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};

        start_pulse_reg <= 1'b0;
        stop_pulse_reg <= 1'b0;

        commit_stride_reg <= {DMA_ADDR_WIDTH{1'b0}};
        commit_buf0_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        commit_buf1_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        commit_buf0_slot_capacity_reg <= 32'd0;
        commit_buf1_slot_capacity_reg <= 32'd0;
        buf0_arm_pulse_reg <= 1'b0;
        buf1_arm_pulse_reg <= 1'b0;
        buf0_clear_pulse_reg <= 1'b0;
        buf1_clear_pulse_reg <= 1'b0;
    end
end

// Output assignments
assign reg_wr_wait = 1'b0;
assign reg_wr_ack = reg_wr_ack_reg;
assign reg_rd_wait = 1'b0;
assign reg_rd_ack = reg_rd_ack_reg;
assign reg_rd_data = reg_rd_data_reg;

// ======================================================================
//                  DMA write FSM combinational logic
// ======================================================================

// DMA write FSM
localparam [2:0] 
        STATE_IDLE          = 3'd0,
        STATE_WAIT_BUFFER   = 3'd1,
        STATE_WAIT_SLOT     = 3'd2,
        STATE_ISSUE_DMA     = 3'd3,
        STATE_WAIT_DMA      = 3'd4,
        STATE_POP_SLOT      = 3'd5;

reg [2:0] state_reg = STATE_IDLE, state_next;

// assistant signals
localparam [RAM_SEL_WIDTH-1:0] RAM_SEL_COMMIT_VALUE = RAM_SEL_COMMIT;
localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_COMMIT_VALUE = DMA_TAG_COMMIT;
// buffer status
wire active_buf_armed = active_buf_reg ? buf1_armed_reg : buf0_armed_reg;
wire [DMA_ADDR_WIDTH-1:0] active_buf_base_addr = active_buf_reg ? commit_buf1_addr_reg : commit_buf0_addr_reg;
wire [31:0] active_buf_slot_capacity = active_buf_reg ? commit_buf1_slot_capacity_reg : commit_buf0_slot_capacity_reg;
wire [31:0] active_buf_completed_count = active_buf_reg ? buf1_completed_count_reg : buf0_completed_count_reg;

wire active_buf_ready = active_buf_armed && active_buf_slot_capacity != 32'd0;
wire [DMA_ADDR_WIDTH-1:0] active_buf_completed_count_dma = active_buf_completed_count;
wire [DMA_ADDR_WIDTH-1:0] commit_dma_dst_addr = active_buf_base_addr + (active_buf_completed_count_dma * commit_stride_reg);

// DMA write descriptor signals
reg [DMA_ADDR_WIDTH-1:0]    dma_write_desc_dma_addr_reg = {DMA_ADDR_WIDTH{1'b0}}, dma_write_desc_dma_addr_next;
reg [RAM_SEL_WIDTH-1:0]     dma_write_desc_ram_sel_reg = {RAM_SEL_WIDTH{1'b0}}, dma_write_desc_ram_sel_next;
reg [RAM_ADDR_WIDTH-1:0]    dma_write_desc_ram_addr_reg = {RAM_ADDR_WIDTH{1'b0}}, dma_write_desc_ram_addr_next;
reg [DMA_LEN_WIDTH-1:0]     dma_write_desc_len_reg = {DMA_LEN_WIDTH{1'b0}}, dma_write_desc_len_next;
reg [DMA_TAG_WIDTH-1:0]     dma_write_desc_tag_reg = {DMA_TAG_WIDTH{1'b0}}, dma_write_desc_tag_next;
reg                         dma_write_desc_valid_reg = 1'b0, dma_write_desc_valid_next;

reg head_slot_pop_valid_reg = 1'b0, head_slot_pop_valid_next;

// DMA handshake and status helper signals
wire dma_write_desc_fire = dma_write_desc_valid_reg && m_axis_dma_write_desc_ready;
wire dma_write_status_match = s_axis_dma_write_desc_status_valid && s_axis_dma_write_desc_status_tag == DMA_TAG_COMMIT_VALUE;
wire dma_write_status_error = dma_write_status_match && s_axis_dma_write_desc_status_error != 4'd0;

wire head_slot_pop_fire = head_slot_pop_valid_reg && head_slot_pop_ready;

// -----------------------------------------------------
//         DMA write FSM combinational logic
// -----------------------------------------------------
always @(*) begin
    state_next = state_reg;

    busy_next = busy_reg;
    active_buf_next = active_buf_reg;

    waiting_slot_next = waiting_slot_reg;
    waiting_armed_buf_next = waiting_armed_buf_reg;

    stop_pending_next = stop_pending_reg;

    // buffer 0
    buf0_armed_next = buf0_armed_reg;
    buf0_done_next = buf0_done_reg;
    buf0_completed_count_next = buf0_completed_count_reg;
    buf0_error_count_next = buf0_error_count_reg;

    // buffer 1
    buf1_armed_next = buf1_armed_reg;
    buf1_done_next = buf1_done_reg;
    buf1_completed_count_next = buf1_completed_count_reg;
    buf1_error_count_next = buf1_error_count_reg;

    // DMA descriptor signals
    dma_write_desc_dma_addr_next = dma_write_desc_dma_addr_reg;
    dma_write_desc_ram_sel_next = dma_write_desc_ram_sel_reg;
    dma_write_desc_ram_addr_next = dma_write_desc_ram_addr_reg;
    dma_write_desc_len_next = dma_write_desc_len_reg;
    dma_write_desc_tag_next = dma_write_desc_tag_reg;
    dma_write_desc_valid_next = dma_write_desc_valid_reg && !dma_write_desc_fire;

    // commit_buf slot pop signals
    head_slot_pop_valid_next = head_slot_pop_valid_reg;

    // ------------------------------------------------
    // Per-buffer CSR commands
    // 
    // Host contract:
    //     - arm/clear an inactive buffer, or configure 
    //       buffers before start.
    //     - do not re-arm the currently active buffer 
    //       while it is being written.
    // ------------------------------------------------
    if (buf0_clear_pulse_reg) begin
        buf0_done_next = 1'b0;
        buf0_completed_count_next = 32'd0;
        buf0_error_count_next = 32'd0;
    end    

    if (buf0_arm_pulse_reg) begin
        buf0_armed_next = 1'b1;
        buf0_done_next = 1'b0;
        buf0_completed_count_next = 32'd0;
        buf0_error_count_next = 32'd0;
    end

    if (buf1_clear_pulse_reg) begin
        buf1_done_next = 1'b0;
        buf1_completed_count_next = 32'd0;
        buf1_error_count_next = 32'd0;
    end

    if (buf1_arm_pulse_reg) begin
        buf1_armed_next = 1'b1;
        buf1_done_next = 1'b0;
        buf1_completed_count_next = 32'd0;
        buf1_error_count_next = 32'd0;
    end

    // ------------------------------------------------
    //              FSM state transitions
    // ------------------------------------------------
    case (state_reg)
        // Idle state: wait for start signal
        STATE_IDLE: begin
            busy_next = 1'b0;

            dma_write_desc_valid_next = 1'b0;
            head_slot_pop_valid_next = 1'b0;

            stop_pending_next = 1'b0;

            if (start_pulse_reg && !stop_pulse_reg) begin
                busy_next = 1'b1;
                state_next = STATE_WAIT_BUFFER;
            end
        end

        // Wait for buffer to be armed
        STATE_WAIT_BUFFER: begin
            busy_next = 1'b1;
            waiting_armed_buf_next = 1'b0;

            dma_write_desc_valid_next = 1'b0;
            head_slot_pop_valid_next = 1'b0;

            if (stop_pulse_reg) begin
                busy_next = 1'b0;
                waiting_armed_buf_next = 1'b0;
                stop_pending_next = 1'b0;

                state_next = STATE_IDLE;
            end else if (active_buf_ready) begin
                // buffer is armed and has non-zero capacity, proceed to wait for slot
                waiting_armed_buf_next = 1'b0;
                state_next = STATE_WAIT_SLOT;
            end else begin
                // buffer is not armed or has zero capacity, wait for it to be armed
                waiting_armed_buf_next = 1'b1;
            end
        end

        // Wait for slot to be valid
        STATE_WAIT_SLOT: begin
            busy_next = 1'b1;
            waiting_slot_next = 1'b1;

            if (stop_pulse_reg) begin
                busy_next = 1'b0;
                waiting_slot_next = 1'b0;
                stop_pending_next = 1'b0;

                state_next = STATE_IDLE;
            end else if (!active_buf_ready) begin
                // slot is valid, proceed to issue DMA write
                waiting_slot_next = 1'b0;
                state_next = STATE_WAIT_BUFFER;
            end else if (head_slot_valid) begin
                // slot is valid, proceed to issue DMA write
                waiting_slot_next = 1'b0;

                // launch a complete DMA write descriptor
                dma_write_desc_dma_addr_next = commit_dma_dst_addr;
                dma_write_desc_ram_sel_next = RAM_SEL_COMMIT_VALUE;
                dma_write_desc_ram_addr_next = head_slot_addr;
                dma_write_desc_len_next = head_slot_len;
                dma_write_desc_tag_next = DMA_TAG_COMMIT_VALUE;
                dma_write_desc_valid_next = 1'b1;

                state_next = STATE_ISSUE_DMA;
            end
        end

        STATE_ISSUE_DMA: begin
            busy_next = 1'b1;

            if (dma_write_desc_fire) begin
                dma_write_desc_valid_next = 1'b0;

                // The descriptor have been accepted. It can no longer
                // be cancelled. A simultaneous stop becomes stop_pending.
                if (stop_pulse_reg) begin
                    stop_pending_next = 1'b1;
                end

                state_next = STATE_WAIT_DMA;
            end else if (stop_pulse_reg) begin
                // Descriptor has not been accepted yet, so it can
                // be cancelled safely.
                dma_write_desc_valid_next = 1'b0;
                
                busy_next = 1'b0;
                stop_pending_next = 1'b0;

                state_next = STATE_IDLE;
            end
        end

        // Wait for DMA write completion
        STATE_WAIT_DMA: begin
            busy_next = 1'b1;

            if (stop_pulse_reg) begin
                // DMA write is in progress, cannot be cancelled. Stop becomes pending.
                stop_pending_next = 1'b1;
            end

            if (dma_write_status_match) begin
                // DMA write completed, check for error
                if (dma_write_status_error) begin
                    // DMA write failed. Do not pop the commit slot.
                    if (active_buf_reg == 1'b0) begin
                        buf0_error_count_next = buf0_error_count_reg + 1'b1;
                    end else begin
                        buf1_error_count_next = buf1_error_count_reg + 1'b1;
                    end

                    busy_next = 1'b0;
                    stop_pending_next = 1'b0;
                    state_next = STATE_IDLE;
                end else begin
                    // DMA write successful, increment completed count for active buffer
                    head_slot_pop_valid_next = 1'b1;
                    state_next = STATE_POP_SLOT;
                end
            end
        end

        // Pop the head slot after successful DMA write
        STATE_POP_SLOT: begin
            busy_next = 1'b1;

            if (stop_pulse_reg) begin
                // DMA write is completed, but stop is requested. Stop becomes pending.
                stop_pending_next = 1'b1;
            end

            if (head_slot_pop_fire) begin
                head_slot_pop_valid_next = 1'b0;

                // Increment completed count for active buffer
                if (active_buf_reg == 1'b0) begin
                    // Buffer 0 completion
                    buf0_completed_count_next = buf0_completed_count_reg + 1'b1;

                    // Check if buffer 0 is now done
                    if (buf0_completed_count_next >= commit_buf0_slot_capacity_reg) begin
                        buf0_done_next = 1'b1;
                        buf0_armed_next = 1'b0; // Disarm buffer 0

                        // strict ping-pong transition: buffer 0 -> buffer 1.
                        // If buffer 1 is not armed, wait in STATE_WAIT_BUFFER.
                        active_buf_next = 1'b1;

                        if (stop_pending_reg || stop_pulse_reg) begin
                            busy_next = 1'b0;
                            stop_pending_next = 1'b0;
                            state_next = STATE_IDLE;
                        end else begin
                            state_next = STATE_WAIT_BUFFER;
                        end
                    end else begin
                        // Buffer 0 still has space. Continue writing it.
                        if (stop_pending_reg || stop_pulse_reg) begin
                            busy_next = 1'b0;
                            stop_pending_next = 1'b0;
                            state_next = STATE_IDLE;
                        end else begin
                            state_next = STATE_WAIT_SLOT;
                        end
                    end
                end else begin
                    // Buffer 1 completion
                    buf1_completed_count_next = buf1_completed_count_reg + 1'b1;

                    if (buf1_completed_count_next >= commit_buf1_slot_capacity_reg) begin
                        buf1_done_next = 1'b1;
                        buf1_armed_next = 1'b0; // Disarm buffer 1

                        // strict ping-pong transition: switch to buffer 0 if it is armed
                        active_buf_next = 1'b0;

                        if (stop_pending_reg || stop_pulse_reg) begin
                            busy_next = 1'b0;
                            stop_pending_next = 1'b0;
                            state_next = STATE_IDLE;
                        end else begin
                            state_next = STATE_WAIT_BUFFER;
                        end
                    end else begin
                        // Buffer 1 still has space. Continue writing it.
                        if (stop_pending_reg || stop_pulse_reg) begin
                            busy_next = 1'b0;
                            stop_pending_next = 1'b0;
                            state_next = STATE_IDLE;
                        end else begin
                            state_next = STATE_WAIT_SLOT;
                        end
                    end
                end
            end
        end

        default: begin
            state_next = STATE_IDLE;

            busy_next = 1'b0;
            waiting_slot_next = 1'b0;
            waiting_armed_buf_next = 1'b0;

            stop_pending_next = 1'b0;

            dma_write_desc_valid_next = 1'b0;
            head_slot_pop_valid_next = 1'b0;
        end

    endcase
end

// ------------------------------------------------
//              Sequential update logic
// ------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        state_reg <= STATE_IDLE;

        busy_reg <= 1'b0;
        active_buf_reg <= 1'b0;

        waiting_slot_reg <= 1'b0;
        waiting_armed_buf_reg <= 1'b0;

        stop_pending_reg <= 1'b0;

        // Buffer 0 runtime state
        buf0_armed_reg <= 1'b0;
        buf0_done_reg <= 1'b0;
        buf0_completed_count_reg <= 32'd0;
        buf0_error_count_reg <= 32'd0;

        // Buffer 1 runtime state
        buf1_armed_reg <= 1'b0;
        buf1_done_reg <= 1'b0;
        buf1_completed_count_reg <= 32'd0;
        buf1_error_count_reg <= 32'd0;

        // DMA descriptor
        dma_write_desc_dma_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        dma_write_desc_ram_sel_reg <= {RAM_SEL_WIDTH{1'b0}};
        dma_write_desc_ram_addr_reg <= {RAM_ADDR_WIDTH{1'b0}};
        dma_write_desc_len_reg <= {DMA_LEN_WIDTH{1'b0}};
        dma_write_desc_tag_reg <= {DMA_TAG_WIDTH{1'b0}};
        dma_write_desc_valid_reg <= 1'b0;

        head_slot_pop_valid_reg <= 1'b0;
    end else begin
        state_reg <= state_next;

        busy_reg <= busy_next;
        active_buf_reg <= active_buf_next;

        waiting_slot_reg <= waiting_slot_next;
        waiting_armed_buf_reg <= waiting_armed_buf_next;

        stop_pending_reg <= stop_pending_next;

        // Buffer 0 runtime state
        buf0_armed_reg <= buf0_armed_next;
        buf0_done_reg <= buf0_done_next;
        buf0_completed_count_reg <= buf0_completed_count_next;
        buf0_error_count_reg <= buf0_error_count_next;

        // Buffer 1 runtime state
        buf1_armed_reg <= buf1_armed_next;
        buf1_done_reg <= buf1_done_next;
        buf1_completed_count_reg <= buf1_completed_count_next;
        buf1_error_count_reg <= buf1_error_count_next;

        // DMA descriptor
        dma_write_desc_dma_addr_reg <= dma_write_desc_dma_addr_next;
        dma_write_desc_ram_sel_reg <= dma_write_desc_ram_sel_next;
        dma_write_desc_ram_addr_reg <= dma_write_desc_ram_addr_next;
        dma_write_desc_len_reg <= dma_write_desc_len_next;
        dma_write_desc_tag_reg <= dma_write_desc_tag_next;
        dma_write_desc_valid_reg <= dma_write_desc_valid_next;

        // commit_buf slot pop
        head_slot_pop_valid_reg <= head_slot_pop_valid_next;
    end
end

// output assignments
assign m_axis_dma_write_desc_dma_addr = dma_write_desc_dma_addr_reg;
assign m_axis_dma_write_desc_ram_sel = dma_write_desc_ram_sel_reg;
assign m_axis_dma_write_desc_ram_addr = dma_write_desc_ram_addr_reg;
assign m_axis_dma_write_desc_imm = {DMA_IMM_WIDTH{1'b0}}; // not used in this module
assign m_axis_dma_write_desc_imm_en = 1'b0; // not used in this module
assign m_axis_dma_write_desc_len = dma_write_desc_len_reg;
assign m_axis_dma_write_desc_tag = dma_write_desc_tag_reg;
assign m_axis_dma_write_desc_valid = dma_write_desc_valid_reg;
assign head_slot_pop_valid = head_slot_pop_valid_reg;

endmodule
