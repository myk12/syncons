`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_core_protocol - exercises SECTION 3 (consensus pipeline + FSM) of core.v
 *
 * NODE_COUNT consensus_core instances share a PTP time source and a broadcast
 * CSR write bus, and are wired to each other through a trivial network model:
 * when a node pulses o_tx_start_pulse, its {round_id, run_id, sound_set} is
 * handed to the others one cycle later. TDMA guarantees only one node transmits
 * at a time, so a single-entry delay register is a faithful medium.
 *
 * Two knobs let the tests break the cluster: link_enable_mask gags a node's
 * transmitter, and the inject_* registers push a hand-crafted packet at one
 * node so that evaluations which cannot arise from healthy traffic - a sound
 * set that grew, a row that does not contain its own author - can still be
 * reached.
 */
module tb_core_protocol;

localparam integer CLK_PERIOD_NS     = 4;
// Node count is a build-time knob: `iverilog -DSSR_TB_NODE_COUNT=5`.
// Running at 5 matters because several protocol properties are vacuous at 3.
// A 3-member quorum is 2, and any two 2-subsets of a 3-set intersect, so a
// cluster of 3 cannot express the case where two nodes draw quorums that miss
// each other. Every expectation below is derived from NODE_COUNT rather than
// written as a literal, so both sizes exercise the same assertions.
`ifndef SSR_TB_NODE_COUNT
`define SSR_TB_NODE_COUNT 3
`endif
localparam integer NODE_COUNT        = `SSR_TB_NODE_COUNT;
localparam integer ROUND_LENGTH_NS   = 4000;
localparam integer GUARD_TIME_NS     = 200;
localparam integer TX_SUBSLOT_NS     = 400;
localparam integer TX_ADMIT_MARGIN_NS = 100;
localparam integer ROUNDS_PER_SECOND = 1_000_000_000 / ROUND_LENGTH_NS;
localparam integer CYCLES_PER_ROUND  = ROUND_LENGTH_NS / CLK_PERIOD_NS;

localparam [23:0] RB_BASE_ADDR = 24'h003000;
localparam [23:0] REG_CONTROL                    = RB_BASE_ADDR + 24'h00C;
localparam [23:0] REG_STATUS                     = RB_BASE_ADDR + 24'h010;
localparam [23:0] REG_CONFIG_RUN_ID              = RB_BASE_ADDR + 24'h100;
localparam [23:0] REG_CONFIG_MEMBERSHIP          = RB_BASE_ADDR + 24'h104;
localparam [23:0] REG_CONFIG_EFFECTIVE_ROUND_LOW = RB_BASE_ADDR + 24'h108;
localparam [23:0] REG_CURRENT_RUN_ID             = RB_BASE_ADDR + 24'h118;
localparam [23:0] REG_CURRENT_SOUND_SET          = RB_BASE_ADDR + 24'h11C;
localparam [23:0] REG_HALT_REASON                = RB_BASE_ADDR + 24'h200;
localparam [23:0] REG_HALT_ROUND_LOW             = RB_BASE_ADDR + 24'h204;
localparam [23:0] REG_HALT_SELF_ROW              = RB_BASE_ADDR + 24'h20C;
localparam [23:0] REG_HALT_SOUND_SET             = RB_BASE_ADDR + 24'h214;
localparam [23:0] REG_HALT_ROWS_LOW              = RB_BASE_ADDR + 24'h218;
localparam [23:0] REG_CONFIG_EFFECTIVE_ROUND_HIGH= RB_BASE_ADDR + 24'h10C;
localparam [23:0] REG_COMMIT_COUNT_LOW           = RB_BASE_ADDR + 24'h30C;
localparam [23:0] REG_HALT_COUNT                 = RB_BASE_ADDR + 24'h314;
localparam [7:0]  TOO_SMALL = ALL_MEMBERS & ~((8'd1 << (NODE_COUNT-2)) - 8'd1);

// Derived expectations. GAGGED/DROP_SRC are the last node; DROP_VICTIM is a
// node that is neither the source nor the local reference node 0.
localparam [7:0]   ALL_MEMBERS  = (8'd1 << NODE_COUNT) - 8'd1;
localparam integer GAGGED_NODE  = NODE_COUNT - 1;
localparam integer DROP_SRC     = NODE_COUNT - 1;
localparam integer DROP_VICTIM  = 1;
localparam [7:0]   AFTER_GAG    = ALL_MEMBERS & ~(8'd1 << GAGGED_NODE);
localparam [7:0]   AFTER_DROP   = ALL_MEMBERS & ~(8'd1 << DROP_VICTIM);

// A running node's sound set may never hold fewer members than a quorum of the
// FULL membership. This is the tolerance bound floor((n-1)/2) restated: witness
// count >= quorum, and the sound set IS the witness set. Sizing the quorum from
// the node's own shrinking sound set instead lets this ratchet downwards - the
// cluster keeps committing with a minority - which is invisible at n=3 because
// a 3-member quorum of 2 cannot shrink below 2 anyway.
localparam integer QUORUM = (NODE_COUNT >> 1) + 1;

localparam [3:0] HALT_NONE               = 4'd0;
localparam [3:0] HALT_NO_AGREED_ROW      = 4'd1;
localparam [3:0] HALT_COMMIT_SET_INVALID = 4'd2;
localparam [3:0] HALT_SOUND_SET_GREW     = 4'd5;
localparam [3:0] HALT_TIME_FAULT         = 4'd6;

// -------------------------------------------------------------------------
// clock / reset / PTP time
// -------------------------------------------------------------------------
reg clk = 1'b0;
reg rst = 1'b1;
always #(CLK_PERIOD_NS/2.0) clk = ~clk;

reg [47:0] time_seconds     = 48'd7;
reg [31:0] time_nanoseconds = 32'd0;
reg        time_valid       = 1'b1;
reg        time_step        = 1'b0;
reg        time_advancing   = 1'b0;

always @(posedge clk) begin
    if (time_advancing) begin
        if (time_nanoseconds + CLK_PERIOD_NS >= 32'd1_000_000_000) begin
            time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS - 32'd1_000_000_000;
            time_seconds     <= time_seconds + 48'd1;
        end else begin
            time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS;
        end
    end
end

reg enable_input = 1'b0;

// -------------------------------------------------------------------------
// CSR bus: writes broadcast, reads muxed by csr_read_node
// -------------------------------------------------------------------------
reg  [23:0] csr_write_addr   = 24'd0;
reg  [31:0] csr_write_data   = 32'd0;
reg         csr_write_enable = 1'b0;
reg  [23:0] csr_read_addr    = 24'd0;
reg         csr_read_enable  = 1'b0;

wire        csr_write_ack [0:NODE_COUNT-1];
wire        csr_read_ack  [0:NODE_COUNT-1];
wire [31:0] csr_read_data [0:NODE_COUNT-1];

// -------------------------------------------------------------------------
// node signals
// -------------------------------------------------------------------------
wire [63:0] round_id      [0:NODE_COUNT-1];
wire        round_start   [0:NODE_COUNT-1];
wire        tx_start      [0:NODE_COUNT-1];
wire [63:0] tx_round_id   [0:NODE_COUNT-1];
wire [31:0] tx_run_id     [0:NODE_COUNT-1];
wire [7:0]  tx_row  [0:NODE_COUNT-1];
wire        commit_valid  [0:NODE_COUNT-1];
wire [63:0] commit_round  [0:NODE_COUNT-1];
wire [7:0]  commit_set    [0:NODE_COUNT-1];
wire        halt          [0:NODE_COUNT-1];
wire [7:0]  node_sound_set [0:NODE_COUNT-1];   // white-box taps for the monitors
wire        node_running   [0:NODE_COUNT-1];

// -------------------------------------------------------------------------
// network model
// -------------------------------------------------------------------------
reg [NODE_COUNT-1:0] link_enable_mask = {NODE_COUNT{1'b1}};

// One-directional, one-round drop: src -> dst in round asym_drop_round only.
// Symmetric loss cannot tell the two row semantics apart, because every node
// misses the same packet and their observation rows stay identical. Asymmetry
// is the discriminating case.
reg [7:0]  asym_drop_src   = 8'hFF;
reg [7:0]  asym_drop_dst   = 8'hFF;
reg [63:0] asym_drop_round = {64{1'b1}};

reg        net_valid_reg = 1'b0;
reg [7:0]  net_src_reg   = 8'd0;
reg [7:0]  net_row_reg = 8'd0;
reg [31:0] net_run_reg   = 32'd0;
reg [63:0] net_round_reg = 64'd0;

integer net_i;
always @(posedge clk) begin
    net_valid_reg <= 1'b0;
    for (net_i = 0; net_i < NODE_COUNT; net_i = net_i + 1) begin
        if (tx_start[net_i] && link_enable_mask[net_i]) begin
            net_valid_reg   <= 1'b1;
            net_src_reg     <= net_i[7:0];
            net_row_reg     <= tx_row[net_i];
            net_run_reg     <= tx_run_id[net_i];
            net_round_reg   <= tx_round_id[net_i];
        end
    end
end

// hand-crafted packet injection, aimed at a single node
reg        inject_valid  = 1'b0;
reg [7:0]  inject_target = 8'd0;
reg [7:0]  inject_src    = 8'd0;
reg [7:0]  inject_row  = 8'd0;
reg [31:0] inject_run    = 32'd0;
reg [63:0] inject_round  = 64'd0;

wire        rx_valid    [0:NODE_COUNT-1];
wire [7:0]  rx_node_id  [0:NODE_COUNT-1];
wire [7:0]  rx_row_w    [0:NODE_COUNT-1];
wire [31:0] rx_run      [0:NODE_COUNT-1];
wire [63:0] rx_round    [0:NODE_COUNT-1];

// -------------------------------------------------------------------------
// DUTs
// -------------------------------------------------------------------------
genvar node_index;
generate
for (node_index = 0; node_index < NODE_COUNT; node_index = node_index + 1) begin : g_node

    wire injected_here = inject_valid && (inject_target == node_index);
    wire dropped_here  = (net_src_reg   == asym_drop_src)
                      && (asym_drop_dst == node_index)
                      && (net_round_reg == asym_drop_round);

    assign rx_valid[node_index]   = injected_here
                                  || (net_valid_reg && (net_src_reg != node_index)
                                      && !dropped_here);
    assign rx_node_id[node_index] = injected_here ? inject_src   : net_src_reg;
    assign rx_row_w[node_index]   = injected_here ? inject_row : net_row_reg;
    assign rx_run[node_index]     = injected_here ? inject_run   : net_run_reg;
    assign rx_round[node_index]   = injected_here ? inject_round : net_round_reg;

    consensus_core #(
        .P_NODE_COUNT(NODE_COUNT),
        .P_NODE_ID(node_index),
        .RB_BASE_ADDR(RB_BASE_ADDR),
        .ROUND_LENGTH_NS(ROUND_LENGTH_NS), .GUARD_TIME_NS(GUARD_TIME_NS),
        .TX_SUBSLOT_NS(TX_SUBSLOT_NS), .TX_ADMIT_MARGIN_NS(TX_ADMIT_MARGIN_NS)
    ) dut (
        .clk(clk), .rst(rst), .i_enable(enable_input),

        .i_ptp_tod_sec(time_seconds), .i_ptp_tod_ns(time_nanoseconds),
        .i_ptp_time_valid(time_valid), .i_ptp_step(time_step),

        .reg_wr_addr(csr_write_addr), .reg_wr_data(csr_write_data),
        .reg_wr_strb(4'hF), .reg_wr_en(csr_write_enable),
        .reg_wr_wait(), .reg_wr_ack(csr_write_ack[node_index]),
        .reg_rd_addr(csr_read_addr), .reg_rd_en(csr_read_enable),
        .reg_rd_data(csr_read_data[node_index]), .reg_rd_wait(),
        .reg_rd_ack(csr_read_ack[node_index]),

        .o_round_id(round_id[node_index]),
        .o_round_start_pulse(round_start[node_index]),
        .o_round_boundary_pulse(),
        .o_tx_start_pulse(tx_start[node_index]),
        .o_tx_end_pulse(), .o_tx_window(),
        .o_rx_start_pulse(), .o_rx_end_pulse(), .o_rx_window(),

        .o_tx_round_id(tx_round_id[node_index]),
        .o_tx_run_id(tx_run_id[node_index]),
        .o_tx_row(tx_row[node_index]),

        .i_rx_valid(rx_valid[node_index]),
        .i_rx_node_id(rx_node_id[node_index]),
        .i_rx_row(rx_row_w[node_index]),
        .i_rx_run_id(rx_run[node_index]),
        .i_rx_round_id(rx_round[node_index]),

        .o_commit_valid(commit_valid[node_index]),
        .o_commit_round_id(commit_round[node_index]),
        .o_commit_set(commit_set[node_index]),

        .o_halt(halt[node_index]),
        .o_time_fault(), .o_time_fault_count()
    );

    // VCD cannot represent a Verilog array, and previous_stage_rows_reg is the
    // one structure you most need to see. Flatten it for the waveform: byte i
    // is node i's row. Costs nothing - nothing reads it.
    wire [63:0] wave_row_matrix;
    genvar wave_j;
    for (wave_j = 0; wave_j < 8; wave_j = wave_j + 1) begin : g_wave
        assign wave_row_matrix[wave_j*8 +: 8] = dut.previous_stage_rows_reg[wave_j];
    end

    assign node_sound_set[node_index] = dut.current_sound_set_reg;
    assign node_running[node_index]   = (dut.state_reg == 2'd2);   // S_RUN
end
endgenerate

// -------------------------------------------------------------------------
// helpers
// -------------------------------------------------------------------------
integer error_count = 0;
integer check_count = 0;

task check(input condition, input string message);
begin
    check_count = check_count + 1;
    if (!condition) begin
        $display("[%0t] ERROR: %0s", $realtime, message);
        error_count = error_count + 1;
    end
end
endtask

reg        csr_last_acked = 1'b0;
reg [31:0] csr_read_value = 32'd0;

task csr_write(input [23:0] address, input [31:0] data);
    integer poll_count;
begin
    @(negedge clk);
    csr_write_addr = address; csr_write_data = data; csr_write_enable = 1'b1;
    csr_last_acked = 1'b0; poll_count = 0;
    while (!csr_last_acked && poll_count < 16) begin
        @(posedge clk); #0.1;
        if (csr_write_ack[0]) csr_last_acked = 1'b1;
        poll_count = poll_count + 1;
    end
    @(negedge clk); csr_write_enable = 1'b0;
end
endtask

task csr_read_node(input [23:0] address, input integer node);
    integer poll_count;
begin
    @(negedge clk);
    csr_read_addr = address; csr_read_enable = 1'b1;
    csr_last_acked = 1'b0; csr_read_value = 32'hDEAD_BEEF; poll_count = 0;
    while (!csr_last_acked && poll_count < 16) begin
        @(posedge clk); #0.1;
        if (csr_read_ack[node]) begin
            csr_last_acked = 1'b1;
            csr_read_value = csr_read_data[node];
        end
        poll_count = poll_count + 1;
    end
    @(negedge clk); csr_read_enable = 1'b0;
end
endtask

task wait_rounds(input integer count);
begin
    repeat (count * CYCLES_PER_ROUND) @(posedge clk);
end
endtask

// Bring all three nodes up together into a healthy run.
task bring_up(input [31:0] run_id_value);
    integer bring_up_i;
begin
    // A new run restarts the commit stream at a fresh round, so the continuity
    // monitor has to forget the previous frontier or it reports a false gap.
    for (bring_up_i = 0; bring_up_i < NODE_COUNT; bring_up_i = bring_up_i + 1)
        commit_seen[bring_up_i] = 1'b0;

    csr_write(REG_CONTROL, 32'h0000_0000);              // disable, so config unlocks
    csr_write(REG_CONFIG_RUN_ID, run_id_value);
    csr_write(REG_CONFIG_MEMBERSHIP, {24'd0, ALL_MEMBERS});
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW, 32'h0000_0100);
    enable_input = 1'b1;
    csr_write(REG_CONTROL, 32'h0000_0003);              // enable | activate
    wait_rounds(4);                                     // arm, activate, prime
end
endtask

// -------------------------------------------------------------------------
// commit observation
// -------------------------------------------------------------------------
integer    commit_count   [0:NODE_COUNT-1];
reg [63:0] last_commit_round [0:NODE_COUNT-1];
reg [31:0] last_commit_run_id[0:NODE_COUNT-1];
reg [7:0]  last_commit_set   [0:NODE_COUNT-1];
reg        commit_seen       [0:NODE_COUNT-1];
integer    halt_count [0:NODE_COUNT-1];

integer obs_i;
initial begin
    for (obs_i = 0; obs_i < NODE_COUNT; obs_i = obs_i + 1) begin
        commit_count[obs_i]      = 0;
        last_commit_round[obs_i]  = 64'd0;
        last_commit_run_id[obs_i] = 32'd0;
        last_commit_set[obs_i]   = 8'd0;
        commit_seen[obs_i]       = 1'b0;
        halt_count[obs_i]        = 0;
    end
end

// Continuous invariant: commits from one node must be strictly consecutive.
// A gap means a round was silently skipped, which is exactly the failure the
// old single-evaluation bug produced.
always @(posedge clk) begin
    for (obs_i = 0; obs_i < NODE_COUNT; obs_i = obs_i + 1) begin
        if (commit_valid[obs_i]) begin
            // Continuity holds WITHIN a run, not across one. A new run_id means
            // the pipeline was reset - by a reboot or a live reconfiguration -
            // and the commit stream legitimately restarts. The gap it leaves is
            // exactly the activation round plus the two priming rounds, so it is
            // checked rather than merely tolerated.
            if (commit_seen[obs_i] && tx_run_id[obs_i] != last_commit_run_id[obs_i])
                check(commit_round[obs_i] == last_commit_round[obs_i] + 64'd3,
                      $sformatf("node %0d: first commit of a new run is round %0d after %0d; expected +3 (activation round + 2 priming)",
                                obs_i, commit_round[obs_i], last_commit_round[obs_i]));
            else if (commit_seen[obs_i])
                check(commit_round[obs_i] == last_commit_round[obs_i] + 64'd1,
                      $sformatf("node %0d committed round %0d after %0d (gap)",
                                obs_i, commit_round[obs_i], last_commit_round[obs_i]));
            // The commit always trails the round in progress by exactly two:
            // one round to gather proposals, one more to gather the rows that
            // judge them.
            check(commit_round[obs_i] + 64'd2 == round_id[obs_i],
                  $sformatf("node %0d committed round %0d while in round %0d (lag != 2)",
                            obs_i, commit_round[obs_i], round_id[obs_i]));
            commit_count[obs_i]      = commit_count[obs_i] + 1;
            last_commit_round[obs_i]  = commit_round[obs_i];
            last_commit_run_id[obs_i] = tx_run_id[obs_i];
            last_commit_set[obs_i]   = commit_set[obs_i];
            commit_seen[obs_i]       = 1'b1;
        end
        if (halt[obs_i] && halt_count[obs_i] == 0)
            halt_count[obs_i] = 1;
    end
end

// -------------------------------------------------------------------------
// always-on safety monitors
// -------------------------------------------------------------------------
function automatic [3:0] popcount8(input [7:0] v);
    integer b;
    begin
        popcount8 = 4'd0;
        for (b = 0; b < 8; b = b + 1) popcount8 = popcount8 + {3'd0, v[b]};
    end
endfunction

// (1) Agreement. Two nodes committing the same round must commit the same set.
// This is the property the whole protocol exists to provide, so it is checked
// continuously rather than inside any one test.
localparam integer COMMIT_LOG_DEPTH = 64;
reg [63:0] commit_log_round [0:COMMIT_LOG_DEPTH-1];
reg [7:0]  commit_log_set   [0:COMMIT_LOG_DEPTH-1];
reg        commit_log_valid [0:COMMIT_LOG_DEPTH-1];

integer mon_i, log_idx;
initial for (mon_i = 0; mon_i < COMMIT_LOG_DEPTH; mon_i = mon_i + 1)
    commit_log_valid[mon_i] = 1'b0;

always @(posedge clk) begin
    for (mon_i = 0; mon_i < NODE_COUNT; mon_i = mon_i + 1) begin
        if (commit_valid[mon_i]) begin
            log_idx = commit_round[mon_i] % COMMIT_LOG_DEPTH;
            if (commit_log_valid[log_idx] &&
                commit_log_round[log_idx] == commit_round[mon_i]) begin
                check(commit_log_set[log_idx] == commit_set[mon_i],
                      $sformatf("AGREEMENT: round %0d committed as %02h by an earlier node, %02h by node %0d",
                                commit_round[mon_i], commit_log_set[log_idx],
                                commit_set[mon_i], mon_i));
            end else begin
                commit_log_valid[log_idx] = 1'b1;
                commit_log_round[log_idx] = commit_round[mon_i];
                commit_log_set[log_idx]   = commit_set[mon_i];
            end
        end
    end

    // (2) Tolerance bound. A commit means a quorum of witnesses agreed, and the
    // sound set IS that witness set - so a committing node must hold at least
    // QUORUM members. Checked at the commit rather than continuously: between
    // activation and its first evaluation a node legitimately holds whatever
    // membership the control plane handed it, which may itself be below quorum.
    // What must never happen is that it COMMITS from there.
    for (mon_i = 0; mon_i < NODE_COUNT; mon_i = mon_i + 1)
        if (!rst && commit_valid[mon_i])
            check(popcount8(node_sound_set[mon_i]) >= QUORUM[3:0],
                  $sformatf("TOLERANCE: node %0d committed round %0d with sound set %02h (%0d members) below quorum %0d",
                            mon_i, commit_round[mon_i], node_sound_set[mon_i],
                            popcount8(node_sound_set[mon_i]), QUORUM));
end

// -------------------------------------------------------------------------
// main
// -------------------------------------------------------------------------
integer n;
integer commits_before [0:NODE_COUNT-1];
reg [63:0] agreed_round;
integer    victim;
integer    byte_i;
reg [31:0] halt_count_before;
reg [7:0]  expect_row;
reg [63:0] target_round;

initial begin
    $dumpfile($sformatf("build/tb_core_protocol_%0d.vcd", NODE_COUNT));
    $dumpvars(0, tb_core_protocol);

    rst = 1'b1; enable_input = 1'b0; time_advancing = 1'b0;
    repeat (10) @(posedge clk);
    time_advancing = 1'b1;
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // ================= Test 0: healthy three-node run =================
    $display("[%0t] Test 0: healthy %0d-node run", $realtime, NODE_COUNT);
    bring_up(32'h0000_00A1);

    for (n = 0; n < NODE_COUNT; n = n + 1) begin
        check(!halt[n], $sformatf("node %0d halted during a healthy run", n));
        check(tx_row[n] == ALL_MEMBERS,
              $sformatf("node %0d advertises sound set %02h, expected %02h",
                        n, tx_row[n], ALL_MEMBERS));
    end

    for (n = 0; n < NODE_COUNT; n = n + 1) commits_before[n] = commit_count[n];
    wait_rounds(10);
    for (n = 0; n < NODE_COUNT; n = n + 1) begin
        check(commit_count[n] - commits_before[n] >= 8,
              $sformatf("node %0d produced %0d commits over 10 rounds",
                        n, commit_count[n] - commits_before[n]));
        check(last_commit_set[n] == ALL_MEMBERS,
              $sformatf("node %0d commit set %02h, expected %02h",
                        n, last_commit_set[n], ALL_MEMBERS));
        check(!halt[n], $sformatf("node %0d halted mid-run", n));
    end

    // all three must agree on what they have committed
    agreed_round = last_commit_round[0];
    for (n = 1; n < NODE_COUNT; n = n + 1)
        check(last_commit_round[n] == agreed_round,
              $sformatf("node %0d frontier %0d != node0 %0d",
                        n, last_commit_round[n], agreed_round));

    csr_read_node(REG_CURRENT_RUN_ID, 0);
    check(csr_read_value == 32'h0000_00A1,
          $sformatf("CURRENT_RUN_ID %08h, expected 000000a1", csr_read_value));

    // ============ Test 1: a node goes silent; the rest shrink ============
    $display("[%0t] Test 1: node %0d stops transmitting", $realtime, GAGGED_NODE);
    link_enable_mask = AFTER_GAG[NODE_COUNT-1:0];
    wait_rounds(6);

    for (n = 0; n < GAGGED_NODE; n = n + 1) begin
        check(!halt[n], $sformatf("node %0d must survive losing one peer", n));
        check(tx_row[n] == AFTER_GAG,
              $sformatf("node %0d sound set %02h, expected %02h after shrink",
                        n, tx_row[n], AFTER_GAG));
    end
    check(halt[GAGGED_NODE],
          $sformatf("node %0d must halt once it is cut out of the sound set", GAGGED_NODE));

    csr_read_node(REG_HALT_REASON, GAGGED_NODE);
    check(csr_read_value[3:0] == HALT_NO_AGREED_ROW,
          $sformatf("node %0d halt reason %0d, expected %0d (no agreed row)",
                    GAGGED_NODE, csr_read_value[3:0], HALT_NO_AGREED_ROW));

    csr_read_node(REG_CURRENT_SOUND_SET, 0);
    check(csr_read_value[7:0] == AFTER_GAG,
          $sformatf("node 0 CURRENT_SOUND_SET %02h, expected %02h",
                    csr_read_value[7:0], AFTER_GAG));

    // the surviving pair must keep committing, now with the smaller set
    for (n = 0; n < GAGGED_NODE; n = n + 1) commits_before[n] = commit_count[n];
    wait_rounds(6);
    for (n = 0; n < GAGGED_NODE; n = n + 1) begin
        check(commit_count[n] - commits_before[n] >= 4,
              $sformatf("node %0d stopped committing after the shrink (%0d commits)",
                        n, commit_count[n] - commits_before[n]));
        check(last_commit_set[n] == AFTER_GAG,
              $sformatf("node %0d commit set %02h, expected %02h",
                        n, last_commit_set[n], AFTER_GAG));
    end
    check(halt_count[GAGGED_NODE] == 1,
          $sformatf("node %0d should have halted exactly once", GAGGED_NODE));

    // ============ Test 2: reboot the cluster with a fresh run_id =========
    $display("[%0t] Test 2: reboot and reactivate with a new run_id", $realtime);
    link_enable_mask = {NODE_COUNT{1'b1}};
    csr_write(REG_CONTROL, 32'h0000_0004);      // reboot pulse
    repeat (8) @(posedge clk);
    for (n = 0; n < NODE_COUNT; n = n + 1)
        check(!halt[n], $sformatf("node %0d still halted after reboot", n));

    bring_up(32'h0000_00B2);
    for (n = 0; n < NODE_COUNT; n = n + 1) begin
        check(!halt[n], $sformatf("node %0d failed to rejoin after reboot", n));
        check(tx_row[n] == ALL_MEMBERS,
              $sformatf("node %0d sound set %02h after rejoin, expected %02h",
                        n, tx_row[n], ALL_MEMBERS));
        check(tx_run_id[n] == 32'h0000_00B2,
              $sformatf("node %0d run_id %08h, expected 000000b2", n, tx_run_id[n]));
    end
    for (n = 0; n < NODE_COUNT; n = n + 1) commits_before[n] = commit_count[n];
    wait_rounds(6);
    check(commit_count[0] - commits_before[0] >= 4, "cluster did not resume committing");

    // ============ Test 3: stale run_id / stale round are ignored =========
    $display("[%0t] Test 3: packets with the wrong run_id or round are dropped", $realtime);
    for (n = 0; n < NODE_COUNT; n = n + 1) commits_before[n] = commit_count[n];

    @(posedge round_start[0]);
    repeat (4) @(posedge clk);
    inject_target = 8'd0; inject_src = 8'd1;
    inject_row  = 8'h01;                       // a row that would poison node 0
    inject_run    = 32'hDEAD_BEEF;               // ... but from the wrong run
    inject_round  = round_id[0];
    @(negedge clk); inject_valid = 1'b1;
    @(negedge clk); inject_valid = 1'b0;

    repeat (4) @(posedge clk);
    inject_run   = 32'h0000_00B2;                // right run
    inject_round = round_id[0] + 64'd50;         // wrong round
    @(negedge clk); inject_valid = 1'b1;
    @(negedge clk); inject_valid = 1'b0;

    wait_rounds(5);
    check(!halt[0], "node 0 halted on a packet it should have dropped");
    check(commit_count[0] - commits_before[0] >= 3,
          "node 0 stopped committing after dropped packets");

    // ============ Test 4: a sound set that grows must halt ===============
    // Only reachable by injection: healthy traffic can never widen the set.
    // Shrink the cluster first so there is room to "grow" back.
    $display("[%0t] Test 4: sound set growth is rejected", $realtime);
    link_enable_mask = AFTER_GAG[NODE_COUNT-1:0];
    wait_rounds(6);
    check(tx_row[0] == AFTER_GAG,
          $sformatf("precondition: node 0 should have shrunk to %02h", AFTER_GAG));

    // Feed node 0 a row from node 1 claiming all three are still sound, one
    // round after node 0 shrank to {0,1}. This is the property that matters: no
    // peer's claim, however confident, can widen a sound set. (HALT_SOUND_SET_GREW
    // itself is a defensive net and is not reachable from here - it needs the
    // stage's own membership snapshot to outlive a shrink, which healthy traffic
    // never produces.)
    commits_before[0] = commit_count[0];
    @(posedge round_start[0]);
    repeat (4) @(posedge clk);
    inject_target = 8'd0; inject_src = 8'd1;
    inject_row  = ALL_MEMBERS;                 // claims every member is sound
    inject_run    = tx_run_id[0];
    inject_round  = round_id[0];
    @(negedge clk); inject_valid = 1'b1;
    @(negedge clk); inject_valid = 1'b0;
    wait_rounds(4);
    check(tx_row[0] <= AFTER_GAG,
          $sformatf("node 0 sound set widened to %02h - monotonicity violated",
                    tx_row[0]));

    // ============ Test 5: PTP fault halts a running node =================
    $display("[%0t] Test 5: PTP step halts the cluster", $realtime);
    link_enable_mask = {NODE_COUNT{1'b1}};
    csr_write(REG_CONTROL, 32'h0000_0004);       // reboot
    repeat (8) @(posedge clk);
    bring_up(32'h0000_00C3);
    check(!halt[0], "precondition: node 0 running before the step");

    @(negedge clk); time_step = 1'b1;
    @(negedge clk); time_step = 1'b0;
    repeat (6) @(posedge clk);

    for (n = 0; n < NODE_COUNT; n = n + 1)
        check(halt[n], $sformatf("node %0d did not halt on a PTP step", n));
    csr_read_node(REG_HALT_REASON, 0);
    check(csr_read_value[3:0] == HALT_TIME_FAULT,
          $sformatf("halt reason %0d, expected %0d (time fault)",
                    csr_read_value[3:0], HALT_TIME_FAULT));

    // a halted node must be silent even though the timing keeps running
    for (n = 0; n < NODE_COUNT; n = n + 1) commits_before[n] = commit_count[n];
    wait_rounds(4);
    for (n = 0; n < NODE_COUNT; n = n + 1)
        check(commit_count[n] == commits_before[n],
              $sformatf("node %0d kept committing while halted", n));

    // ====== Test 6: one-way loss on the first round of a run ================
    // Node 2 -> node 1 is dropped for exactly one round, and that round is the
    // ACTIVATION round. The timing matters: mid-run, a dropped packet removes
    // the sender from both candidate row semantics alike, so the two are
    // indistinguishable. On the first round of a run there is no prior
    // evaluation to derive a sound set from, and they come apart:
    //
    //   raw observation  node 1 broadcasts 0b011 -> its view is uncorroborated,
    //                    node 1 alone halts (no agreed row) and nodes 0 and 2
    //                    shrink to {0,2} immediately.
    //   derived set      all three broadcast 0b111, the loss is invisible in
    //                    the matrix, node 1 halts on a missing proposal
    //                    (commit set invalid) and nodes 0 and 2 keep believing
    //                    node 1 is sound until it goes silent.
    //
    // A startup fault is not an exotic case, so the checks below pin both the
    // halt reason and the survivors' sound set.
    $display("[%0t] Test 6: one-way loss on the activation round", $realtime);
    csr_write(REG_CONTROL, 32'h0000_0004);       // reboot
    repeat (8) @(posedge clk);

    for (n = 0; n < NODE_COUNT; n = n + 1) commit_seen[n] = 1'b0;
    csr_write(REG_CONTROL, 32'h0000_0000);
    csr_write(REG_CONFIG_RUN_ID, 32'h0000_00D4);
    csr_write(REG_CONFIG_MEMBERSHIP, {24'd0, ALL_MEMBERS});
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW, 32'h0000_0100);
    enable_input = 1'b1;
    csr_write(REG_CONTROL, 32'h0000_0003);       // enable | activate

    csr_read_node(REG_HALT_COUNT, DROP_VICTIM);
    halt_count_before = csr_read_value;

    wait (tx_run_id[0] == 32'h0000_00D4);        // the activation boundary
    #0.1;
    asym_drop_src   = DROP_SRC[7:0];
    asym_drop_dst   = DROP_VICTIM[7:0];
    asym_drop_round = round_id[0];
    wait_rounds(1);
    asym_drop_round = {64{1'b1}};                // one round only
    wait_rounds(4);

    for (n = 0; n < NODE_COUNT; n = n + 1)
        if (n != DROP_VICTIM)
            check(!halt[n],
                  $sformatf("node %0d must survive a loss it did not suffer", n));
    check(halt[DROP_VICTIM],
          $sformatf("node %0d must halt: its view of that round is uncorroborated",
                    DROP_VICTIM));

    // Reason 2 (commit set invalid) here would mean the row still carried a
    // derived sound set rather than the raw observation.
    csr_read_node(REG_HALT_REASON, DROP_VICTIM);
    check(csr_read_value[3:0] == HALT_NO_AGREED_ROW,
          $sformatf("node %0d halt reason %0d, expected %0d (no agreed row)",
                    DROP_VICTIM, csr_read_value[3:0], HALT_NO_AGREED_ROW));
    // The halt record must name WHO diverged, not just that someone did. Every
    // member's row is frozen at the moment of the decision; the victim's row
    // differs from everyone else's, and that difference is the diagnosis.
    csr_read_node(REG_HALT_ROWS_LOW, DROP_VICTIM);
    for (byte_i = 0; byte_i < 4; byte_i = byte_i + 1) begin
        if (byte_i >= NODE_COUNT)       expect_row = 8'd0;
        else if (byte_i == DROP_VICTIM) expect_row = ALL_MEMBERS & ~(8'd1 << DROP_SRC);
        else                            expect_row = ALL_MEMBERS;
        check(csr_read_value[byte_i*8 +: 8] == expect_row,
              $sformatf("HALT_ROWS byte %0d = %02h, expected %02h",
                        byte_i, csr_read_value[byte_i*8 +: 8], expect_row));
    end

    csr_read_node(REG_HALT_SELF_ROW, DROP_VICTIM);
    check(csr_read_value[7:0] == (ALL_MEMBERS & ~(8'd1 << DROP_SRC)),
          $sformatf("node %0d self row %02h, expected %02h (it missed node %0d)",
                    DROP_VICTIM, csr_read_value[7:0],
                    ALL_MEMBERS & ~(8'd1 << DROP_SRC), DROP_SRC));

    for (n = 0; n < NODE_COUNT; n = n + 1)
        if (n != DROP_VICTIM)
            check(tx_row[n] == AFTER_DROP,
                  $sformatf("node %0d sound set %02h, expected %02h",
                            n, tx_row[n], AFTER_DROP));

    for (n = 0; n < NODE_COUNT; n = n + 1) commits_before[n] = commit_count[n];
    wait_rounds(5);
    for (n = 0; n < NODE_COUNT; n = n + 1)
        if (n != DROP_VICTIM)
            check(commit_count[n] - commits_before[n] >= 3,
                  $sformatf("node %0d stopped committing after excluding node %0d",
                            n, DROP_VICTIM));
    check(last_commit_set[0] == AFTER_DROP,
          $sformatf("node 0 commit set %02h, expected %02h",
                    last_commit_set[0], AFTER_DROP));

    csr_read_node(REG_HALT_COUNT, DROP_VICTIM);
    check(csr_read_value == halt_count_before + 32'd1,
          $sformatf("HALT_COUNT %0d, expected %0d", csr_read_value, halt_count_before + 1));

    // ====== Test 7: walking the cluster down to its tolerance bound ========
    // Needs n >= 5. At n = 3 the bound is 2 and a quorum of 2 cannot shrink
    // below 2, so there is nothing to walk.
    //
    // Three one-way drops from the same source, in separate rounds, each one
    // knocking out a different victim. A 5-node cluster tolerates 2 failures;
    // the third must take everyone down. If the quorum were sized from each
    // node's own shrinking sound set, the survivors' bar would fall as fast as
    // their membership and a 2-node minority would sail past the bound and keep
    // committing - which the TOLERANCE monitor above is watching for.
    if (NODE_COUNT >= 5) begin
        $display("[%0t] Test 7: successive drops past the tolerance bound", $realtime);
        csr_write(REG_CONTROL, 32'h0000_0004);       // reboot
        repeat (8) @(posedge clk);
        bring_up(32'h0000_00E5);
        for (n = 0; n < NODE_COUNT; n = n + 1)
            check(!halt[n], $sformatf("precondition: node %0d running", n));

        for (victim = 1; victim <= 3; victim = victim + 1) begin
            @(posedge round_start[0]);
            #0.1;
            asym_drop_src   = DROP_SRC[7:0];
            asym_drop_dst   = victim[7:0];
            asym_drop_round = round_id[0];
            wait_rounds(1);
            asym_drop_round = {64{1'b1}};
            wait_rounds(4);
            $display("    after dropping %0d->%0d : sound sets %02h %02h %02h %02h %02h  halted %b%b%b%b%b",
                     DROP_SRC, victim,
                     node_sound_set[0], node_sound_set[1], node_sound_set[2],
                     node_sound_set[3], node_sound_set[4],
                     halt[0], halt[1], halt[2], halt[3], halt[4]);
        end

        // Two failures are survivable, the third is not.
        for (n = 0; n < NODE_COUNT; n = n + 1)
            check(halt[n],
                  $sformatf("node %0d still running after the cluster passed its tolerance bound", n));

        for (n = 0; n < NODE_COUNT; n = n + 1) commits_before[n] = commit_count[n];
        wait_rounds(4);
        for (n = 0; n < NODE_COUNT; n = n + 1)
            check(commit_count[n] == commits_before[n],
                  $sformatf("node %0d kept committing past the tolerance bound", n));
    end

    // ====== Test 8: live reconfiguration =================================
    // The cluster takes a new membership and run_id at a round the control
    // plane names, WITHOUT being stopped first. Cold start and reconfiguration
    // go through the same install path; the only difference is which state the
    // node was in when the effective round arrived.
    $display("[%0t] Test 8: live reconfiguration at a named round", $realtime);
    csr_write(REG_CONTROL, 32'h0000_0004);       // reboot
    repeat (8) @(posedge clk);
    link_enable_mask = {NODE_COUNT{1'b1}};
    asym_drop_round  = {64{1'b1}};
    bring_up(32'h0000_00F6);
    for (n = 0; n < NODE_COUNT; n = n + 1)
        check(!halt[n], $sformatf("precondition: node %0d running", n));

    // Stage the next config while the cluster keeps running.
    @(posedge round_start[0]);
    #0.1;
    target_round = round_id[0] + 64'd8;
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW,  target_round[31:0]);
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_HIGH, target_round[63:32]);
    csr_write(REG_CONFIG_RUN_ID,     32'h0000_0A07);
    csr_write(REG_CONFIG_MEMBERSHIP, {24'd0, AFTER_GAG});
    csr_write(REG_CONTROL, 32'h0000_0003);       // stay enabled, arm the activation

    // Armed configs are frozen: a late write must not be able to move the
    // effective round out from under an activation that is already pending.
    csr_write(REG_CONFIG_RUN_ID, 32'hDEAD_BEEF);
    csr_read_node(REG_CONFIG_RUN_ID, 0);
    check(csr_read_value == 32'h0000_0A07,
          $sformatf("armed config must be write-locked, read back %08h", csr_read_value));

    // Nothing may change before the named round.
    wait_rounds(3);
    for (n = 0; n < NODE_COUNT; n = n + 1) begin
        check(tx_run_id[n] == 32'h0000_00F6,
              $sformatf("node %0d switched early: run_id %08h", n, tx_run_id[n]));
        check(!halt[n], $sformatf("node %0d halted while waiting to reconfigure", n));
    end
    check(round_id[0] < target_round, "test setup: should still be before the effective round");

    // Cross the effective round. The continuity monitor handles the run change
    // by itself now, and will assert that the gap is exactly 3 rounds.
    wait (round_id[0] >= target_round);
    wait_rounds(4);

    for (n = 0; n < GAGGED_NODE; n = n + 1) begin
        check(tx_run_id[n] == 32'h0000_0A07,
              $sformatf("node %0d run_id %08h, expected 00000a07 after reconfig",
                        n, tx_run_id[n]));
        check(node_sound_set[n] == AFTER_GAG,
              $sformatf("node %0d sound set %02h, expected %02h after reconfig",
                        n, node_sound_set[n], AFTER_GAG));
        check(!halt[n], $sformatf("node %0d halted across the reconfiguration", n));
    end

    // The node the new config drops must go quiet and say why - not halt, and
    // not silently look like it was never activated.
    check(!halt[GAGGED_NODE],
          $sformatf("node %0d should go idle, not halt, when dropped by a config", GAGGED_NODE));
    csr_read_node(REG_STATUS, GAGGED_NODE);
    check(csr_read_value[4] === 1'b1,
          $sformatf("node %0d STATUS.config_excludes_self not set (%08h)",
                    GAGGED_NODE, csr_read_value));

    // The surviving members must make progress under the new config.
    for (n = 0; n < GAGGED_NODE; n = n + 1) commits_before[n] = commit_count[n];
    wait_rounds(6);
    for (n = 0; n < GAGGED_NODE; n = n + 1) begin
        check(commit_count[n] - commits_before[n] >= 4,
              $sformatf("node %0d not committing after reconfig (%0d commits)",
                        n, commit_count[n] - commits_before[n]));
        check(last_commit_set[n] == AFTER_GAG,
              $sformatf("node %0d commit set %02h, expected %02h",
                        n, last_commit_set[n], AFTER_GAG));
    end

    // COMMIT_COUNT must track what the commit port actually emitted.
    csr_read_node(REG_COMMIT_COUNT_LOW, 0);
    check(csr_read_value == commit_count[0],
          $sformatf("COMMIT_COUNT %0d, testbench counted %0d", csr_read_value, commit_count[0]));

    // ====== Test 9: a config too small to hold a quorum ====================
    // Needs n >= 5. The quorum universe is the physical cluster size, so it does
    // NOT shrink with the membership. Proposing {n-2 .. n-1} therefore installs
    // fine and then simply cannot assemble a quorum - the pair that moved halts,
    // and the nodes the config drops go idle.
    //
    // Safe but stuck, and that is the whole cost of the fixed-universe
    // simplification: two groups can never both commit, but a cluster reduced
    // below its quorum can only be recovered by the control plane. The check
    // that matters is that nobody commits under the smaller config.
    if (NODE_COUNT >= 5) begin
        $display("[%0t] Test 9: a config below quorum cannot commit", $realtime);
        csr_write(REG_CONTROL, 32'h0000_0004);
        repeat (8) @(posedge clk);
        bring_up(32'h0000_0B08);
        for (n = 0; n < NODE_COUNT; n = n + 1)
            check(!halt[n], $sformatf("precondition: node %0d running", n));

        @(posedge round_start[0]);
        #0.1;
        target_round = round_id[0] + 64'd8;
        csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW,  target_round[31:0]);
        csr_write(REG_CONFIG_EFFECTIVE_ROUND_HIGH, target_round[63:32]);
        csr_write(REG_CONFIG_RUN_ID,     32'h0000_0BAD);
        csr_write(REG_CONFIG_MEMBERSHIP, {24'd0, TOO_SMALL});
        csr_write(REG_CONTROL, 32'h0000_0003);

        wait (round_id[0] >= target_round);
        for (n = 0; n < NODE_COUNT; n = n + 1) commits_before[n] = commit_count[n];
        wait_rounds(6);

        // The two that moved must halt rather than commit with a minority.
        for (n = NODE_COUNT-2; n < NODE_COUNT; n = n + 1)
            check(halt[n],
                  $sformatf("node %0d committed under a below-quorum config instead of halting", n));
        // The ones the config dropped go idle and say why.
        for (n = 0; n < NODE_COUNT-2; n = n + 1) begin
            check(!halt[n], $sformatf("node %0d should go idle, not halt", n));
            csr_read_node(REG_STATUS, n);
            check(csr_read_value[4] === 1'b1,
                  $sformatf("node %0d STATUS.config_excludes_self not set (%08h)",
                            n, csr_read_value));
        end
        // Nobody may have committed anything under the new config.
        for (n = 0; n < NODE_COUNT; n = n + 1)
            check(commit_count[n] - commits_before[n] <= 1,
                  $sformatf("node %0d committed %0d rounds under a below-quorum config",
                            n, commit_count[n] - commits_before[n]));
    end

    // ---------------------------- summary --------------------------------
    $display("--------------------------------------------------");
    for (n = 0; n < NODE_COUNT; n = n + 1)
        $display("node %0d: commits=%0d  halted=%0b", n, commit_count[n], halt[n]);
    $display("checks : %0d", check_count);
    $display("errors : %0d", error_count);
    $display("--------------------------------------------------");
    if (error_count == 0) $display("[%0t] ALL TESTS PASSED", $realtime);
    else                  $display("[%0t] %0d FAILURES", $realtime, error_count);
    $finish;
end

initial begin
    #20_000_000;
    $display("[%0t] TIMEOUT", $realtime);
    $finish;
end

endmodule

`resetall
