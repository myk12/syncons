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
reg [63:0]                          current_slot_id;
reg                                 new_slot_pulse;
reg [63:0]                          i_ctrl_membership_epoch;
reg [63:0]                          i_ctrl_run_id;
reg [P_NODE_COUNT-1:0]              i_ctrl_membership;
reg                                 i_ctrl_activate;
reg                                 i_ctrl_reboot;
reg [P_LOG_ITEM_LEN*8-1:0]          i_ctrl_host_payload;
reg [7:0]                           i_rx_sound_bitmap;
reg [63:0]                          i_rx_run_id;
reg [63:0]                          i_rx_round_id;

reg                                 i_rx_valid;
reg [7:0]                           i_rx_node_id;
reg [P_LOG_ITEM_LEN*8-1:0]          i_rx_propose;

// Outputs
wire [P_NODE_COUNT-1:0]             o_alive_mask;
wire                                o_system_halt;

wire [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]  o_commit_log;
wire [P_NODE_COUNT-1:0]                   o_commit_valid;
wire [P_NODE_COUNT-1:0]                   o_tx_knowledge_vec;
wire [P_LOG_ITEM_LEN*8-1:0]               o_tx_propose;

// Debug Signals
// (Debug monitoring disabled - internal signals not exposed)

//================================================
// DUT Instantiation
//================================================
consensus_core #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_NODE_ID(P_NODE_ID),
    .P_LOG_ITEM_LEN(P_LOG_ITEM_LEN)
) uut (
    .clk(clk),
    .rst_n(rst_n),

    .i_current_slot_id(current_slot_id),
    .i_new_slot_pulse(new_slot_pulse),

    .i_rx_valid(i_rx_valid),
    .i_rx_node_id(i_rx_node_id),
    .i_rx_sound_bitmap(i_rx_sound_bitmap),
    .i_rx_payload(i_rx_propose),
    .i_rx_run_id(i_rx_run_id),
    .i_rx_round_id(i_rx_round_id),

    .i_ctrl_membership_epoch(i_ctrl_membership_epoch),
    .i_ctrl_run_id(i_ctrl_run_id),
    .i_ctrl_membership(i_ctrl_membership),
    .i_ctrl_activate(i_ctrl_activate),
    .i_ctrl_reboot(i_ctrl_reboot),
    .i_ctrl_host_payload(i_ctrl_host_payload),

     .o_alive_mask(o_alive_mask),
     .o_system_halt(o_system_halt),
     .o_commit_log(o_commit_log),
     .o_commit_valid(o_commit_valid),
     .o_tx_knowledge_vec(o_tx_knowledge_vec),
     .o_tx_propose(o_tx_propose)
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

    // Test Case 1: Normal Operation (all 3 nodes active)
    $display("Test Case 1: Normal Operation");
    test_normal_agreement();
    
    #100;
    
    // Test Case 2: Node 2 Fails
    $display("\nTest Case 2: Node 2 Fails");
    rst_n = 0;
    #10 rst_n = 1;
    #10;
    test_node_failure();
    
    #100;
    
    // Test Case 3: Network Partition
    $display("\nTest Case 3: Network Partition");
    rst_n = 0;
    #10 rst_n = 1;
    #10;
    test_network_partition();
    
    #100;
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
        new_slot_pulse = 0;
        i_rx_valid = 0;
        i_rx_node_id = 0;
        i_rx_sound_bitmap = 0;
        i_rx_propose = 0;
        i_rx_run_id = 0;
        i_rx_round_id = 0;
        
        i_ctrl_activate = 0;
        i_ctrl_membership_epoch = 0;
        i_ctrl_run_id = 0;
        i_ctrl_membership = 0;
        i_ctrl_host_payload = 0;
        i_ctrl_reboot = 0;
    end
endtask

task initialize_core;
    input [P_NODE_COUNT-1:0] membership;
    begin
        @(posedge clk);
        i_ctrl_activate <= 1;
        i_ctrl_membership_epoch <= 0;
        i_ctrl_run_id <= 1;
        i_ctrl_membership <= membership;
        i_ctrl_host_payload <= 64'hAAAAAAAAAAAAAAAA;
        i_ctrl_reboot <= 0;
        @(posedge clk);
        i_ctrl_activate <= 0;
        repeat(5) @(posedge clk);
    end
endtask

task trigger_round_with_packets;
    input [63:0] round_id;
    input [63:0] run_id;
    input [P_NODE_COUNT-1:0] active_nodes;  // bitmap of nodes sending packets
    input [P_NODE_COUNT * P_NODE_COUNT - 1:0] sound_bitmaps_packed;  // packed: {sound_bitmaps[P_NODE_COUNT-1],...,sound_bitmaps[0]}
    integer n;
    begin
        // Trigger round start
        @(posedge clk);
        new_slot_pulse <= 1;
        current_slot_id <= round_id;
        @(posedge clk);
        new_slot_pulse <= 0;
        
        // Send packets from active nodes
        for (n = 1; n < P_NODE_COUNT; n = n + 1) begin
            if (active_nodes[n]) begin
                send_packet(n, run_id, round_id, sound_bitmaps_packed[n * P_NODE_COUNT +: P_NODE_COUNT]);
            end
        end
        
        // Wait for processing
        repeat(50) @(posedge clk);
        round_id <= round_id + 1;
        current_slot_id <= round_id;
        
        // Monitor outputs
        $display("Round %0d: commit_valid=%b, halt=%b, tx_knowledge=%b", 
                 round_id, o_commit_valid, o_system_halt, o_tx_knowledge_vec);
    end
endtask

task send_packet;
    input [7:0] node_id;
    input [63:0] run_id;
    input [63:0] round_id;
    input [P_NODE_COUNT-1:0] sound_bitmap;
    begin
        @(posedge clk);
        i_rx_valid <= 1;
        i_rx_node_id <= node_id;
        i_rx_run_id <= run_id;
        i_rx_round_id <= round_id;
        i_rx_sound_bitmap <= sound_bitmap;
        i_rx_propose <= {node_id, 56'h0};
        @(posedge clk);
        i_rx_valid <= 0;
        repeat(5) @(posedge clk);
    end
endtask

task test_normal_agreement;
    integer round;
    reg [P_NODE_COUNT-1:0] all_nodes;
    reg [P_NODE_COUNT-1:0] sound_bitmaps [0:P_NODE_COUNT-1];
    begin
        all_nodes = 3'b111;  // Nodes 0, 1, 2 active, assume UUT is node 0 (P_NODE_ID=0)
        
        // All nodes see each other (bitmap = 111)
        sound_bitmaps[0] = 3'b111;
        sound_bitmaps[1] = 3'b111;
        sound_bitmaps[2] = 3'b111;
        
        // Initialize core
        initialize_core(all_nodes);
        
        // Rounds 0-1: Warm-up (eval_counter < 2, no evaluation)
        for (round = 0; round < 2; round = round + 1) begin
            $display("  Warmup round %0d", round);
            trigger_round_with_packets(round, 1, all_nodes, {sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
        end
        
        // Round 2+: Real evaluation (should commit)
        for (round = 2; round < 5; round = round + 1) begin
            $display("  Active round %0d", round);
            trigger_round_with_packets(round, 1, all_nodes, {sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
            if (o_system_halt) begin
                $display("  System halted at round %0d", round);
                round = 5;  // Exit loop
            end
        end
    end
endtask

task test_node_failure;
    integer round;
    reg [P_NODE_COUNT-1:0] active_nodes;
    reg [P_NODE_COUNT-1:0] sound_bitmaps [0:P_NODE_COUNT-1];
    begin
        active_nodes = 3'b011;  // Only nodes 0, 1 (node 2 failed)
        
        // Nodes 0, 1 see each other; node 2 missing from their bitmaps
        sound_bitmaps[0] = 3'b011;
        sound_bitmaps[1] = 3'b011;
        // node 2 doesn't send
        
        initialize_core(3'b111);  // Core was configured for 3 nodes
        
        // Warmup
        for (round = 0; round < 2; round = round + 1) begin
            trigger_round_with_packets(round, 1, active_nodes, {sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
        end
        
        // Real evaluation with reduced set
        for (round = 2; round < 5; round = round + 1) begin
            trigger_round_with_packets(round, 1, active_nodes, {sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
            if (o_system_halt) begin
                $display("  Node failure test: halted at round %0d", round);
                round = 5;  // Exit loop
            end
        end
    end
endtask

task test_network_partition;
    integer round;
    reg [P_NODE_COUNT-1:0] active_nodes;
    reg [P_NODE_COUNT-1:0] sound_bitmaps [0:P_NODE_COUNT-1];
    begin
        // Network partition: nodes 0,1 isolated from 2,3,4
        active_nodes = 5'b11111;  // All 5 nodes send packets
        
        // Node 0 sees only 0,1; Node 1 sees only 0,1
        sound_bitmaps[0] = 5'b00011;
        sound_bitmaps[1] = 5'b00011;
        // Nodes 2,3,4 see all nodes
        sound_bitmaps[2] = 5'b11111;
        sound_bitmaps[3] = 5'b11111;
        sound_bitmaps[4] = 5'b11111;
        
        initialize_core(5'b11111);  // Core configured for 5 nodes
        
        // Warmup
        for (round = 0; round < 2; round = round + 1) begin
            trigger_round_with_packets(round, 1, active_nodes, {sound_bitmaps[4], sound_bitmaps[3], sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
        end
        
        // Real evaluation with partition
        for (round = 2; round < 5; round = round + 1) begin
            trigger_round_with_packets(round, 1, active_nodes, {sound_bitmaps[4], sound_bitmaps[3], sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
            if (o_system_halt) begin
                $display("  Partition test: halted at round %0d (expected due to divergent knowledge)", round);
                round = 5;  // Exit loop
            end
        end
    end
endtask

endmodule
