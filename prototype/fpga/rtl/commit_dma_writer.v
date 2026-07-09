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

    parameter RAM_SEL_COUNT = 1,
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
// All offsets are relative to RB_BASE_ADDR
//
// - 0x100: COMMIT_BUF0_ADDR_LO
// - 0x104: COMMIT_BUF0_ADDR_HI
// - 0x108: COMMIT_BUF1_ADDR_LO
// - 0x10C: COMMIT_BUF1_ADDR_HI
//
// - 0x110: COMMIT_STRIDE_LO
// - 0x114: COMMIT_STRIDE_HI
// - 0x118: COMMIT_COUNT
//
// - 0x11C: COMMIT_CONTROL
//      bit 0: start
//      bit 1: stop
//      bit 2: clear status
//      bit 8: arm buf 0
//      bit 9: arm buf 1
//
// - 0x120: COMMIT_STATUS
//      bit 0: busy
//      bit 1: current buf select
//      bit 2: buf 0 armed
//      bit 3: buf 1 armed
//      bit 4: buf 0 done
//      bit 5: buf 1 done
//      bit 6: error
//      bit 7: waiting for commit slot
//      bit 8: waiting for armed buf
//
// - 0x124: COMMIT_ACTIVE_INDEX
// - 0x128: COMMIT_BUF0_COMPLETED_COUNT
// - 0x12C: COMMIT_BUF1_COMPLETED_COUNT
// - 0x130: COMMIT_ERROR_COUNT

localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_BUF0_ADDR_LO = RB_BASE_ADDR + 16'h100;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_BUF0_ADDR_HI = RB_BASE_ADDR + 24'h104;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_BUF1_ADDR_LO = RB_BASE_ADDR + 24'h108;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_BUF1_ADDR_HI = RB_BASE_ADDR + 24'h10C;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_STRIDE_LO    = RB_BASE_ADDR + 24'h110;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_STRIDE_HI    = RB_BASE_ADDR + 24'h114;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_COUNT        = RB_BASE_ADDR + 24'h118;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_CONTROL      = RB_BASE_ADDR + 24'h11C;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_STATUS       = RB_BASE_ADDR + 24'h120;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_ACTIVE_INDEX = RB_BASE_ADDR + 24'h124;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_BUF0_COMPLETED_COUNT = RB_BASE_ADDR + 24'h128;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_BUF1_COMPLETED_COUNT = RB_BASE_ADDR + 24'h12C;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_ERROR_COUNT  = RB_BASE_ADDR + 24'h130;

localparam [RAM_SEG_WIDTH-1:0] RAM_SEL_COMMIT_VALUE = RAM_SEL_COMMIT;
localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_COMMIT_VALUE = DMA_TAG_COMMIT;

function [31:0] apply_wstrb;
    input [31:0] old_value;
    input [31:0] new_value;
    input [3:0]  strb;

    integer i;

    begin
        apply_wstrb = old_value;
        for (i=0; i<4; i=i+1) begin
            if (strb[i]) begin
                apply_wstrb[i*8 +: 8] = new_value[i*8 +: 8];
            end
        end
    end
endfunction

// ======================================================================
// Internal signals
// ======================================================================
reg [DMA_ADDR_WIDTH-1:0] commit_buf0_addr_reg = {DMA_ADDR_WIDTH{1'b0}};
reg [DMA_ADDR_WIDTH-1:0] commit_buf1_addr_reg = {DMA_ADDR_WIDTH{1'b0}};
reg [DMA_ADDR_WIDTH-1:0] commit_stride_reg = {DMA_ADDR_WIDTH{1'b0}};

reg [31:0] commit_count_reg = {DMA_LEN_WIDTH{1'b0}};

reg busy_reg = 1'b0, busy_next;
reg current_buf_reg =  1'b0, current_buf_next;

reg [1:0] buf_armed_reg = 2'b00, buf_armed_next;
reg [1:0] buf_done_reg = 2'b00, buf_done_next;

reg [31:0] active_index_reg = 32'd0, active_index_next;
reg [31:0] buf0_completed_count_reg = 32'd0, buf0_completed_count_next;
reg [31:0] buf1_completed_count_reg = 32'd0, buf1_completed_count_next;
reg [31:0] error_count_reg = 32'd0, error_count_next;

reg waiting_alot_reg = 1'b0;
reg waiting_armed_buf_reg = 1'b0;

reg clear_status_pulse_reg = 1'b0;
reg arm0_pulse_reg = 1'b0;
reg arm1_pulse_reg = 1'b0;

reg wr_ack_reg = 1'b0;
reg rd_ack_reg = 1'b0;
reg [REG_DATA_WIDTH-1:0] rd_data_reg = {REG_DATA_WIDTH{1'b0}};

assign reg_wr_wait = 1'b0;
assign reg_wr_ack = wr_ack_reg;

assign reg_rd_wait = 1'b0;
assign reg_rd_ack = rd_ack_reg;
assign reg_rd_data = rd_data_reg;

// ------------------------------------------
// DMA write FSM
// -----------------------------------------
localparam [2:0] 
        STATE_IDLE                  = 3'd0,
        STATE_SELECT_BUFFER         = 3'd1,
        STATE_WAIT_ARMED_BUFFER     = 3'd2,
        STATE_WAIT_SLOT             = 3'd3,
        STATE_ISSUE_DMA             = 3'd4,
        STATE_WAIT_DMA              = 3'd5,
        STATE_POP_SLOT              = 3'd6;

reg [2:0] state_reg = STATE_IDLE;

reg [DMA_ADDR_WIDTH-1:0]    dma_write_desc_dma_addr_reg = {DMA_ADDR_WIDTH{1'b0}}, dma_write_desc_dma_addr_next;
reg [RAM_SEL_WIDTH-1:0]     dma_write_desc_ram_sel_reg = {RAM_SEL_WIDTH{1'b0}}, dma_write_desc_ram_sel_next;
reg [RAM_ADDR_WIDTH-1:0]    dma_write_desc_ram_addr_reg = {RAM_ADDR_WIDTH{1'b0}}, dma_write_desc_ram_addr_next;
reg [DMA_IMM_WIDTH-1:0]     dma_write_desc_imm_reg = {DMA_IMM_WIDTH{1'b0}}, dma_write_desc_imm_next;
reg                         dma_write_desc_imm_en_reg = 1'b0;
reg [DMA_LEN_WIDTH-1:0]     dma_write_desc_len_reg = {DMA_LEN_WIDTH{1'b0}}, dma_write_desc_len_next;
reg [DMA_TAG_WIDTH-1:0]     dma_write_desc_tag_reg = {DMA_TAG_WIDTH{1'b0}}, dma_write_desc_tag_next;
reg                         dma_write_desc_valid_reg = 1'b0, dma_write_desc_valid_next;

reg head_slot_pop_valid_reg = 1'b0;

wire current_buf_armed = current_buf_reg ? buf_armed_reg[1] : buf_armed_reg[0];
wire other_buf_armed = current_buf_reg ? buf_armed_reg[0] : buf_armed_reg[1];
wire [DMA_ADDR_WIDTH-1:0] current_buf_base_addr =  current_buf_reg ? commit_buf1_addr_reg : commit_buf0_addr_reg;

wire [DMA_ADDR_WIDTH-1:0] active_index_dma = active_index_reg;

wire [DMA_ADDR_WIDTH-1:0] commit_dma_dst_addr = current_buf_base_addr + (active_index_dma << 2);

wire commit_count_zero = commit_count_reg == 32'd0;

wire dma_write_status_match = s_axis_dma_write_desc_status_valid &&
    (s_axis_dma_write_desc_status_tag == DMA_TAG_COMMIT_VALUE);

wire dma_write_status_error = dma_write_status_match && (s_axis_dma_write_desc_status_error != 4'd0);

assign m_axis_dma_write_desc_dma_addr = dma_write_desc_dma_addr_reg;
assign m_axis_dma_write_desc_ram_sel = dma_write_desc_ram_sel_reg;
assign m_axis_dma_write_desc_ram_addr = dma_write_desc_ram_addr_reg;
assign m_axis_dma_write_desc_imm = dma_write_desc_imm_reg;
assign m_axis_dma_write_desc_imm_en = dma_write_desc_imm_en_reg;
assign m_axis_dma_write_desc_len = dma_write_desc_len_reg;
assign m_axis_dma_write_desc_tag = dma_write_desc_tag_reg;
assign m_axis_dma_write_desc_valid = dma_write_desc_valid_reg;
assign head_slot_pop_valid = head_slot_pop_valid_reg;

// ======================================================================
// CSR write logic
// ======================================================================
always @(posedge clk) begin
    clear_status_pulse_reg <= 1'b0;
    arm0_pulse_reg <= 1'b0;
    arm1_pulse_reg <= 1'b0;

    wr_ack_reg <= 1'b0;
    rd_ack_reg <= 1'b0;

    if (reg_wr_en && !reg_wr_ack_reg) begin
        reg_wr_ack_reg <= 1'b1;

        case (reg_wr_addr)
            REG_COMMIT_BUF0_ADDR_LO: commit_buf0_addr_reg[31:0] <= apply_wstrb(commit_buf0_addr_reg[31:0], reg_wr_data, reg_wr_strb);
            REG_COMMIT_BUF0_ADDR_HI: commit_buf0_addr_reg[63:32] <= apply_wstrb(commit_buf0_addr_reg[63:32], reg_wr_data, reg_wr_strb);
            REG_COMMIT_BUF1_ADDR_LO: commit_buf1_addr_reg[31:0] <= apply_wstrb(commit_buf1_addr_reg[31:0], reg_wr_data, reg_wr_strb);
            REG_COMMIT_BUF1_ADDR_HI: commit_buf1_addr_reg[63:32] <= apply_wstrb(commit_buf1_addr_reg[63:32], reg_wr_data, reg_wr_strb);
            REG_COMMIT_STRIDE_LO: commit_stride_reg[31:0] <= apply_wstrb(commit_stride_reg[31:0], reg_wr_data, reg_wr_strb);
            REG_COMMIT_STRIDE_HI: commit_stride_reg[63:32] <= apply_wstrb(commit_stride_reg[63:32], reg_wr_data, reg_wr_strb);
            REG_COMMIT_COUNT: commit_count_reg <= apply_wstrb(commit_count_reg, reg_wr_data, reg_wr_strb);
            REG_COMMIT_CONTROL: begin
                if (reg_wr_data[2]) begin
                    clear_status_pulse_reg <= 1'b1;

                    active_index_reg <= 32'd0;
                    buf0_completed_count_reg <= 32'd0;
                    buf1_completed_count_reg <= 32'd0;
                    error_count_reg <= 32'd0;
                    buf_done_reg <= 2'b00;
                end

                if (reg_wr_data[8]) begin
                    arm0_pulse_reg <= 1'b1;
                    buf_armed_reg[0] <= 1'b1;
                    buf_done_reg[0] <= 1'b0;
                    buf0_completed_count_reg <= 32'd0;
                end

                if (reg_rd_data[9]) begin
                    arm1_pulse_reg <= 1'b1;
                    buf_armed_reg[1] <= 1'b1;
                    buf_done_reg[1] <= 1'b0;
                    buf1_completed_count_reg <= 32'd0;
                end
            end

            default: begin
                // Ignore writes to other addresses
            end
        endcase
    end

    if (reg_rd_en && !reg_rd_ack_reg) begin
        reg_rd_ack_reg <= 1'b1;
        reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};

        case (reg_rd_addr)
            REG_COMMIT_BUF0_ADDR_LO: rd_data_reg <= commit_buf0_addr_reg[31:0];
            REG_COMMIT_BUF0_ADDR_HI: rd_data_reg <= commit_buf0_addr_reg[63:32];
            REG_COMMIT_BUF1_ADDR_LO: rd_data_reg <= commit_buf1_addr_reg[31:0];
            REG_COMMIT_BUF1_ADDR_HI: rd_data_reg <= commit_buf1_addr_reg[63:32];
            REG_COMMIT_STRIDE_LO: rd_data_reg <= commit_stride_reg[31:0];
            REG_COMMIT_STRIDE_HI: rd_data_reg <= commit_stride_reg[63:32];
            REG_COMMIT_COUNT: rd_data_reg <= commit_count_reg;
            REG_COMMIT_CONTROL: rd_data_reg <= {26'd0,
                                                clear_status_pulse_reg,
                                                2'b00,
                                                arm0_pulse_reg,
                                                arm1_pulse_reg};
            REG_COMMIT_STATUS: rd_data_reg <= {24'd0,
                                                busy_reg,
                                                current_buf_reg,
                                                buf_armed_reg,
                                                buf_done_reg,
                                                error_count_reg != 32'd0,
                                                waiting_alot_reg,
                                                waiting_armed_buf_reg};
            REG_COMMIT_ACTIVE_INDEX: rd_data_reg <= active_index_reg;
            REG_COMMIT_BUF0_COMPLETED_COUNT: rd_data_reg <= buf0_completed_count_reg;
            REG_COMMIT_BUF1_COMPLETED_COUNT: rd_data_reg <= buf1_completed_count_reg;
            REG_COMMIT_ERROR_COUNT: rd_data_reg <= error_count_reg;

            default: begin
                // Ignore reads from other addresses
                rd_data_reg <= {REG_DATA_WIDTH{1'b0}};
            end
        endcase
    end

    if (rst) begin
        commit_buf0_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        commit_buf1_addr_reg <= {DMA_ADDR_WIDTH{1'b0}};
        commit_stride_reg <= {DMA_ADDR_WIDTH{1'b0}};
        commit_count_reg <= {DMA_LEN_WIDTH{1'b0}};

        busy_reg <= 1'b0;
        current_buf_reg <= 1'b0;

        buf_armed_reg <= 2'b00;
        buf_done_reg <= 2'b00;

        waiting_alot_reg <= 1'b0;
        waiting_armed_buf_reg <= 1'b0;

        active_index_reg <= 32'd0;
        buf0_completed_count_reg <= 32'd0;
        buf1_completed_count_reg <= 32'd0;
        error_count_reg <= 32'd0;

        clear_status_pulse_reg <= 1'b0;
        arm0_pulse_reg <= 1'b0;
        arm1_pulse_reg <= 1'b0;

        wr_ack_reg <= 1'b0;
        rd_ack_reg <= 1'b0;
    end
end

// ======================================================================
// Write state transitions
// ======================================================================
always @(*) begin
    state_next = state_reg;

    // Default values
    busy_next = busy_reg;
    current_buf_next = current_buf_reg;
    buf_armed_next = buf_armed_reg;
    buf_done_next = buf_done_reg;

    active_index_next = active_index_reg;
    buf0_completed_count_next = buf0_completed_count_reg;
    buf1_completed_count_next = buf1_completed_count_reg;
    error_count_next = error_count_reg;

    dma_write_desc_valid_next = dma_write_desc_valid_reg;
    head_slot_pop_valid_next = head_slot_pop_valid_reg;

    waiting_slot_next = 1'b0;
    waiting_armed_buf_next = 1'b0;

    case (state_reg)
        STATE_IDLE: begin
            dma_write_desc_valid_next = 1'b0;
            head_slot_pop_valid_next = 1'b0;

            if (start_cmd) begin
                busy_next = 1'b1;
                active_index_next = 32'd0;
                state_next = STATE_SELECT_BUFFER;
            end
        end

        STATE_SELECT_BUFFER: begin
            if (commit_count_zero) begin
                busy_next = 1'b0;
                state_next = STATE_IDLE;
            end else if (current_buf_armed) begin
                state_next = STATE_WAIT_SLOT;
            end else if (other_buf_armed) begin
                current_buf_next = !current_buf_reg;
                state_next = STATE_WAIT_SLOT;
            end else begin
                waiting_armed_buf_next = 1'b1;
                state_next = STATE_WAIT_ARMED_BUFFER;
            end
        end

        STATE_WAIT_SLOT: begin
            waiting_slot_next = 1'b1;

            if (head_slot_valid) begin
                waiting_slot_next = 1'b0;

                dma_write_desc_dma_addr_next = commit_dma_dst_addr;
                dma_write_desc_ram_sel_next = RAM_SEL_COMMIT_VALUE;
                dma_write_desc_ram_addr_next = head_slot_addr;
                dma_write_desc_imm_en_next = 1'b0;
                dma_write_desc_len_next = head_slot_len;
                dma_write_desc_tag_next = DMA_TAG_COMMIT_VALUE;
                dma_write_desc_valid_next = 1'b1;

                state_next = STATE_ISSUE_DMA;
            end
        end

        STATE_ISSUE_DMA: begin
            if (dma_write_desc_valid_reg && m_axis_dma_write_desc_ready) begin
                dma_write_desc_valid_next = 1'b0;
                state_next = STATE_WAIT_DMA;
            end
        end

        STATE_WAIT_DMA: begin
            if (dma_write_status_match) begin
                if (dma_write_status_error) begin
                    error_count_next = error_count_reg + 1;
                    busy_next = 1'b0;
                    state_next = STATE_IDLE;
                end else begin
                    head_slot_pop_valid_next = 1'b1;
                    state_next = STATE_POP_SLOT;
                end
            end
        end

        STATE_POP_SLOT: begin
            if (head_slot_pop_valid_reg && head_slot_pop_ready) begin
                head_slot_pop_valid_next = 1'b0;

                if (current_buf_reg == 1'b0) begin
                    buf0_completed_count_next = buf0_completed_count_reg + 1'b1;
                end else begin
                    buf1_completed_count_next = buf1_completed_count_reg + 1'b1;
                end

                if (active_index_reg + 1 >= commit_count_reg) begin
                    active_index_next = 32'd0;

                    if (current_buf_reg == 1'b0) begin
                        buf_done_next[0] = 1'b1;
                        buf_armed_next[0] = 1'b0;
                    end else begin
                        buf_done_next[1] = 1'b1;
                        buf_armed_next[1] = 1'b0;
                    end

                    current_buf_next = !current_buf_reg;
                    state_next = STATE_SELECT_BUFFER;
                end else begin
                    active_index_next = active_index_reg + 1'b1;
                    state_next = STATE_WAIT_SLOT;
                end
            end
        end
    endcase
    
    if (stop_cmd) begin
        busy_next = 1'b0;
        waiting_slot_next = 1'b0;
        waiting_armed_buf_next = 1'b0;
        dma_write_desc_valid_next = 1'b0;
        head_slot_pop_valid_next = 1'b0;
        state_next = STATE_IDLE;
    end
end

// ======================================================================
// Sequential logic
// ======================================================================
always @(posedge clk) begin
    if (rst) begin
        state_reg <= STATE_IDLE;

        busy_reg <= 1'b0;
        current_buf_reg <= 1'b0;
        buf_armed_reg <= 2'b00;
        buf_done_reg <= 2'b00;

        active_index_reg <= 32'd0;
        buf0_completed_count_reg <= 32'd0;
        buf1_completed_count_reg <= 32'd0;
        error_count_reg <= 32'd0;

        waiting_slot_reg <= 1'b0;
        waiting_armed_buf_reg <= 1'b0;

        dma_write_desc_valid_reg <= 1'b0;
        head_slot_pop_valid_reg <= 1'b0;
    end else begin
        state_reg <= state_next;

        busy_reg <= busy_next;
        current_buf_reg <= current_buf_next;
        buf_armed_reg <= buf_armed_next;
        buf_done_reg <= buf_done_next;

        active_index_reg <= active_index_next;
        buf0_completed_count_reg <= buf0_completed_count_next;
        buf1_completed_count_reg <= buf1_completed_count_next;
        error_count_reg <= error_count_next;

        waiting_slot_reg <= waiting_slot_next;
        waiting_armed_buf_reg <= waiting_armed_buf_next;

        dma_write_desc_valid_reg <= dma_write_desc_valid_next;
        head_slot_pop_valid_reg <= head_slot_pop_valid_next;
    end
end

endmodule
