`timescale 1ns / 1ps

module tb_consensus_core;

// Testbench for consensus_core module
// This testbench instantiates a consensus_core and drives a simulated
// PTP clock to exercise the internal scheduler (slot timing is now
// derived inside the DUT from ptp_sync_ts, not pushed in from outside).

parameter CLOCK_PERIOD = 10;

//================================================
// Parameters and Signals
//================================================
parameter P_NODE_COUNT       = 5;
parameter P_NODE_ID          = 0;
parameter P_DATA_WIDTH       = 512;
parameter P_KEEP_WIDTH       = P_DATA_WIDTH / 8;
parameter P_LOG_ITEM_LEN     = 40; // bytes
parameter P_SLOT_DURATION_NS = 4000;
parameter P_GUARD_NS         = 50;
parameter PTP_TS_FMT_TOD     = 1;
parameter PTP_TS_WIDTH       = PTP_TS_FMT_TOD ? 96 : 64;

// Clock and reset
reg clk;
reg rst_n;

// Scheduler / PTP signals
reg                                  i_global_enable;
reg  [PTP_TS_WIDTH-1:0]              ptp_sync_ts;

// Free-running simulated PTP nanosecond counter (TOD ns sub-field).
// Increments every clk edge to model a PTP-synced local clock ticking
// in real time. Kept strictly smaller than P_SLOT_DURATION_NS per step
// so the level-sensitive boundary check in the DUT never skips a slot.
reg  [PTP_TS_WIDTH-1:0]              r_sim_ptp_ns;

// Control plane / data plane inputs
reg [63:0]                          i_ctrl_membership_epoch;
reg [63:0]                          i_ctrl_run_id;
reg [P_NODE_COUNT-1:0]              i_ctrl_membership;
reg                                 i_ctrl_activate;
reg                                 i_ctrl_reboot;
// reg [P_LOG_ITEM_LEN*8-1:0]          i_ctrl_host_payload;
reg [7:0]                           i_rx_sound_bitmap;
reg [63:0]                          i_rx_run_id;
reg [63:0]                          i_rx_round_id;

reg                                 i_rx_valid;
reg [7:0]                           i_rx_node_id;
reg [P_LOG_ITEM_LEN*8-1:0]          i_rx_propose;

// Outputs
// wire [P_NODE_COUNT-1:0]             o_alive_mask;
wire                                o_system_halt;

// wire [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]  o_commit_log;
// wire [P_NODE_COUNT-1:0]                   o_commit_valid;
wire [P_NODE_COUNT-1:0]                   o_tx_knowledge_vec;
wire [P_LOG_ITEM_LEN*8-1:0]               o_tx_propose;

wire                                 o_tx_allowed;
wire                                 o_rx_enabled;
wire [63:0]                          o_current_slot_id;
wire [63:0]                          o_current_run_id;

//================================================
// DUT Instantiation
//================================================
consensus_core #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_NODE_ID(P_NODE_ID),
    .P_LOG_ITEM_LEN(P_LOG_ITEM_LEN),
    .P_SLOT_DURATION_NS(P_SLOT_DURATION_NS),
    .P_GUARD_NS(P_GUARD_NS),
    .PTP_TS_FMT_TOD(PTP_TS_FMT_TOD)
) uut (
    .clk(clk),
    .rst_n(rst_n),

    .i_global_enable(i_global_enable),
    .ptp_sync_ts(ptp_sync_ts),

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
    // .i_ctrl_host_payload(i_ctrl_host_payload),

    // .o_alive_mask(o_alive_mask),
    .o_system_halt(o_system_halt),
    // .o_commit_log(o_commit_log),
    // .o_commit_valid(o_commit_valid),
    .o_tx_knowledge_vec(o_tx_knowledge_vec),
    .o_tx_propose(o_tx_propose),

    .o_tx_allowed(o_tx_allowed),
    .o_rx_enabled(o_rx_enabled),
    .o_current_slot_id(o_current_slot_id),
    .o_current_run_id(o_current_run_id)
);

// Debug hooks into DUT internals (mirrors prior debug visibility, plus
// the new scheduler internals so we can confirm boundary-crossing
// behavior without guessing from outputs alone).
wire [P_NODE_COUNT-1:0] dbg_evidence_matrix_0 = uut.s_evidence_sound_matrix[0];
wire [P_NODE_COUNT-1:0] dbg_evidence_matrix_1 = uut.s_evidence_sound_matrix[1];
wire [P_NODE_COUNT-1:0] dbg_evidence_matrix_2 = uut.s_evidence_sound_matrix[2];

wire [P_NODE_COUNT-1:0] dbg_commit_matrix_0 = uut.s_commit_sound_matrix[0];
wire [P_NODE_COUNT-1:0] dbg_commit_matrix_1 = uut.s_commit_sound_matrix[1];
wire [P_NODE_COUNT-1:0] dbg_commit_matrix_2 = uut.s_commit_sound_matrix[2];

wire                     dbg_new_slot_pulse  = uut.new_slot_pulse;
wire [63:0]              dbg_curr_round_id   = uut.s_curr_round_id;
wire [PTP_TS_WIDTH-1:0]  dbg_next_boundary   = uut.r_next_boundary;
wire [PTP_TS_WIDTH-1:0]  dbg_slot_offset     = uut.slot_offset;

//================================================
// Clock Generation
//================================================
initial begin
    clk = 0;
    forever #(CLOCK_PERIOD/2) clk = ~clk;
end

//================================================
// Simulated PTP Clock
//================================================
// Models a free-running, already-synchronized PTP local clock: it just
// keeps counting nanoseconds every cycle regardless of reset/enable
// state, exactly like real PTP hardware would. The DUT's scheduler is
// responsible for aligning to it, not the other way around.
initial begin
    r_sim_ptp_ns = 0;
    forever begin
        @(posedge clk);
        r_sim_ptp_ns = r_sim_ptp_ns + CLOCK_PERIOD;
    end
end

always @(*) ptp_sync_ts = r_sim_ptp_ns;

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

    // Test Case 2: Node 1 cannot receive packets from node 0
    $display("\nTest Case 2: Node 1 cannot receive packets from node 0");
    pulse_reset();
    test_node_failure();

    #100;

    // Test Case 3: Network Partition
    $display("\nTest Case 3: Network Partition");
    pulse_reset();
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
        i_global_enable   = 0;

        i_rx_valid        = 0;
        i_rx_node_id      = 0;
        i_rx_sound_bitmap = 0;
        i_rx_propose      = 0;
        i_rx_run_id       = 0;
        i_rx_round_id     = 0;

        i_ctrl_activate         = 0;
        i_ctrl_membership_epoch = 0;
        i_ctrl_run_id           = 0;
        i_ctrl_membership       = 0;
        i_ctrl_host_payload     = 0;
        i_ctrl_reboot           = 0;
    end
endtask

// Resets the DUT and the simulated PTP scheduler state together. The
// scheduler's r_next_boundary/r_slot_id_counter only reset while
// i_global_enable is low (or rst_n is low), so we drop enable across
// the reset pulse to guarantee a clean slot-id restart for each test
// case, matching how the old TB re-synchronized round_id to 0.
task pulse_reset;
    begin
        rst_n = 0;
        i_global_enable = 0;
        #10;
        rst_n = 1;
        #10;
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

        // Bring up the PTP scheduler. enable_rising_edge in the DUT
        // latches r_next_boundary = ptp_sync_ts + P_SLOT_DURATION_NS at
        // this instant, so slot 0 starts one full slot duration from
        // here (per the design note: first slot may run long since
        // there's no true epoch alignment yet).
        i_global_enable <= 1;

        @(posedge clk);
        i_ctrl_activate <= 0;
        repeat(5) @(posedge clk);
    end
endtask

// Blocks until the DUT's internal scheduler asserts new_slot_pulse,
// i.e. until ptp_sync_ts has actually crossed r_next_boundary inside
// the DUT. This replaces the old behavior of forcing new_slot_pulse
// directly, since slot boundaries are now derived, not injected.
task wait_for_slot_boundary;
    begin
        @(posedge dbg_new_slot_pulse);
        // give slot_offset / o_tx_allowed / o_rx_enabled (which lag by
        // one cycle, see scheduler implementation) time to settle
        repeat(2) @(posedge clk);
    end
endtask

task trigger_round_with_packets;
    input [63:0] round_id;           // expected round id, for logging/sanity check only
    input [63:0] run_id;
    input [P_NODE_COUNT-1:0] active_nodes;  // bitmap of nodes sending packets
    input [P_NODE_COUNT * P_NODE_COUNT - 1:0] sound_bitmaps_packed;  // packed: {sound_bitmaps[P_NODE_COUNT-1],...,sound_bitmaps[0]}
    integer n;
    reg [63:0] dut_round_id;
    begin
        // Wait for the DUT's own scheduler to roll the slot boundary
        // rather than injecting one. dbg_curr_round_id mirrors
        // s_curr_round_id, which is what i_rx_round_id is actually
        // checked against in S_COLLECT.
        wait_for_slot_boundary();
        dut_round_id = dbg_curr_round_id;

        if (dut_round_id !== round_id) begin
            $display("  NOTE: expected round_id=%0d but DUT scheduler is at round_id=%0d (using DUT's value)",
                      round_id, dut_round_id);
        end

        // Send packets from active nodes, tagged with the round id the
        // DUT itself believes it's in.
        for (n = 1; n < P_NODE_COUNT; n = n + 1) begin
            if (active_nodes[n]) begin
                send_packet(n, run_id, dut_round_id, sound_bitmaps_packed[n * P_NODE_COUNT +: P_NODE_COUNT]);
            end
        end

        // Wait for processing within the slot, but stop short of the
        // next boundary crossing so packets land in the same round
        // they were tagged for. P_SLOT_DURATION_NS=4000ns at
        // CLOCK_PERIOD=10ns is 400 clk cycles per slot; 50 cycles of
        // margin (as in the original TB) comfortably fits inside that
        // with room to spare before the next boundary.
        repeat(50) @(posedge clk);

        // Monitor outputs
        $display("Round %0d: halt=%b, tx_knowledge=%b, tx_allowed=%b, rx_enabled=%b",
                 dut_round_id, o_system_halt, o_tx_knowledge_vec, o_tx_allowed, o_rx_enabled);
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

        // Initialize core (this also enables the PTP scheduler)
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
        active_nodes = 3'b111;

        sound_bitmaps[0] = 3'b111;
        sound_bitmaps[1] = 3'b111;
        sound_bitmaps[2] = 3'b111;

        initialize_core(3'b111);  // Core was configured for 3 nodes

        // Warmup
        trigger_round_with_packets(0, 1, active_nodes, {sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
        active_nodes[1] = 0; // Node 1 fails after round 0
        trigger_round_with_packets(1, 1, active_nodes, {sound_bitmaps[2], sound_bitmaps[1], sound_bitmaps[0]});
        sound_bitmaps[2] = 3'b101;

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
        active_nodes = 5'b00011;

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
