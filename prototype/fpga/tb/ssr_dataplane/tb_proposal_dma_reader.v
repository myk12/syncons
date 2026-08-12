`resetall
`timescale 1ns / 1ps
`default_nettype none

module tb_proposal_dma_reader;

// Parameters
localparam REG_ADDR_WIDTH = 12;
localparam REG_DATA_WIDTH = 32;
localparam REG_STRB_WIDTH = (REG_DATA_WIDTH/8);
localparam RB_BASE_ADDR = 32'h0000_0000;

localparam DMA_ADDR_WIDTH = 64;
localparam DMA_LEN_WIDTH = 32;
localparam DMA_TAG_WIDTH = 8;

localparam RAM_SEL_WIDTH = 4;
localparam RAM_ADDR_WIDTH = 16;
localparam RAM_SEG_COUNT = 2;
localparam RAM_SEG_DATA_WIDTH = 256 * 2/ RAM_SEG_COUNT;
localparam RAM_SEG_BE_WIDTH = (RAM_SEG_DATA_WIDTH/8);
localparam RAM_SEG_ADDR_WIDTH = (RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH));

localparam RAM_SEL_PROP = 0;
localparam DMA_TAG_PROP = 0;

localparam PROPOSAL_SLOT_BYTES = 1024;

localparam [DMA_LEN_WIDTH-1:0] PROPOSAL_SLOT_BYTES_LEN = PROPOSAL_SLOT_BYTES;

// ========================================================================
// Test Configuration
// ========================================================================

localparam [DMA_ADDR_WIDTH-1:0] TEST_DMA_BASE_ADDR = 64'h0000_0001_0000_0000;
localparam [DMA_ADDR_WIDTH-1:0] TEST_DMA_STRIDE = PROPOSAL_SLOT_BYTES;
localparam integer TEST_BATCH_COUNT = 4;

// ========================================================================
// CSR register addresses
// ========================================================================
localparam [REG_ADDR_WIDTH-1:0] REG_STATUS          = 12'h010;
localparam [REG_ADDR_WIDTH-1:0] REG_COUNTER         = 12'h018;

localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_ADDR_LO   = 12'h100;
localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_ADDR_HI   = 12'h104;
localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_LEN       = 12'h108;
localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_STRIDE_LO = 12'h10C;
localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_STRIDE_HI = 12'h110;
localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_COUNT     = 12'h114;
localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_CONTROL   = 12'h118;
localparam [REG_ADDR_WIDTH-1:0] REG_BATCH_STATUS    = 12'h11C;
localparam [REG_ADDR_WIDTH-1:0] REG_ACTIVE_INDEX    = 12'h120;
localparam [REG_ADDR_WIDTH-1:0] REG_FSM_STATE       = 12'h124;

// ========================================================================
// Clock and Reset
// ========================================================================

reg clk = 1'b0;
reg rst = 1'b0;

always #5 clk = ~clk; // 100 MHz clock

// ========================================================================
// CSR write interface
// ========================================================================
reg [REG_ADDR_WIDTH-1:0] reg_wr_addr = {REG_ADDR_WIDTH{1'b0}};
reg [REG_DATA_WIDTH-1:0] reg_wr_data = {REG_DATA_WIDTH{1'b0}};
reg [REG_STRB_WIDTH-1:0] reg_wr_strb = {REG_STRB_WIDTH{1'b0}};
reg reg_wr_en = 1'b0;

wire reg_wr_wait;
wire reg_wr_ack;

// ========================================================================
// CSR read interface
// ========================================================================
reg  [REG_ADDR_WIDTH-1:0]   reg_rd_addr = {REG_ADDR_WIDTH{1'b0}};
wire [REG_DATA_WIDTH-1:0]   reg_rd_data;
reg reg_rd_en = 1'b0;

wire reg_rd_wait;
wire reg_rd_ack;

// ========================================================================
// DMA read descriptor output from DUT
// ========================================================================
wire [DMA_ADDR_WIDTH-1:0]   m_axis_dma_read_desc_dma_addr;
wire [RAM_SEL_WIDTH-1:0]    m_axis_dma_read_desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0]   m_axis_dma_read_desc_ram_addr;
wire [DMA_LEN_WIDTH-1:0]    m_axis_dma_read_desc_len;
wire [DMA_TAG_WIDTH-1:0]    m_axis_dma_read_desc_tag;
wire                        m_axis_dma_read_desc_valid;

reg                         m_axis_dma_read_desc_ready = 1'b0;

// ========================================================================
// DMA read completion status input to DUT
// ========================================================================
reg [DMA_TAG_WIDTH-1:0]     s_axis_dma_read_desc_status_tag = {DMA_TAG_WIDTH{1'b0}};
reg [3:0]                   s_axis_dma_read_desc_status_error = 4'b0;
reg                         s_axis_dma_read_desc_status_valid = 1'b0;

// ========================================================================
// DMA RAM write back interface into DUT
//
// In this minimal control-path testbench, we do not really send payload
// write-back data. These inputs are tied to zero.
// ========================================================================
reg [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]       dma_ram_wr_cmd_sel = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
reg [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]    dma_ram_wr_cmd_be = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
reg [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]  dma_ram_wr_cmd_addr = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  dma_ram_wr_cmd_data = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
reg [RAM_SEG_COUNT-1:0]                     dma_ram_wr_cmd_valid = {RAM_SEG_COUNT{1'b0}};

wire [RAM_SEG_COUNT-1:0]                     dma_ram_wr_cmd_ready;
wire [RAM_SEG_COUNT-1:0]                     dma_ram_wr_done;

// ========================================================================
// Generic buffer write interface from DUT to fake proposal buffer
//
// Since this is a minimal testbench, the fake proposal buffer is always
// ready to accept write-back beats.
// ========================================================================
wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]       buf_wr_be;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]     buf_wr_data;
wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]     buf_wr_addr;
wire [RAM_SEG_COUNT-1:0]                        buf_wr_valid;

wire [RAM_SEG_COUNT-1:0]                        buf_wr_ready;
wire [RAM_SEG_COUNT-1:0]                        buf_wr_done;

assign buf_wr_ready = {RAM_SEG_COUNT{1'b1}};
assign buf_wr_done = buf_wr_valid;

// ========================================================================
// Fake proposal buffer tail slot interface
//
// prposal_buffer continuously exposes the current writable tail slot.
// In this testbench, tail_slot_addr advances only after commit.
// ========================================================================

localparam integer PROPOSAL_SLOT_BYTE_ADDR_WIDTH = $clog2(PROPOSAL_SLOT_BYTES);

reg tail_slot_valid = 1'b1;
reg [31:0] tail_slot_index_reg = 32'd0;

wire [RAM_ADDR_WIDTH-1:0] tail_slot_addr;
wire [DMA_LEN_WIDTH-1:0] tail_slot_len;

assign tail_slot_addr = tail_slot_index_reg[RAM_ADDR_WIDTH-1:0] << PROPOSAL_SLOT_BYTE_ADDR_WIDTH;
assign tail_slot_len = PROPOSAL_SLOT_BYTES_LEN;

// ========================================================================
// Commit interface from DUT to fake proposal_buffer
// =====================================================================

wire commit_valid;
reg commit_ready = 1'b1;

// ========================================================================
// DUT instantiation
// ========================================================================
proposal_dma_reader #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .REG_STRB_WIDTH(REG_STRB_WIDTH),
    .RB_BASE_ADDR(RB_BASE_ADDR),

    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),

    .RAM_SEL_PROP(RAM_SEL_PROP),
    .DMA_TAG_PROP(DMA_TAG_PROP),
    .PROPOSAL_SLOT_BYTES(PROPOSAL_SLOT_BYTES)
)
dut (
    .clk(clk),
    .rst(rst),

    // Register interface
    .reg_wr_addr(reg_wr_addr),
    .reg_wr_data(reg_wr_data),
    .reg_wr_strb(reg_wr_strb),
    .reg_wr_en(reg_wr_en),
    .reg_wr_wait(reg_wr_wait),
    .reg_wr_ack(reg_wr_ack),

    .reg_rd_addr(reg_rd_addr),
    .reg_rd_data(reg_rd_data),
    .reg_rd_en(reg_rd_en),
    .reg_rd_wait(reg_rd_wait),
    .reg_rd_ack(reg_rd_ack),

    // DMA read descriptor output
    .m_axis_dma_read_desc_dma_addr(m_axis_dma_read_desc_dma_addr),
    .m_axis_dma_read_desc_ram_sel(m_axis_dma_read_desc_ram_sel),
    .m_axis_dma_read_desc_ram_addr(m_axis_dma_read_desc_ram_addr),
    .m_axis_dma_read_desc_len(m_axis_dma_read_desc_len),
    .m_axis_dma_read_desc_tag(m_axis_dma_read_desc_tag),
    .m_axis_dma_read_desc_valid(m_axis_dma_read_desc_valid),
    .m_axis_dma_read_desc_ready(m_axis_dma_read_desc_ready),

    // DMA read completion status input
    .s_axis_dma_read_desc_status_tag(s_axis_dma_read_desc_status_tag),
    .s_axis_dma_read_desc_status_error(s_axis_dma_read_desc_status_error),
    .s_axis_dma_read_desc_status_valid(s_axis_dma_read_desc_status_valid),

    // DMA RAM write back interface
    .dma_ram_wr_cmd_sel(dma_ram_wr_cmd_sel),
    .dma_ram_wr_cmd_be(dma_ram_wr_cmd_be),
    .dma_ram_wr_cmd_addr(dma_ram_wr_cmd_addr),
    .dma_ram_wr_cmd_data(dma_ram_wr_cmd_data),
    .dma_ram_wr_cmd_valid(dma_ram_wr_cmd_valid),
    .dma_ram_wr_cmd_ready(dma_ram_wr_cmd_ready),
    .dma_ram_wr_done(dma_ram_wr_done),

    // Generic buffer write interface
    .buf_wr_be(buf_wr_be),
    .buf_wr_data(buf_wr_data),
    .buf_wr_addr(buf_wr_addr),
    .buf_wr_valid(buf_wr_valid),
    .buf_wr_ready(buf_wr_ready),
    .buf_wr_done(buf_wr_done),

    // Tail slot interface from fake proposal_buffer
    .tail_slot_valid(tail_slot_valid),
    .tail_slot_addr(tail_slot_addr),
    .tail_slot_len(tail_slot_len),

    // Commit interface to fake proposal_buffer
    .commit_valid(commit_valid),
    .commit_ready(commit_ready)
);

// ========================================================================
// Testbench bookkeeping
// ========================================================================

integer error_count = 0;
reg [REG_DATA_WIDTH-1:0] rd_data_tmp = {REG_DATA_WIDTH{1'b0}};

// ========================================================================
// CSR write task
// ========================================================================
task csr_write;
    input [REG_ADDR_WIDTH-1:0] addr;
    input [REG_DATA_WIDTH-1:0] data;

    begin
        @(negedge clk);

        reg_wr_addr <= addr;
        reg_wr_data <= data;
        reg_wr_strb <= {REG_STRB_WIDTH{1'b1}};
        reg_wr_en <= 1'b1;

        @(posedge clk);
        #1;

        if (!reg_wr_ack) begin
            $display("[%0t] ERROR: CSR write to address 0x%0h did not receive ack", $time, addr);
            error_count = error_count + 1;
        end

        @(negedge clk);

        reg_wr_en = 1'b0;
        reg_wr_addr <= {REG_ADDR_WIDTH{1'b0}};
        reg_wr_data <= {REG_DATA_WIDTH{1'b0}};
        reg_wr_strb <= {REG_STRB_WIDTH{1'b0}};
    end
endtask

// ========================================================================
// CSR read task
// ========================================================================

task csr_read;
    input [REG_ADDR_WIDTH-1:0] addr;
    output [REG_DATA_WIDTH-1:0] data;

    begin
        @(negedge clk);

        reg_rd_addr <= addr;
        reg_rd_en <= 1'b1;

        @(posedge clk);
        #1;

        if (!reg_rd_ack) begin
            $display("[%0t] ERROR: CSR read from address 0x%0h did not receive ack", $time, addr);
            error_count = error_count + 1;
        end else begin
            data = reg_rd_data;
        end

        @(negedge clk);

        reg_rd_en <= 1'b0;
        reg_rd_addr <= {REG_ADDR_WIDTH{1'b0}};
    end
endtask

// ========================================================================
// Descriptor monitor and fake DMA completion generator
// ========================================================================
reg [31:0] dma_desc_count = 32'd0;

reg status_pending = 1'b0;
reg [7:0] status_delay_count = 8'd0;
reg [DMA_TAG_WIDTH-1:0] pending_status_tag = {DMA_TAG_WIDTH{1'b0}};

reg [DMA_ADDR_WIDTH-1:0] expected_dma_addr = {DMA_ADDR_WIDTH{1'b0}};
reg [RAM_ADDR_WIDTH-1:0] expected_ram_addr = {RAM_ADDR_WIDTH{1'b0}};
reg [DMA_LEN_WIDTH-1:0]  expected_dma_len = {DMA_LEN_WIDTH{1'b0}};
reg [DMA_TAG_WIDTH-1:0]  expected_dma_tag = {DMA_TAG_WIDTH{1'b0}};

always @(posedge clk) begin
    if (rst) begin
        dma_desc_count <= 32'd0;

        status_pending <= 1'b0;
        status_delay_count <= 8'd0;
        pending_status_tag <= {DMA_TAG_WIDTH{1'b0}};

        s_axis_dma_read_desc_status_tag <= {DMA_TAG_WIDTH{1'b0}};
        s_axis_dma_read_desc_status_error <= 4'b0;
        s_axis_dma_read_desc_status_valid <= 1'b0;
    end else begin
        // default: no DMA completion status this cycle
        s_axis_dma_read_desc_status_valid <= 1'b0;

        // detect one accepted DMA read descriptor
        if (m_axis_dma_read_desc_valid && m_axis_dma_read_desc_ready) begin
            expected_dma_addr   = TEST_DMA_BASE_ADDR + dma_desc_count * TEST_DMA_STRIDE;
            expected_ram_addr   = dma_desc_count * PROPOSAL_SLOT_BYTES;
            expected_dma_len    = PROPOSAL_SLOT_BYTES;
            expected_dma_tag      = DMA_TAG_PROP + dma_desc_count[DMA_TAG_WIDTH-1:0];

            $display("[%0t] DMA desc %0d: addr=0x%0h, ram_addr=0x%0h, len=%0d, tag=0x%0h",
                $time,
                dma_desc_count,
                m_axis_dma_read_desc_dma_addr,
                m_axis_dma_read_desc_ram_addr,
                m_axis_dma_read_desc_len,
                m_axis_dma_read_desc_tag
            );

            if (m_axis_dma_read_desc_dma_addr !== expected_dma_addr) begin
                $display("[%0t] ERROR: dma_addr mismatch, got=0x%h expected=0x%h",
                    $time,
                    m_axis_dma_read_desc_dma_addr,
                    expected_dma_addr
                );
                error_count = error_count + 1;
            end

            if (m_axis_dma_read_desc_ram_addr !== expected_ram_addr) begin
                $display("[%0t] ERROR: ram_addr mismatch, got=0x%h expected=0x%h",
                    $time,
                    m_axis_dma_read_desc_ram_addr,
                    expected_ram_addr
                );
                error_count = error_count + 1;
            end

            if (m_axis_dma_read_desc_len !== expected_dma_len) begin
                $display("[%0t] ERROR: len mismatch, got=%0d expected=%0d",
                    $time,
                    m_axis_dma_read_desc_len,
                    expected_dma_len
                );
                error_count = error_count + 1;
            end

            if (status_pending) begin
                $display("[%0t] ERROR: DMA descriptor accepted while previous status is pending", $time);
                error_count = error_count + 1;
            end

            // schedule a fake DMA completion after serveral cycles
            status_pending <= 1'b1;
            status_delay_count <= 8'd5; // delay 5 cycles before sending completion
            pending_status_tag <= m_axis_dma_read_desc_tag;

            dma_desc_count <= dma_desc_count + 1;
        end

        // Generate fake DMA completion status after delay
        if (status_pending) begin
            if (status_delay_count == 0) begin
                s_axis_dma_read_desc_status_tag <= pending_status_tag;
                s_axis_dma_read_desc_status_error <= 4'b0; // no error
                s_axis_dma_read_desc_status_valid <= 1'b1;

                status_pending <= 1'b0;

                $display("[%0t] DMA completion status sent for tag=0x%0h", $time, pending_status_tag);
            end else begin
                status_delay_count <= status_delay_count - 1;
            end
        end
    end
end

// ========================================================================
// Fake proposal_buffer commit interface
// ========================================================================

reg [31:0] commit_count = 32'd0;

always @(posedge clk) begin
    if (rst) begin
        tail_slot_index_reg <= 32'd0;
        commit_count <= 32'd0;
    end else begin
        if (commit_valid && commit_ready) begin
            $display("[%0t] Commit tail slot index %0d", $time, tail_slot_index_reg);

            tail_slot_index_reg <= tail_slot_index_reg + 1;
            commit_count <= commit_count + 1;
        end
    end
end

// ========================================================================
// Main test
// ========================================================================
initial begin
    $dumpfile("tb_proposal_dma_reader.vcd");
    $dumpvars(0, tb_proposal_dma_reader);

    $display("Start tb_proposal_dma_reader");

    // Initial values
    rst = 1'b1;

    reg_wr_addr = {REG_ADDR_WIDTH{1'b0}};
    reg_wr_data = {REG_DATA_WIDTH{1'b0}};
    reg_wr_strb = {REG_STRB_WIDTH{1'b0}};
    reg_wr_en = 1'b0;

    reg_rd_addr = {REG_ADDR_WIDTH{1'b0}};
    reg_rd_en = 1'b0;

    m_axis_dma_read_desc_ready = 1'b1;

    dma_ram_wr_cmd_sel = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
    dma_ram_wr_cmd_be = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
    dma_ram_wr_cmd_addr = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
    dma_ram_wr_cmd_data = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
    dma_ram_wr_cmd_valid = 1'b0;

    tail_slot_valid = 1'b1;
    commit_ready = 1'b1;

    // Reset
    repeat (10) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // Configure batch
    csr_write(REG_BATCH_ADDR_LO, TEST_DMA_BASE_ADDR[31:0]);
    csr_write(REG_BATCH_ADDR_HI, TEST_DMA_BASE_ADDR[63:32]);

    csr_write(REG_BATCH_STRIDE_LO, TEST_DMA_STRIDE[31:0]);
    csr_write(REG_BATCH_STRIDE_HI, TEST_DMA_STRIDE[63:32]);

    csr_write(REG_BATCH_COUNT, TEST_BATCH_COUNT);

    // Start batch: bit 0 = start
    csr_write(REG_BATCH_CONTROL, 32'h0000_0001);

    // Wait until all expected commits are observed
    wait (commit_count == TEST_BATCH_COUNT);

    repeat (10) @(posedge clk);

    // Check final batch status
    csr_read(REG_BATCH_STATUS, rd_data_tmp);

    $display("[%0t] Final batch status: 0x%0h", $time, rd_data_tmp);

    // bit 0: running
    // bit 1: done
    // bit 2: error
    if (rd_data_tmp[2:0] != 3'b010) begin
        $display("[%0t] ERROR: Final batch status indicates error or not done", $time);
        error_count = error_count + 1;
    end

    // Check committed proposal counter
    csr_read(REG_COUNTER, rd_data_tmp);

    $display("[%0t] Final proposal entry counter: %0d", $time, rd_data_tmp);

    if (rd_data_tmp != TEST_BATCH_COUNT) begin
        $display("[%0t] ERROR: Proposal entry counter does not match expected count", $time);
        error_count = error_count + 1;
    end

    // Check active index
    csr_read(REG_ACTIVE_INDEX, rd_data_tmp);

    $display("[%0t] Final active index: %0d", $time, rd_data_tmp);

    if (rd_data_tmp != TEST_BATCH_COUNT) begin
        $display("[%0t] ERROR: Active index does not match expected count", $time);
        error_count = error_count + 1;
    end

    // Check descriptor and commit counts
    if (dma_desc_count != TEST_BATCH_COUNT) begin
        $display("[%0t] ERROR: DMA descriptor count (%0d) does not match expected (%0d)", $time, dma_desc_count, TEST_BATCH_COUNT);
        error_count = error_count + 1;
    end

    if (commit_count != TEST_BATCH_COUNT) begin
        $display("[%0t] ERROR: Commit count (%0d) does not match expected (%0d)", $time, commit_count, TEST_BATCH_COUNT);
        error_count = error_count + 1;
    end

    if (error_count == 0) begin
        $display("[%0t] Test PASSED", $time);
    end else begin
        $display("[%0t] Test FAILED with %0d errors", $time, error_count);
    end

    $finish;
end

// =========================================================================
// Timeout
// =========================================================================
initial begin
    repeat (2000) @(posedge clk);
    $display("[%0t] ERROR: Test timed out", $time);
    $finish;
end

endmodule

`resetall
