`resetall
`timescale 1ns / 1ps
`default_nettype none

module tb_proposal_buffer;

// ==============================================================================
//              Parameters
// ==============================================================================

localparam DMA_LEN_WIDTH = 16;

localparam RAM_ADDR_WIDTH = 16; // 64KB in total
localparam RAM_SEG_COUNT = 2;
localparam RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT;  // 32 bytes per beat
localparam RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8;
localparam RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH);
localparam RAM_PIPELINE = 2;

localparam PROPOSAL_SLOT_BYTES = 1024; // 1KB per slot
localparam PROPOSAL_SLOT_COUNT = 64; // 64 slots in total

localparam integer RAM_BEAT_BYTES = RAM_SEG_COUNT * RAM_SEG_BE_WIDTH;
localparam integer PROPOSAL_SLOT_BEAT_COUNT = PROPOSAL_SLOT_BYTES / RAM_BEAT_BYTES;

localparam integer RAM_SEG_ADDR_WIDTH_VALUE = RAM_SEG_ADDR_WIDTH;

// ==============================================================================
//              Clock and reset
// ==============================================================================

reg clk = 1'b0;
reg rst = 1'b1;

always #5 clk = ~clk;

// ==============================================================================
//              DUT signals
// ==============================================================================

// Write interface
reg  [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]           buf_wr_be = 0;
reg  [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]         buf_wr_data = 0;
reg  [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]         buf_wr_addr = 0;
reg  [RAM_SEG_COUNT-1:0]                            buf_wr_valid = 0;
wire [RAM_SEG_COUNT-1:0]                            buf_wr_ready;
wire [RAM_SEG_COUNT-1:0]                            buf_wr_done;


// Tail slot interface
wire                                    tail_slot_valid;
wire [RAM_ADDR_WIDTH-1:0]               tail_slot_addr;
wire [DMA_LEN_WIDTH-1:0]                tail_slot_len;


// Commit interface
reg                                     tail_commit_valid;
wire                                    tail_commit_ready;

// TX streaming interface
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]         buf_rd_data;
wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]           buf_rd_be;
wire                                                buf_rd_valid;
reg                                                 buf_rd_ready;
wire                                                buf_tx_last;
wire [DMA_LEN_WIDTH-1:0]                            buf_tx_len;

// ==============================================================================
//              DUT instantiation
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
) dut (
    .clk(clk),
    .rst(rst),

    // Write interface
    .buf_wr_be(buf_wr_be),
    .buf_wr_data(buf_wr_data),
    .buf_wr_addr(buf_wr_addr),
    .buf_wr_valid(buf_wr_valid),
    .buf_wr_ready(buf_wr_ready),
    .buf_wr_done(buf_wr_done),

    // Tail slot interface
    .tail_slot_valid(tail_slot_valid),
    .tail_slot_addr(tail_slot_addr),
    .tail_slot_len(tail_slot_len),

    // Commit interface
    .tail_commit_valid(tail_commit_valid),
    .tail_commit_ready(tail_commit_ready),

    // TX streaming interface
    .buf_rd_data(buf_rd_data),
    .buf_rd_be(buf_rd_be),
    .buf_rd_valid(buf_rd_valid),
    .buf_rd_ready(buf_rd_ready),
    .buf_tx_last(buf_tx_last),
    .buf_tx_len(buf_tx_len)
);

// ==============================================================================
//          Test bookkeeping
// ==============================================================================
integer error_count = 0;
integer beat_index;
integer seg_index;

task check_error;
    input condition;
    input [1023:0] message;
    begin
        if (condition) begin
            $display("ERROR: %s", message);
            error_count = error_count + 1;
        end
    end
endtask

// ==============================================================================
//         Testbench data generator
// =============================================================================

function [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] make_beat_data;
    input integer slot_index;
    input integer beat_index;

    integer s;
    integer w;

    reg [RAM_SEG_DATA_WIDTH-1:0] seg_data;
    begin
        make_beat_data = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};

        for (s = 0; s < RAM_SEG_COUNT; s = s + 1) begin
            seg_data = {RAM_SEG_DATA_WIDTH{1'b0}};

            for (w = 0; w < RAM_SEG_DATA_WIDTH/32; w = w + 1) begin
                seg_data[w*32 +: 32] = 
                    32'hA0000000 |
                    ((slot_index & 8'hFF) << 16) |
                    ((beat_index & 8'hFF) << 8) |
                    ((s & 4'hF) << 4) |
                    (w & 4'hF);
            end

            make_beat_data[s*RAM_SEG_DATA_WIDTH +: RAM_SEG_DATA_WIDTH] = seg_data;
        end
    end
endfunction

// ==============================================================================
// Task: write one full slot through buf_wr interface
//
// This task emulates DMA write-back beats from proposal_dma_reader.
// It writes PROPOSAL_SLOT_BEAT_COUNT beats into the current tail slot
// ==============================================================================

task write_one_slot;
    input integer slot_index;

    integer beat;
    integer seg;
    integer base_row_addr;
    begin
        if (!tail_slot_valid) begin
            $display("[%0t] ERROR: tail_slot_valid is not asserted before writing slot %0d", $time, slot_index);
            error_count = error_count + 1;
        end

        base_row_addr = tail_slot_addr / RAM_BEAT_BYTES;

        $display("[%0t] Writing slot %0d: tail_slot_addr=0x%0h, base_row_addr=0x%0h, tail_slot_len=%0d", $time, slot_index, tail_slot_addr, base_row_addr, tail_slot_len);

        for (beat = 0; beat < PROPOSAL_SLOT_BEAT_COUNT; beat = beat + 1) begin
            @(negedge clk);

            buf_wr_valid = {RAM_SEG_COUNT{1'b1}};
            buf_wr_be = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};
            buf_wr_data = make_beat_data(slot_index, beat);

            for (seg = 0; seg < RAM_SEG_COUNT; seg = seg + 1) begin
                buf_wr_addr[seg*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH] = base_row_addr + beat;
            end

            // Wait until all segments accept this write beat
            @(posedge clk);
            #1;

            while (&buf_wr_ready != 1'b1) begin
                @(posedge clk);
                #1;
            end

            @(negedge clk);
            buf_wr_valid = {RAM_SEG_COUNT{1'b0}};
            buf_wr_be = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
            buf_wr_data = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
            buf_wr_addr = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
        end

        @(posedge clk);
        #1;
    end
endtask

// ==============================================================================
// Task: commit current tail slot
// ==============================================================================
task commit_tail_slot;
    begin
        @(negedge clk);
        tail_commit_valid = 1'b1;

        // Wait until tail_commit_ready is asserted
        @(posedge clk);
        #1;
        while (tail_commit_ready != 1'b1) begin
            @(posedge clk);
            #1;
        end

        @(negedge clk);
        tail_commit_valid = 1'b0;

        @(posedge clk);
        #1;
    end
endtask

// ==============================================================================
// Task: read and check one slot from buf_rd_*
//
// This task emulates tx_engine.
// It keeps buf_rd_ready high and checks every accepted beat.
// ==============================================================================
task read_and_check_one_slot;
    input integer slot_index;

    integer beat;
    integer timeout_count;
    reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] expected_data;
    reg expected_last;

    begin
        beat = 0;
        timeout_count = 0;

        buf_rd_ready = 1'b1;

        $display("[%0t] Reading slot %0d", $time, slot_index);

        // Make ready stable before the next clock edge
        @(negedge clk);
        buf_rd_ready = 1'b1;

        while (beat < PROPOSAL_SLOT_BEAT_COUNT) begin
            @(posedge clk);

            // IMPORTANT:
            // Check valid/ready at the clock edge.
            // Do not insert #1 before this check, because buf_rd_valid may be deasserted in the same clock edge when buf_rd_ready is deasserted.
            if (buf_rd_valid && buf_rd_ready) begin
                expected_data = make_beat_data(slot_index, beat);
                expected_last = (beat == PROPOSAL_SLOT_BEAT_COUNT - 1);

                if (buf_rd_data !== expected_data) begin
                    $display("[%0t] ERROR: buf_rd_data mismatch at slot %0d, beat %0d", $time, slot_index, beat);
                    $display("Expected: %h", expected_data);
                    $display("Received: %h", buf_rd_data);
                    error_count = error_count + 1;
                end

                if (buf_rd_be !== {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}}) begin
                    $display("[%0t] ERROR: buf_rd_be mismatch at slot %0d, beat %0d", $time, slot_index, beat);
                    error_count = error_count + 1;
                end

                beat = beat + 1;
                timeout_count = 0;
            end else begin
                timeout_count = timeout_count + 1;

                if (timeout_count > 100) begin
                    $display("[%0t] ERROR: Timeout waiting for buf_rd_valid at slot %0d, beat %0d", $time, slot_index, beat);
                    error_count = error_count + 1;
                    beat = PROPOSAL_SLOT_BEAT_COUNT; // exit the loop
                end
            end
        end

        @(negedge clk);
        buf_rd_ready = 1'b0;

        @(posedge clk);
    end
endtask

// ==============================================================================
// Task: read and check one slot with deterministic backpressure
//
// This task emulates tx_engine with periodic backpressure.
// It verifies:
//    1. Data is still read in correct order.
//    2. buf_rd_data / buf_rd_be / buf_tx_last stay stable while
//       buf_rd_valid is high and buf_rd_ready is low.
// ==============================================================================
task read_and_check_one_slot_with_backpressure;
    input integer slot_index;

    integer beat;
    integer stall_cycle;
    integer timeout_count;

    reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] expected_data;
    reg expected_last;

    reg holding_valid;
    reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] held_data;
    reg [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0] held_be;
    reg held_last;

    begin
        beat = 0;
        timeout_count = 0;

        $display("[%0t] Reading slot %0d with backpressure", $time, slot_index);

        // Start with ready low
        @(negedge clk);
        buf_rd_ready = 1'b0;

        while (beat < PROPOSAL_SLOT_BEAT_COUNT) begin
            // -------------------------------------------------
            // Wait until proposal_buffer presents a valid beat.
            //
            // We sample at negedge, so valid/data are already stable at this point.
            // after the previous posedge update.
            // -------------------------------------------------

            while (!buf_rd_valid) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;

                if (timeout_count > 2000) begin
                    $display("[%0t] ERROR: Timeout waiting for buf_rd_valid at slot %0d, beat %0d", $time, slot_index, beat);
                    error_count = error_count + 1;
                    beat = PROPOSAL_SLOT_BEAT_COUNT; // exit the loop
                end
            end

            timeout_count = 0;

            // Capture the stable valid beat while ready is low.
            held_data = buf_rd_data;
            held_be = buf_rd_be;
            held_last = buf_tx_last;

            // -------------------------------------------------
            // Hold ready low for several cycles and verify stability of valid beat.
            // -------------------------------------------------

            for (stall_cycle = 0; stall_cycle < 2; stall_cycle = stall_cycle + 1) begin
                @(posedge clk);
                @(negedge clk);

                if (buf_rd_valid !== 1'b1) begin
                    $display("[%0t] ERROR: buf_rd_valid deasserted while stalled at slot %0d, beat %0d", $time, slot_index, beat);
                    error_count = error_count + 1;
                end

                if (buf_rd_data !== held_data) begin
                    $display("[%0t] ERROR: buf_rd_data changed while stalled at slot %0d, beat %0d", $time, slot_index, beat);
                    $display("Expected: %h", held_data);
                    $display("Received: %h", buf_rd_data);
                    error_count = error_count + 1;
                end

                if (buf_rd_be !== held_be) begin
                    $display("[%0t] ERROR: buf_rd_be changed while stalled at slot %0d, beat %0d", $time, slot_index, beat);
                    error_count = error_count + 1;
                end

                if (buf_tx_last !== held_last) begin
                    $display("[%0t] ERROR: buf_tx_last changed while stalled at slot %0d, beat %0d", $time, slot_index, beat);
                    error_count = error_count + 1;
                end
            end

            // -------------------------------------------------
            // Now accept this beat.
            // ready must be stable before the next posedge.
            // -------------------------------------------------
            expected_data = make_beat_data(slot_index, beat);
            expected_last = (beat == PROPOSAL_SLOT_BEAT_COUNT - 1);

            @(negedge clk);
            buf_rd_ready = 1'b1;

            @(posedge clk);

            // Check the handshake beat at the clock edge.
            if (!(buf_rd_valid && buf_rd_ready)) begin
                $display("[%0t] ERROR: Handshake failed at slot %0d, beat %0d", $time, slot_index, beat);
                error_count = error_count + 1;
            end

            if (buf_rd_data !== expected_data) begin
                $display("[%0t] ERROR: buf_rd_data mismatch at slot %0d, beat %0d", $time, slot_index, beat);
                $display("Expected: %h", expected_data);
                $display("Received: %h", buf_rd_data);
                error_count = error_count + 1;
            end

            if (buf_tx_last !== expected_last) begin
                $display("[%0t] ERROR: buf_tx_last mismatch at slot %0d, beat %0d", $time, slot_index, beat);
                error_count = error_count + 1;
            end

            beat = beat + 1;

            // Drop ready agian after accepting one beat.
            @(negedge clk);
            buf_rd_ready = 1'b0;
        end

        @(posedge clk);
    end
endtask

// ==============================================================================
//                      Main test
// ==============================================================================
initial begin
    $dumpfile("build/tb_proposal_buffer.vcd");
    $dumpvars(0, tb_proposal_buffer);

    $display("[%0t] Starting testbench", $time);

    // Initialize signals
    rst = 1'b1;

    buf_wr_valid = {RAM_SEG_COUNT{1'b0}};
    buf_wr_be = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
    buf_wr_data = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
    buf_wr_addr = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};

    tail_commit_valid = 1'b0;
    buf_rd_ready = 1'b0;

    repeat (10) @(posedge clk);
    rst = 1'b0;
    repeat (50) @(posedge clk);
    #1;

    // ---------------------------------------------------------------
    // Test 1: reset state
    // ---------------------------------------------------------------
    $display("[%0t] Test 1: Reset state", $time);
    check_error(tail_slot_valid !== 1'b1, "tail_slot_valid should be 1 after reset"); 
    check_error(tail_slot_addr !== 0, "tail_slot_addr should be 0 after reset");
    check_error(tail_slot_len !== PROPOSAL_SLOT_BYTES, "tail_slot_len should be PROPOSAL_SLOT_BYTES after reset");
    check_error(buf_rd_valid !== 1'b0, "buf_rd_valid should be 0 after reset");

    $display("[%0t] Test 1 completed", $time);

    // ---------------------------------------------------------------
    // Test 2: write one slot but do not commit
    // TX side should not produce valid data.
    // ---------------------------------------------------------------
    write_one_slot(0);

    repeat (20) @(posedge clk);
    #1;

    check_error(buf_rd_valid !== 1'b0, "buf_rd_valid should be 0 after writing one slot but not committing");

    $display("[%0t] Test 2 completed", $time);

    // ---------------------------------------------------------------
    // Test 3: commit the slot and read it back
    // ---------------------------------------------------------------
    commit_tail_slot();

    read_and_check_one_slot(0);

    $display("[%0t] Test 3 completed", $time);

    // ---------------------------------------------------------------
    // Test 4: write and read multiple slots in order
    // ---------------------------------------------------------------
    write_one_slot(1);
    commit_tail_slot();

    write_one_slot(2);
    commit_tail_slot();

    read_and_check_one_slot(1);
    read_and_check_one_slot(2);

    $display("[%0t] Test 4 completed", $time);

    // ---------------------------------------------------------------
    // Test 5: write and read multiple slots with backpressure
    // ---------------------------------------------------------------
    write_one_slot(3);
    commit_tail_slot();

    read_and_check_one_slot_with_backpressure(3);

    $display("[%0t] Test 5 completed", $time);

    // ---------------------------------------------------------------
    // Final result
    // ---------------------------------------------------------------
    repeat (10) @(posedge clk);

    if (error_count == 0) begin
        $display("[%0t] All tests passed!", $time);
    end else begin
        $display("[%0t] Test completed with %0d errors", $time, error_count);
    end

    $finish;

end

// =============================================================================
// Timeout
// =============================================================================
initial begin
    repeat (5000) @(posedge clk);
    $display("[%0t] ERROR: Testbench timeout", $time);
    $finish;
end

endmodule

`resetall
