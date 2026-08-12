`resetall
`timescale 1ns / 1ps
`default_nettype none

module tb_proposal_path;

// ==============================================================================
//                     Parameters
// ==============================================================================

localparam REG_ADDR_WIDTH = 12;
localparam REG_DATA_WIDTH = 32;
localparam REG_STRB_WIDTH = REG_DATA_WIDTH / 8;
localparam RB_BASE_ADDR = 32'h0000_0000;

localparam DMA_ADDR_WIDTH = 64;
localparam DMA_LEN_WIDTH = 16;
localparam DMA_TAG_WIDTH = 16;

localparam RAM_SEL_WIDTH = 4;
localparam RAM_ADDR_WIDTH = 16;
localparam RAM_SEG_COUNT = 2;
localparam RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT;
localparam RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH / 8;
localparam RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH);
localparam RAM_PIPELINE = 2;

localparam RAM_SEL_PROP = 0;
localparam DMA_TAG_PROP = 0;

localparam PROPOSAL_SLOT_BYTES = 1024;
localparam PROPOSAL_SLOT_COUNT = 64;

localparam integer RAM_BEAT_BYTES = RAM_SEG_COUNT * RAM_SEG_BE_WIDTH;
localparam integer PROPOSAL_SLOT_BEAT_COUNT = PROPOSAL_SLOT_BYTES / RAM_BEAT_BYTES;

localparam [DMA_ADDR_WIDTH-1:0] HOST_BASE_ADDR = 64'h0000_0000_0000_0000;
localparam [DMA_ADDR_WIDTH-1:0] HOST_STRIDE = PROPOSAL_SLOT_BYTES;
localparam [DMA_ADDR_WIDTH-1:0] HOST_BASE_ADDR_TEST2 = HOST_BASE_ADDR + HOST_STRIDE;

// ==============================================================================
//                     Clock and Reset
// ==============================================================================

reg clk = 1'b0;
reg rst = 1'b0;

always #5 clk = ~clk;

// ==============================================================================
//                    CSR register interface to proposal_dma_reader
// ==============================================================================
reg  [REG_ADDR_WIDTH-1:0]       reg_wr_addr = 0;
reg  [REG_DATA_WIDTH-1:0]       reg_wr_data = 0;
reg  [REG_STRB_WIDTH-1:0]       reg_wr_strb = 0;
reg                             reg_wr_en = 0;
wire                            reg_wr_wait;
wire                            reg_wr_ack;

reg  [REG_ADDR_WIDTH-1:0]       reg_rd_addr = 0;
wire [REG_DATA_WIDTH-1:0]       reg_rd_data;
reg                             reg_rd_en = 0;
wire                            reg_rd_wait;
wire                            reg_rd_ack;

// proposal_dma_reader CSR offsets
localparam [REG_ADDR_WIDTH-1:0] REG_PROP_BASE_ADDR_LO   = 12'h100;
localparam [REG_ADDR_WIDTH-1:0] REG_PROP_BASE_ADDR_HI   = 12'h104;
localparam [REG_ADDR_WIDTH-1:0] REG_PROP_STRIDE_LO      = 12'h10c;
localparam [REG_ADDR_WIDTH-1:0] REG_PROP_STRIDE_HI      = 12'h110;

localparam [REG_ADDR_WIDTH-1:0] REG_PROP_COUNT          = 12'h114;
localparam [REG_ADDR_WIDTH-1:0] REG_PROP_CONTROL        = 12'h118;

localparam [REG_ADDR_WIDTH-1:0] REG_PROP_STATUS         = 12'h11c;
localparam [REG_ADDR_WIDTH-1:0] REG_PROP_ACTIVE_SLOT    = 12'h120;



// ==============================================================================
//                    DMA read descriptor interface
// ==============================================================================
wire [DMA_ADDR_WIDTH-1:0]       m_axis_dma_read_desc_dma_addr;
wire [RAM_SEL_WIDTH-1:0]        m_axis_dma_read_desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0]       m_axis_dma_read_desc_ram_addr;
wire [DMA_LEN_WIDTH-1:0]        m_axis_dma_read_desc_len;
wire [DMA_TAG_WIDTH-1:0]        m_axis_dma_read_desc_tag;
wire                            m_axis_dma_read_desc_valid;
reg                             m_axis_dma_read_desc_ready = 1'b1;

// ==============================================================================
//                   DMA read status interface
// ==============================================================================
reg  [DMA_TAG_WIDTH-1:0]        s_axis_dma_read_desc_status_tag = 0;
reg                             s_axis_dma_read_desc_status_valid = 0;
reg  [3:0]                      s_axis_dma_read_desc_status_error = 4'd0;

// ==============================================================================
//  Fake DMA RAM write-back interface into proposal_buffer
// ==============================================================================
reg  [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]              dma_ram_wr_cmd_sel = 0;
reg  [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]           dma_ram_wr_cmd_be = 0;
reg  [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]         dma_ram_wr_cmd_addr = 0;
reg  [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]         dma_ram_wr_cmd_data = 0;
reg  [RAM_SEG_COUNT-1:0]                            dma_ram_wr_cmd_valid = 0;
wire [RAM_SEG_COUNT-1:0]                            dma_ram_wr_cmd_ready;
wire [RAM_SEG_COUNT-1:0]                            dma_ram_wr_done;

// ==============================================================================
// proposal_dma_reader -> proposal_buffer write interface
// ==============================================================================
wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]           buf_wr_be;
wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]         buf_wr_addr;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]         buf_wr_data;
wire [RAM_SEG_COUNT-1:0]                            buf_wr_valid;
wire [RAM_SEG_COUNT-1:0]                            buf_wr_ready;
wire [RAM_SEG_COUNT-1:0]                            buf_wr_done;

// ==============================================================================
// proposal_buffer -> proposal_dma_reader read interface
// ==============================================================================
wire                                                tail_slot_valid;
wire [RAM_ADDR_WIDTH-1:0]                           tail_slot_addr;
wire [DMA_LEN_WIDTH-1:0]                            tail_slot_len;

// ==============================================================================
// proposal_dma_reader -> proposal_buffer commit interface
// ==============================================================================
wire                                                tail_commit_valid;
wire                                                tail_commit_ready;

// ==============================================================================
// proposal_buffer -> fake tx_engine streaming interface
// ==============================================================================
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]         buf_rd_data;
wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]           buf_rd_be;
wire                                                buf_rd_valid;
reg                                                 buf_rd_ready = 1'b0;
wire                                                buf_tx_last;
wire [DMA_LEN_WIDTH-1:0]                            buf_tx_len;


// ==============================================================================
// DUT 1: proposal_dma_reader   
// ==============================================================================
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
    .RAM_PIPELINE(RAM_PIPELINE),

    .RAM_SEL_PROP(RAM_SEL_PROP),
    .DMA_TAG_PROP(DMA_TAG_PROP),
    .PROPOSAL_SLOT_BYTES(PROPOSAL_SLOT_BYTES)
)
proposal_dma_reader_inst (
    .clk(clk),
    .rst(rst),

    // CSR register interface
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

    // DMA read descriptor interface
    .m_axis_dma_read_desc_dma_addr(m_axis_dma_read_desc_dma_addr),
    .m_axis_dma_read_desc_ram_sel(m_axis_dma_read_desc_ram_sel),
    .m_axis_dma_read_desc_ram_addr(m_axis_dma_read_desc_ram_addr),
    .m_axis_dma_read_desc_len(m_axis_dma_read_desc_len),
    .m_axis_dma_read_desc_tag(m_axis_dma_read_desc_tag),
    .m_axis_dma_read_desc_valid(m_axis_dma_read_desc_valid),
    .m_axis_dma_read_desc_ready(m_axis_dma_read_desc_ready),

    .s_axis_dma_read_desc_status_tag(s_axis_dma_read_desc_status_tag),
    .s_axis_dma_read_desc_status_valid(s_axis_dma_read_desc_status_valid),
    .s_axis_dma_read_desc_status_error(s_axis_dma_read_desc_status_error),

    .dma_ram_wr_cmd_sel(dma_ram_wr_cmd_sel),
    .dma_ram_wr_cmd_be(dma_ram_wr_cmd_be),
    .dma_ram_wr_cmd_addr(dma_ram_wr_cmd_addr),
    .dma_ram_wr_cmd_data(dma_ram_wr_cmd_data),
    .dma_ram_wr_cmd_valid(dma_ram_wr_cmd_valid),
    .dma_ram_wr_cmd_ready(dma_ram_wr_cmd_ready),
    .dma_ram_wr_done(dma_ram_wr_done),

    .buf_wr_be(buf_wr_be),
    .buf_wr_addr(buf_wr_addr),
    .buf_wr_data(buf_wr_data),
    .buf_wr_valid(buf_wr_valid),
    .buf_wr_ready(buf_wr_ready),
    .buf_wr_done(buf_wr_done),

    .tail_slot_valid(tail_slot_valid),
    .tail_slot_addr(tail_slot_addr),
    .tail_slot_len(tail_slot_len),

    .commit_valid(tail_commit_valid),
    .commit_ready(tail_commit_ready)
);

// ==============================================================================
// DUT 2: proposal_buffer
// ==============================================================================
proposal_buffer #(
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),

    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE),

    .PROPOSAL_SLOT_BYTES(PROPOSAL_SLOT_BYTES),
    .PROPOSAL_SLOT_COUNT(PROPOSAL_SLOT_COUNT)
)
proposal_buffer_inst (
    .clk(clk),
    .rst(rst),

    .buf_wr_be(buf_wr_be),
    .buf_wr_addr(buf_wr_addr),
    .buf_wr_data(buf_wr_data),
    .buf_wr_valid(buf_wr_valid),
    .buf_wr_ready(buf_wr_ready),
    .buf_wr_done(buf_wr_done),

    .tail_slot_valid(tail_slot_valid),
    .tail_slot_addr(tail_slot_addr),
    .tail_slot_len(tail_slot_len),

    .tail_commit_valid(tail_commit_valid),
    .tail_commit_ready(tail_commit_ready),

    .buf_rd_data(buf_rd_data),
    .buf_rd_be(buf_rd_be),
    .buf_rd_valid(buf_rd_valid),
    .buf_rd_ready(buf_rd_ready),
    .buf_tx_last(buf_tx_last),
    .buf_tx_len(buf_tx_len)
);

// ==============================================================================
//                    Testbench tasks
// ==============================================================================
integer error_count = 0;

function [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] make_beat_data;
    input integer proposal_index;
    input integer beat_index;

    integer seg;
    integer word;
    reg [RAM_SEG_DATA_WIDTH-1:0] seg_data;
    reg [31:0] word_data;

    begin
        make_beat_data = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};

        for (seg = 0; seg < RAM_SEG_COUNT; seg = seg + 1) begin
            seg_data = {RAM_SEG_DATA_WIDTH{1'b0}};

            for (word = 0; word < RAM_SEG_DATA_WIDTH/32; word = word + 1) begin
                word_data = 
                    32'hA000_0000 | 
                    ((proposal_index & 8'hFF) << 16) |
                    ((beat_index & 8'hFF) << 8) |
                    ((seg & 4'hF) << 4) |
                    (word & 4'hF);

                seg_data[word*32 +: 32] = word_data;
            end

            make_beat_data[seg*RAM_SEG_DATA_WIDTH +: RAM_SEG_DATA_WIDTH] = seg_data;
        end
    end
endfunction

task csr_write;
    input [REG_ADDR_WIDTH-1:0] addr;
    input [REG_DATA_WIDTH-1:0] data;

    begin
        @(negedge clk);
        reg_wr_addr = addr;
        reg_wr_data = data;
        reg_wr_strb = {REG_STRB_WIDTH{1'b1}};
        reg_wr_en   = 1'b1;

        @(posedge clk);

        @(negedge clk);
        reg_wr_en = 1'b0;
        reg_wr_addr = 0;
        reg_wr_data = 0;
        reg_wr_strb = 0;

        @(posedge clk);
    end
endtask

//  Wait and check one DMA descriptor
task wait_and_check_dma_desc;
    input integer proposal_index;

    integer timeout_count;

    reg [DMA_ADDR_WIDTH-1:0]    expected_dma_addr;
    reg [RAM_SEL_WIDTH-1:0]     expected_ram_addr;
    reg [DMA_LEN_WIDTH-1:0]     expected_len;
    reg [DMA_TAG_WIDTH-1:0]     expected_tag;

    begin
        timeout_count = 0;

        expected_dma_addr   = HOST_BASE_ADDR + proposal_index * HOST_STRIDE;
        expected_ram_addr   = proposal_index * PROPOSAL_SLOT_BYTES;
        expected_len        = PROPOSAL_SLOT_BYTES;
        expected_tag        = DMA_TAG_PROP + proposal_index;

        while (!(m_axis_dma_read_desc_valid && m_axis_dma_read_desc_ready)) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;

            if (timeout_count > 1000) begin
                $display("[%0t] ERROR: Timeout waiting for DMA descriptor", $time);
                error_count = error_count + 1;
                disable wait_and_check_dma_desc;
            end
        end

        $display("[%0t] DMA descriptor valid: addr=0x%h, ram_sel=0x%h, ram_addr=0x%h, len=%0d, tag=%0d",
            $time,
            m_axis_dma_read_desc_dma_addr,
            m_axis_dma_read_desc_ram_sel,
            m_axis_dma_read_desc_ram_addr,
            m_axis_dma_read_desc_len,
            m_axis_dma_read_desc_tag);

        if (m_axis_dma_read_desc_dma_addr !== expected_dma_addr) begin
            $display("[%0t] ERROR: DMA addr mismatch: expected=0x%h, got=0x%h", $time, expected_dma_addr, m_axis_dma_read_desc_dma_addr);
            error_count = error_count + 1;
        end

        if (m_axis_dma_read_desc_ram_addr !== expected_ram_addr) begin
            $display("[%0t] ERROR: RAM addr mismatch: expected=0x%h, got=0x%h", $time, expected_ram_addr, m_axis_dma_read_desc_ram_addr);
            error_count = error_count + 1;
        end

        if (m_axis_dma_read_desc_len !== expected_len) begin
            $display("[%0t] ERROR: Length mismatch: expected=%0d, got=%0d", $time, expected_len, m_axis_dma_read_desc_len);
            error_count = error_count + 1;
        end

        if (m_axis_dma_read_desc_tag !== expected_tag) begin
            $display("[%0t] ERROR: Tag mismatch: expected=%0d, got=%0d", $time, expected_tag, m_axis_dma_read_desc_tag);
            error_count = error_count + 1;
        end

        @(posedge clk);
    end
endtask

// Drive one fake DMA RAM write-back beat
task drive_dma_write_beat;
    input integer base_row_addr;
    input integer proposal_index;
    input integer beat_index;

    integer seg;

    begin
        @(negedge clk);

        dma_ram_wr_cmd_valid = {RAM_SEG_COUNT{1'b1}};
        dma_ram_wr_cmd_be  = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};
        dma_ram_wr_cmd_data = make_beat_data(proposal_index, beat_index);

        for (seg = 0; seg < RAM_SEG_COUNT; seg = seg + 1) begin
            dma_ram_wr_cmd_sel[seg*RAM_SEL_WIDTH +: RAM_SEL_WIDTH] = RAM_SEL_PROP;
            dma_ram_wr_cmd_addr[seg*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH] = base_row_addr + beat_index;
        end

        @(posedge clk);
        #1;

        while (&dma_ram_wr_cmd_ready !== 1'b1) begin
            @(posedge clk);
            #1;
        end

        @(negedge clk);

        dma_ram_wr_cmd_valid = {RAM_SEG_COUNT{1'b0}};
        dma_ram_wr_cmd_be  = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
        dma_ram_wr_cmd_data = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
        dma_ram_wr_cmd_sel  = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
        dma_ram_wr_cmd_addr = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};

        @(posedge clk);
        #1;
    end
endtask

task send_dma_status_success;
    input [DMA_TAG_WIDTH-1:0] tag;

    begin
        @(negedge clk);

        s_axis_dma_read_desc_status_tag = tag;
        s_axis_dma_read_desc_status_error = 4'd0;
        s_axis_dma_read_desc_status_valid = 1'b1;

        @(posedge clk);
        @(negedge clk);

        s_axis_dma_read_desc_status_tag = 0;
        s_axis_dma_read_desc_status_valid = 1'b0;
        s_axis_dma_read_desc_status_error = 4'd0;

        @(posedge clk);

        $display("[%0t] Sent DMA status success for tag %0d", $time, tag);
    end
endtask

// Fake DAM engine: service one descriptor
task fake_dma_serivce_one_desc;
    input integer proposal_index;

    integer beat;
    integer timeout_count;
    integer base_row_addr;

    reg [DMA_ADDR_WIDTH-1:0]    desc_dma_addr;
    reg [RAM_SEL_WIDTH-1:0]     desc_ram_sel;
    reg [RAM_ADDR_WIDTH-1:0]    desc_ram_addr;
    reg [DMA_LEN_WIDTH-1:0]     desc_len;
    reg [DMA_TAG_WIDTH-1:0]     desc_tag;

    begin
        timeout_count = 0;

        // Wait for descriptor handshake
        while (!(m_axis_dma_read_desc_valid && m_axis_dma_read_desc_ready)) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;

            if (timeout_count > 1000) begin
                $display("[%0t] ERROR: Timeout waiting for DMA descriptor", $time);
                error_count = error_count + 1;
                disable fake_dma_serivce_one_desc;
            end
        end

        desc_dma_addr   = m_axis_dma_read_desc_dma_addr;
        desc_ram_sel    = m_axis_dma_read_desc_ram_sel;
        desc_ram_addr   = m_axis_dma_read_desc_ram_addr;
        desc_len        = m_axis_dma_read_desc_len;
        desc_tag        = m_axis_dma_read_desc_tag;

        $display("[%0t] Fake DMA engine received descriptor: proposal_index=%0d, dma_addr=0x%h, ram_sel=0x%h, ram_addr=0x%h, len=%0d, tag=%0d",
            $time,
            proposal_index,
            desc_dma_addr,
            desc_ram_sel,
            desc_ram_addr,
            desc_len,
            desc_tag);
        
        if (desc_len !== PROPOSAL_SLOT_BYTES) begin
            $display("[%0t] ERROR: Descriptor length mismatch: expected=%0d, got=%0d", $time, PROPOSAL_SLOT_BYTES, desc_len);
            error_count = error_count + 1;
        end

        if (desc_ram_sel !== RAM_SEL_PROP) begin
            $display("[%0t] ERROR: Descriptor RAM select mismatch: expected=0x%h, got=0x%h", $time, RAM_SEL_PROP, desc_ram_sel);
            error_count = error_count + 1;
        end

        // descriptor ram_addr is byte address
        // dma_ram_wr_cmd_addr is RAM row address
        base_row_addr = desc_ram_addr / RAM_BEAT_BYTES;

        for (beat = 0; beat < PROPOSAL_SLOT_BEAT_COUNT; beat = beat + 1) begin
            drive_dma_write_beat(base_row_addr, proposal_index, beat);
        end

        send_dma_status_success(desc_tag);
    end
endtask

// Fake tx_engine: read one proposal slot from proposal_buffer
task read_and_check_one_slot;
    input integer proposal_index;

    integer beat;
    integer timeout_count;

    reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] expected_data;
    reg expected_last;

    begin
        beat = 0;
        timeout_count = 0;

        $display("[%0t] Fake tx_engine: reading proposal slot %0d", $time, proposal_index);

        @(negedge clk);
        buf_rd_ready = 1'b1;

        while (beat < PROPOSAL_SLOT_BEAT_COUNT) begin
            @(posedge clk);

            if (buf_rd_valid && buf_rd_ready) begin
                expected_data = make_beat_data(proposal_index, beat);
                expected_last = (beat == PROPOSAL_SLOT_BEAT_COUNT - 1);

                if (buf_rd_data !== expected_data) begin
                    $display("[%0t] ERROR: Proposal slot data mismatch at beat %0d: expected=0x%h, got=0x%h", $time, beat, expected_data, buf_rd_data);
                    $display("[%0t] Expected data: %h", $time, expected_data);
                    $display("[%0t] Got data:      %h", $time, buf_rd_data);
                    error_count = error_count + 1;
                end

                if (buf_rd_be !== {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}}) begin
                    $display("[%0t] ERROR: Proposal slot BE mismatch at beat %0d: expected=0x%h, got=0x%h", $time, beat, {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}}, buf_rd_be);
                    error_count = error_count + 1;
                end

                if (buf_tx_last !== expected_last) begin
                    $display("[%0t] ERROR: Proposal slot last mismatch at beat %0d: expected=%0b, got=%0b", $time, beat, expected_last, buf_tx_last);
                    error_count = error_count + 1;
                end

                beat = beat + 1;
                timeout_count = 0;
            end else begin
                timeout_count = timeout_count + 1;

                if (timeout_count > 1000) begin
                    $display("[%0t] ERROR: Timeout waiting for proposal slot data", $time);
                    error_count = error_count + 1;
                    disable read_and_check_one_slot;
                end
            end
        end

        @(negedge clk);
        buf_rd_ready = 1'b0;

        @(posedge clk);
        $display("[%0t] Fake tx_engine: completed reading proposal slot %0d",
            $time, proposal_index);
    end
endtask

// ==============================================================================
//                          Main
// ==============================================================================

initial begin
    $display("build/tb_proposal_path.vcd");
    $dumpvars(0, tb_proposal_path);

    $display("[%0t] Starting tb_proposal_path", $time);

    rst = 1'b1;

    reg_wr_addr = 0;
    reg_wr_data = 0;
    reg_wr_strb = 0;
    reg_wr_en = 1'b0;

    reg_rd_addr = 0;
    reg_rd_en = 1'b0;

    m_axis_dma_read_desc_ready = 1'b1;

    s_axis_dma_read_desc_status_tag = 0;
    s_axis_dma_read_desc_status_valid = 1'b0;
    s_axis_dma_read_desc_status_error = 4'd0;

    dma_ram_wr_cmd_sel = 0;
    dma_ram_wr_cmd_be = 0;
    dma_ram_wr_cmd_addr = 0;
    dma_ram_wr_cmd_data = 0;
    dma_ram_wr_cmd_valid = 0;

    buf_rd_ready = 1'b0;

    repeat (10) @(posedge clk);
    rst = 1'b0;
    repeat (10) @(posedge clk);

    $display("[%0t] Structural integration reset completed", $time);

    // -----------------------------------------------
    // Test 1: CSR start -> first DMA descriptor
    // -----------------------------------------------
    $display("[%0t] Test 1: CSR start -> first DMA descriptor", $time);
    csr_write(REG_PROP_BASE_ADDR_LO, HOST_BASE_ADDR[31:0]);
    csr_write(REG_PROP_BASE_ADDR_HI, HOST_BASE_ADDR[63:32]);
    csr_write(REG_PROP_STRIDE_LO, HOST_STRIDE[31:0]);
    csr_write(REG_PROP_STRIDE_HI, HOST_STRIDE[63:32]);
    csr_write(REG_PROP_COUNT, 32'd1);

    csr_write(REG_PROP_CONTROL, 32'h1); // Start

    fake_dma_serivce_one_desc(0);

    // Give proposal_dma_reader time to process DMA status and commit the slot
    repeat (20) @(posedge clk);

    // After one successful commit, proposal_buffer tail should move to slot 1.
    // slot 1 byte address = 0x0000_0400 = 1024
    if (tail_slot_addr !== 32'h0000_0400) begin
        $display("[%0t] ERROR: tail_slot_addr mismatch: expected=0x%h, got=0x%h", $time, 32'h0000_0400, tail_slot_addr);
        error_count = error_count + 1;
    end

    // Read back the committed proposal from proposal_buffer and check the data
    read_and_check_one_slot(0);

    $display("[%0t] Test 1 completed", $time);

    // -----------------------------------------------
    // Test 2: batch of 3 proposals
    // -----------------------------------------------
    $display("[%0t] Test 2: batch of 3 proposals", $time);
    csr_write(REG_PROP_CONTROL, 32'h0); // Stop

    csr_write(REG_PROP_BASE_ADDR_LO, HOST_BASE_ADDR_TEST2[31:0]);
    csr_write(REG_PROP_BASE_ADDR_HI, HOST_BASE_ADDR_TEST2[63:32]);
    csr_write(REG_PROP_STRIDE_LO, HOST_STRIDE[31:0]);
    csr_write(REG_PROP_STRIDE_HI, HOST_STRIDE[63:32]);
    csr_write(REG_PROP_COUNT, 32'd3);

    csr_write(REG_PROP_CONTROL, 32'h1); // Start    

    fake_dma_serivce_one_desc(1);
    fake_dma_serivce_one_desc(2);
    fake_dma_serivce_one_desc(3);

    // Give proposal_dma_reader time to process DMA status and commit the slots
    repeat (20) @(posedge clk);

    // After Test 1 + Test 2, tail should point to slot 4.
    // slot 4 byte address = 4 * 1024 = 0x0000_1000
    if (tail_slot_addr !== 32'h0000_1000) begin
        $display("[%0t] ERROR: tail_slot_addr mismatch after Test 2: expected=0x%h, got=0x%h", $time, 32'h0000_1000, tail_slot_addr);
        error_count = error_count + 1;
    end

    read_and_check_one_slot(1);
    read_and_check_one_slot(2);
    read_and_check_one_slot(3);

    $display("[%0t] Test 2 completed", $time);

    repeat (20) @(posedge clk);

    if (error_count == 0) begin
        $display("[%0t] All tests passed", $time);
    end else begin
        $display("[%0t] %0d errors detected", $time, error_count);
    end

    $finish;
end

initial begin
    repeat (5000) @(posedge clk);
    $display("[%0t] Timeout reached", $time);
    $finish;
end

endmodule

`resetall
