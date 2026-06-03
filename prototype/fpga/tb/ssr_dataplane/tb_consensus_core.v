`timescale 1ns / 1ps

module tb_consensus_core;

// Testbench for consensus_core module
// This testbench instantiates a consensus_core along with

parameter CLOCK_PERIOD = 10;

//================================================
// Parameters and Signals
//================================================
parameter P_NODE_COUNT = 5;
parameter P_NODE_ID = 0;
parameter P_DATA_WIDTH = 512;
parameter P_KEEP_WIDTH = P_DATA_WIDTH / 8;
parameter P_LOG_ITEM_LEN = 40; // bytes

// Clock and reset
reg clk;
reg rst_n;

// Input signals
reg [63:0]      current_slot_id;
reg             slot_end_pulse;
reg             commit_start_pulse;
reg             new_slot_pulse;

// Matrix Inputs 
reg [P_NODE_COUNT-1:0]              i_knowledge_matrix[0:P_NODE_COUNT-1];

reg                                 i_rx_valid;
reg [7:0]                           i_rx_node_id;
reg [7:0]                           i_rx_knowledge_vec;
reg [P_LOG_ITEM_LEN*8-1:0]          i_rx_propose;

// Outputs
wire [P_NODE_COUNT-1:0]             o_alive_mask;
wire                                o_system_halt;

// Debug Signals
genvar i;
generate
    for (i = 0; i < P_NODE_COUNT; i = i + 1) begin : spy_matrix
        wire [P_NODE_COUNT-1:0] debug_knowledge_matrix;
        assign debug_knowledge_matrix = uut.r_knowledge_matrix[i];
    end 
endgenerate

//================================================
// DUT Instantiation
//================================================
consensus_core #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_NODE_ID(P_NODE_ID),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_LOG_ITEM_LEN(P_LOG_ITEM_LEN)
) uut (
    .clk(clk),
    .rst_n(rst_n),

    .i_current_slot_id(current_slot_id),
    .i_new_slot_pulse(new_slot_pulse),
    .i_commit_start_pulse(commit_start_pulse),
    .i_slot_end_pulse(slot_end_pulse),

    .i_rx_valid(i_rx_valid),
    .i_rx_node_id(i_rx_node_id),
    .i_rx_knowledge_vec(i_rx_knowledge_vec),
    .i_rx_propose(i_rx_propose),

    .o_alive_mask(o_alive_mask),
    .o_system_halt(o_system_halt)
);

//================================================
// Clock Generation
//================================================
initial begin
    clk = 0;
    forever #(CLOCK_PERIOD/2) clk = ~clk;
end

//================================================
// Test Sequence
//================================================
initial begin
    $dumpfile("tb_consensus_core.vcd");
    $dumpvars(0, tb_consensus_core);
    // Initialize inputs
    clk = 0;
    rst_n = 0;

    // Reset Inputs
    reset_inputs();

    // Release reset
    #100;
    rst_n = 1;
    #10;

    // Test Sequence
    // Case 1: Normal Operation
    $display("Test Case 1: Normal Operation");
    setup_matrix_normal();

    trigger_slot(1);

    // Case 2: Node 2 fails
    $display("Test Case 2: Node 2 Fails");
    i_knowledge_matrix[0][2] = 0;
    i_knowledge_matrix[1][2] = 0;
    i_knowledge_matrix[2] = 0; // Node 2 sees no one
    i_knowledge_matrix[3][2] = 0;
    i_knowledge_matrix[4][2] = 0;
    trigger_node2_fail_slot(2);

    // Case 3: Network Partition (Node 0 and Node 1 isolated)
    $display("Test Case 3: Network Partition");
    i_knowledge_matrix[0] = 2'b11; // Node 0 sees only Node 0 and Node 1
    i_knowledge_matrix[1] = 2'b11; // Node 1 sees only Node 0 and Node 1
    i_knowledge_matrix[2] = 5'b11111; // Node 2 sees all
    i_knowledge_matrix[3] = 5'b11111; // Node 3 sees all
    i_knowledge_matrix[4] = 5'b11111; // Node 4 sees all
    trigger_network_partition_slot(3);

    $display("Testbench completed.");
    $finish;
end

//=================================================
//    Helper Tasks
//=================================================
integer k;
task reset_inputs;
    begin
        current_slot_id = 0;
        slot_end_pulse = 0;
        commit_start_pulse = 0;
        new_slot_pulse = 0;
        i_rx_valid = 0;
        i_rx_node_id = 0;
        i_rx_knowledge_vec = 0;
        i_rx_propose = 0;

        for (k = 0; k < P_NODE_COUNT; k = k + 1) begin
            i_knowledge_matrix[k] = 0;
        end
    end
endtask

task setup_matrix_normal;
    begin
        // All nodes alive and know about each other
        integer m;
        for (m = 0; m < P_NODE_COUNT; m = m + 1) begin
            i_knowledge_matrix[m] <= {P_NODE_COUNT{1'b1}};
        end
    end
endtask

task trigger_slot;
    input [63:0] slot_id;
    begin
        current_slot_id = slot_id;

        @(posedge clk);
        new_slot_pulse <= 1;
        @(posedge clk);
        new_slot_pulse <= 0;

        // Input Knowledge Matrix

        for (k = 0; k < P_NODE_COUNT; k = k + 1) begin
            @(posedge clk);
            i_rx_valid <= 1;
            i_rx_node_id <= k;
            i_rx_knowledge_vec <= i_knowledge_matrix[k];
            i_rx_propose <= {P_LOG_ITEM_LEN*8{1'b1}}; // Dummy propose data
            @(posedge clk);
            i_rx_valid <= 0;

            // wait 5 cycles
            repeat (5) @(posedge clk);
        end
        @(posedge clk);
        i_rx_valid <= 0;

        // Wait for some cycles
        repeat (50) @(posedge clk); // wait 50 cycles

        @(posedge clk);
        commit_start_pulse <= 1;
        @(posedge clk);
        commit_start_pulse <= 0;

        // Wait for some cycles
        repeat (50) @(posedge clk); // wait 50 cycles
        @(posedge clk);
        slot_end_pulse <= 1;
        @(posedge clk);
        slot_end_pulse <= 0;

        // Wait for some cycles before next slot
        repeat (50) @(posedge clk); // wait 50 cycles
    end
endtask

task trigger_node2_fail_slot;
    input [63:0] slot_id;
    begin
        current_slot_id = slot_id;

        @(posedge clk);
        new_slot_pulse <= 1;
        @(posedge clk);
        new_slot_pulse <= 0;

        // Input Knowledge Matrix with Node 2 failed
        for (k = 0; k < P_NODE_COUNT; k = k + 1) begin
            @(posedge clk);
            if (k != 2) begin
                i_rx_valid <= 1;
                i_rx_node_id <= k;
                i_rx_knowledge_vec <= i_knowledge_matrix[k];
                i_rx_propose <= {P_LOG_ITEM_LEN*8{1'b1}}; // Dummy propose data
            end else begin
                // Node 2 does not send anything (failed)
                i_rx_valid <= 0;
            end
            @(posedge clk);
            i_rx_valid <= 0;

            // wait 5 cycles
            repeat (5) @(posedge clk);
        end
        @(posedge clk);
        i_rx_valid <= 0;

        // Wait for some cycles
        repeat (50) @(posedge clk); // wait 50 cycles

        @(posedge clk);
        commit_start_pulse <= 1;
        @(posedge clk);
        commit_start_pulse <= 0;

        // Wait for some cycles
        repeat (50) @(posedge clk); // wait 50 cycles
        @(posedge clk);
        slot_end_pulse <= 1;
        @(posedge clk);
        slot_end_pulse <= 0;

        // Wait for some cycles before next slot
        repeat (50) @(posedge clk); // wait 50 cycles
    end
endtask

task trigger_network_partition_slot;
    input [63:0] slot_id;
    begin
        current_slot_id = slot_id;

        @(posedge clk);
        new_slot_pulse <= 1;
        @(posedge clk);
        new_slot_pulse <= 0;

        // Input Knowledge Matrix with partition
        for (k = 0; k < P_NODE_COUNT - 3; k = k + 1) begin
            @(posedge clk);
            i_rx_valid <= 1;
            i_rx_node_id <= k;
            i_rx_knowledge_vec <= i_knowledge_matrix[k];
            i_rx_propose <= {P_LOG_ITEM_LEN*8{1'b1}}; // Dummy propose data
            @(posedge clk);
            i_rx_valid <= 0;

            // wait 5 cycles
            repeat (5) @(posedge clk);
        end
        @(posedge clk);
        i_rx_valid <= 0;

        // Wait for some cycles
        repeat (50) @(posedge clk); // wait 50 cycles

        @(posedge clk);
        commit_start_pulse <= 1;
        @(posedge clk);
        commit_start_pulse <= 0;

        // Wait for some cycles
        repeat (50) @(posedge clk); // wait 50 cycles
        @(posedge clk);
        slot_end_pulse <= 1;
        @(posedge clk);
        slot_end_pulse <= 0;

        // Wait for some cycles before next slot
        repeat (50) @(posedge clk); // wait 50 cycles
    end
endtask

endmodule
