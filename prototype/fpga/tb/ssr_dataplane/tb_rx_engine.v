`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_rx_engine - three complete nodes talking to each other.
 *
 * Each node is consensus_core + tx_engine + rx_engine, and the "network" is a
 * single broadcast register: TDMA guarantees one transmitter at a time, so one
 * frame in flight is a faithful medium.
 *
 * The stimulus is real frames from tx_engine rather than hand-built bytes, which
 * is the point of having built the transmit side first - a header field that the
 * two sides disagree about shows up here instead of on hardware, and the bench
 * cannot drift from the wire format because neither side is written down twice.
 *
 * What is checked is the property the whole datapath exists for: after a round,
 * every node's commit ring holds every peer's payload at the right (round, node)
 * address - the peers' by way of the wire, its own by way of the local path,
 * since a broadcast never comes back to the port it left.
 */
module tb_rx_engine;

localparam integer CLK_PERIOD_NS      = 4;
localparam integer NODE_COUNT         = 3;
localparam integer ROUND_LENGTH_NS    = 4000;
localparam integer GUARD_TIME_NS      = 200;
localparam integer TX_SUBSLOT_NS      = 400;
localparam integer TX_ADMIT_MARGIN_NS = 100;

localparam integer AXIS_DATA_WIDTH = 512;
localparam integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8;
localparam integer AXIS_USER_WIDTH = 17;
localparam integer PAYLOAD_BYTES   = 32;
localparam integer SLOT_BEATS      = 16;

localparam [23:0] RB_BASE_ADDR = 24'h003000;
localparam [23:0] REG_CONTROL                    = RB_BASE_ADDR + 24'h00C;
localparam [23:0] REG_CONFIG_RUN_ID              = RB_BASE_ADDR + 24'h100;
localparam [23:0] REG_CONFIG_MEMBERSHIP          = RB_BASE_ADDR + 24'h104;
localparam [23:0] REG_CONFIG_EFFECTIVE_ROUND_LOW = RB_BASE_ADDR + 24'h108;

`include "ssr_packet.vh"

// -------------------------------------------------------------------------
reg clk = 1'b0, rst = 1'b1;
always #(CLK_PERIOD_NS/2.0) clk = ~clk;

reg [47:0] time_seconds     = 48'd7;
reg [31:0] time_nanoseconds = 32'd0;
reg        time_advancing   = 1'b0;
always @(posedge clk) if (time_advancing) begin
    if (time_nanoseconds + CLK_PERIOD_NS >= 32'd1_000_000_000) begin
        time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS - 32'd1_000_000_000;
        time_seconds     <= time_seconds + 48'd1;
    end else time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS;
end

reg  [23:0] csr_addr = 24'd0;
reg  [31:0] csr_data = 32'd0;
reg         csr_en   = 1'b0;
wire        csr_ack [0:NODE_COUNT-1];

// -------------------------------------------------------------------------
// network: one frame in flight, broadcast to everyone but the sender
// -------------------------------------------------------------------------
reg [AXIS_DATA_WIDTH-1:0] net_tdata  = {AXIS_DATA_WIDTH{1'b0}};
reg [AXIS_KEEP_WIDTH-1:0] net_tkeep  = {AXIS_KEEP_WIDTH{1'b0}};
reg [AXIS_USER_WIDTH-1:0] net_tuser  = {AXIS_USER_WIDTH{1'b0}};
reg                       net_tvalid = 1'b0;
reg [7:0]                 net_src    = 8'hFF;

// test knobs
reg [NODE_COUNT-1:0] link_enable = {NODE_COUNT{1'b1}};
// Corruption is aimed at ONE source. Blanking every frame would simply starve
// the cluster of rows and halt it, which tests nothing about the drop paths.
reg [7:0]            corrupt_src       = 8'hFF;
reg                  corrupt_ethertype = 1'b0;
reg                  corrupt_run_id    = 1'b0;

wire [AXIS_DATA_WIDTH-1:0] tx_tdata  [0:NODE_COUNT-1];
wire [AXIS_KEEP_WIDTH-1:0] tx_tkeep  [0:NODE_COUNT-1];
wire [AXIS_USER_WIDTH-1:0] tx_tuser  [0:NODE_COUNT-1];
wire                       tx_tvalid [0:NODE_COUNT-1];
wire                       tx_tlast  [0:NODE_COUNT-1];

integer net_i;
always @(posedge clk) begin
    net_tvalid <= 1'b0;
    for (net_i = 0; net_i < NODE_COUNT; net_i = net_i + 1) begin
        if (tx_tvalid[net_i] && tx_tlast[net_i] && link_enable[net_i]) begin
            net_tdata  <= tx_tdata[net_i];
            net_tkeep  <= tx_tkeep[net_i];
            net_tuser  <= tx_tuser[net_i];
            net_src    <= net_i[7:0];
            net_tvalid <= 1'b1;
            if (corrupt_ethertype && net_i[7:0] == corrupt_src)
                net_tdata[SSR_OFF_ETHERTYPE*8 +: 16] <= 16'h0800;
            if (corrupt_run_id && net_i[7:0] == corrupt_src)
                net_tdata[SSR_OFF_RUN_ID*8 +: 32] <= 32'hDEAD_BEEF;
        end
    end
end

// -------------------------------------------------------------------------
// ring-write scoreboard, per node
// -------------------------------------------------------------------------
reg [7:0]  ring_payload0 [0:NODE_COUNT-1][0:NODE_COUNT-1];  // [observer][source]
reg [63:0] ring_round    [0:NODE_COUNT-1][0:NODE_COUNT-1];
integer    ring_writes   [0:NODE_COUNT-1];
integer    sb_i, sb_j;
initial for (sb_i = 0; sb_i < NODE_COUNT; sb_i = sb_i + 1) begin
    ring_writes[sb_i] = 0;
    for (sb_j = 0; sb_j < NODE_COUNT; sb_j = sb_j + 1) begin
        ring_payload0[sb_i][sb_j] = 8'd0;
        ring_round[sb_i][sb_j]    = 64'd0;
    end
end

// -------------------------------------------------------------------------
integer error_count = 0, check_count = 0;
task check(input condition, input string message);
begin
    check_count = check_count + 1;
    if (!condition) begin
        $display("[%0t] ERROR: %0s", $realtime, message);
        error_count = error_count + 1;
    end
end
endtask

// -------------------------------------------------------------------------
wire [31:0] rx_frames   [0:NODE_COUNT-1];
wire [31:0] rx_foreign  [0:NODE_COUNT-1];
wire [31:0] rx_rejected [0:NODE_COUNT-1];
wire [31:0] rx_local    [0:NODE_COUNT-1];
wire [31:0] rx_collide  [0:NODE_COUNT-1];
wire        node_halt   [0:NODE_COUNT-1];
wire        commit_valid[0:NODE_COUNT-1];
wire [63:0] core_round  [0:NODE_COUNT-1];

genvar g;
generate
for (g = 0; g < NODE_COUNT; g = g + 1) begin : g_node

    wire        tx_start, tx_win, tx_end, round_start;
    wire [63:0] tx_round_id;
    wire [31:0] tx_run_id;
    wire [7:0]  tx_row;
    wire        rx_valid, rx_accepted;
    wire [7:0]  rx_node_id, rx_row;
    wire [31:0] rx_run_id;
    wire [63:0] rx_round_id;

    consensus_core #(
        .P_NODE_COUNT(NODE_COUNT), .P_NODE_ID(g), .RB_BASE_ADDR(RB_BASE_ADDR),
        .ROUND_LENGTH_NS(ROUND_LENGTH_NS), .GUARD_TIME_NS(GUARD_TIME_NS),
        .TX_SUBSLOT_NS(TX_SUBSLOT_NS), .TX_ADMIT_MARGIN_NS(TX_ADMIT_MARGIN_NS)
    ) core (
        .clk(clk), .rst(rst), .i_enable(1'b1),
        .i_ptp_tod_sec(time_seconds), .i_ptp_tod_ns(time_nanoseconds),
        .i_ptp_time_valid(1'b1), .i_ptp_step(1'b0),
        .reg_wr_addr(csr_addr), .reg_wr_data(csr_data), .reg_wr_strb(4'hF),
        .reg_wr_en(csr_en), .reg_wr_wait(), .reg_wr_ack(csr_ack[g]),
        .reg_rd_addr(24'd0), .reg_rd_en(1'b0), .reg_rd_data(), .reg_rd_wait(), .reg_rd_ack(),
        .o_round_id(core_round[g]), .o_round_start_pulse(round_start),
        .o_round_boundary_pulse(),
        .o_tx_start_pulse(tx_start), .o_tx_end_pulse(tx_end), .o_tx_window(tx_win),
        .o_rx_start_pulse(), .o_rx_end_pulse(), .o_rx_window(),
        .o_tx_round_id(tx_round_id), .o_tx_run_id(tx_run_id), .o_tx_row(tx_row),
        .i_rx_valid(rx_valid), .i_rx_node_id(rx_node_id), .i_rx_row(rx_row),
        .i_rx_run_id(rx_run_id), .i_rx_round_id(rx_round_id),
        .o_rx_accepted(rx_accepted),
        .o_commit_valid(commit_valid[g]), .o_commit_round_id(), .o_commit_set(),
        .o_halt(node_halt[g]), .o_time_fault(), .o_time_fault_count()
    );

    // proposal_buffer model: always has a slot, byte 0 identifies the source so
    // the scoreboard can tell whose payload landed where.
    reg [4:0] buf_beat = 5'd0;
    wire      buf_valid = 1'b1;
    wire      buf_last  = (buf_beat == SLOT_BEATS-1);
    wire      buf_ready;
    wire [7:0] my_tag = 8'hA0 + g[7:0];
    wire [AXIS_DATA_WIDTH-1:0] buf_data = {{(AXIS_DATA_WIDTH-8){1'b0}}, my_tag};
    always @(posedge clk) begin
        if (rst) buf_beat <= 5'd0;
        else if (buf_valid && buf_ready)
            buf_beat <= buf_last ? 5'd0 : buf_beat + 5'd1;
    end

    wire                       local_valid;
    wire [63:0]                local_round;
    wire [PAYLOAD_BYTES*8-1:0] local_payload;

    tx_engine #(
        .P_NODE_ID(g), .P_NODE_COUNT(NODE_COUNT),
        .P_SRC_MAC({40'h02_00_00_00_00, g[7:0]}),
        .P_PAYLOAD_BYTES(PAYLOAD_BYTES),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH), .AXIS_USER_WIDTH(AXIS_USER_WIDTH)
    ) tx (
        .clk(clk), .rst(rst),
        .i_tx_start_pulse(tx_start), .i_tx_window(tx_win), .i_tx_end_pulse(tx_end),
        .i_tx_round_id(tx_round_id), .i_tx_run_id(tx_run_id), .i_tx_row(tx_row),
        .i_buf_rd_data(buf_data), .i_buf_rd_valid(buf_valid),
        .o_buf_rd_ready(buf_ready), .i_buf_tx_last(buf_last),
        .m_axis_tdata(tx_tdata[g]), .m_axis_tkeep(tx_tkeep[g]),
        .m_axis_tvalid(tx_tvalid[g]), .m_axis_tready(1'b1),
        .m_axis_tlast(tx_tlast[g]), .m_axis_tuser(tx_tuser[g]),
        .o_local_valid(local_valid), .o_local_round_id(local_round),
        .o_local_payload(local_payload),
        .o_frame_count(), .o_empty_count(), .o_overrun_count(), .o_missed_count()
    );

    // everyone but the sender sees the frame
    wire net_for_me = net_tvalid && (net_src != g);

    wire                       ring_wr_valid;
    wire [63:0]                ring_wr_round;
    wire [7:0]                 ring_wr_node;
    wire [PAYLOAD_BYTES*8-1:0] ring_wr_payload;

    rx_engine #(
        .P_NODE_ID(g), .P_NODE_COUNT(NODE_COUNT), .P_PAYLOAD_BYTES(PAYLOAD_BYTES),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH), .AXIS_USER_WIDTH(AXIS_USER_WIDTH)
    ) rx (
        .clk(clk), .rst(rst),
        .s_axis_tdata(net_tdata), .s_axis_tkeep(net_tkeep),
        .s_axis_tvalid(net_for_me), .s_axis_tready(),
        .s_axis_tlast(1'b1), .s_axis_tuser(net_tuser),
        .o_rx_valid(rx_valid), .o_rx_node_id(rx_node_id), .o_rx_row(rx_row),
        .o_rx_run_id(rx_run_id), .o_rx_round_id(rx_round_id),
        .i_rx_accepted(rx_accepted),
        .i_local_valid(local_valid), .i_local_round_id(local_round),
        .i_local_payload(local_payload),
        .o_ring_wr_valid(ring_wr_valid), .o_ring_wr_round_id(ring_wr_round),
        .o_ring_wr_node_id(ring_wr_node), .o_ring_wr_payload(ring_wr_payload),
        .o_frame_count(rx_frames[g]), .o_foreign_count(rx_foreign[g]),
        .o_rejected_count(rx_rejected[g]), .o_local_count(rx_local[g]),
        .o_collision_count(rx_collide[g])
    );

    // scoreboard: record every ring write and check it on the spot
    always @(posedge clk) begin
        if (!rst && ring_wr_valid) begin
            check(ring_wr_node < NODE_COUNT,
                  $sformatf("node %0d: ring write for node %0d, out of range", g, ring_wr_node));
            // Byte 0 identifies the source. A payload landing under the wrong
            // node id is the failure the ring addressing exists to prevent.
            check(ring_wr_payload[7:0] == (8'hA0 + ring_wr_node),
                  $sformatf("node %0d: ring[node %0d] payload %02h, expected %02h",
                            g, ring_wr_node, ring_wr_payload[7:0], 8'hA0 + ring_wr_node));
            ring_payload0[g][ring_wr_node] = ring_wr_payload[7:0];
            ring_round[g][ring_wr_node]    = ring_wr_round;
            ring_writes[g] = ring_writes[g] + 1;
        end
    end
end
endgenerate

task csr_write(input [23:0] a, input [31:0] d);
    integer q;
begin
    @(negedge clk); csr_addr=a; csr_data=d; csr_en=1'b1; q=0;
    while (q<16) begin @(posedge clk); #0.1; if (csr_ack[0]) q=99; else q=q+1; end
    @(negedge clk); csr_en=1'b0;
end
endtask

task wait_rounds(input integer n);
begin repeat (n*ROUND_LENGTH_NS/CLK_PERIOD_NS) @(posedge clk); end
endtask

task bring_up(input [31:0] run_id_value);
begin
    csr_write(REG_CONTROL, 32'h0000_0004);          // reboot
    repeat (8) @(posedge clk);
    csr_write(REG_CONTROL, 32'h0000_0000);
    csr_write(REG_CONFIG_RUN_ID,     run_id_value);
    csr_write(REG_CONFIG_MEMBERSHIP, 32'h0000_0007);
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW, 32'h0000_0100);
    csr_write(REG_CONTROL, 32'h0000_0003);
    wait (g_node[0].core.state_reg == 2'd2);
    wait_rounds(4);
end
endtask

// -------------------------------------------------------------------------
integer n, m, writes_before [0:NODE_COUNT-1];
integer foreign_before, rejected_before;

initial begin
    $dumpfile("build/tb_rx_engine.vcd");
    $dumpvars(0, tb_rx_engine);

    rst = 1'b1; time_advancing = 1'b0;
    repeat (10) @(posedge clk);
    time_advancing = 1'b1; rst = 1'b0;
    repeat (5) @(posedge clk);

    csr_write(REG_CONFIG_RUN_ID,     32'h0000_0077);
    csr_write(REG_CONFIG_MEMBERSHIP, 32'h0000_0007);
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW, 32'h0000_0100);
    csr_write(REG_CONTROL, 32'h0000_0003);
    wait (g_node[0].core.state_reg == 2'd2);
    wait_rounds(4);

    // ---------------- Test 0: the cluster runs on its own frames ---------
    $display("[%0t] Test 0: three nodes running on real frames", $realtime);
    for (n = 0; n < NODE_COUNT; n = n + 1)
        check(!node_halt[n], $sformatf("node %0d halted on real traffic", n));

    // ---------------- Test 1: every node holds every payload -------------
    // Peers arrive over the wire; the node's own comes from tx_engine, because
    // a broadcast never returns to the port it left.
    $display("[%0t] Test 1: each ring holds all %0d payloads", $realtime, NODE_COUNT);
    wait_rounds(3);
    for (n = 0; n < NODE_COUNT; n = n + 1)
        for (m = 0; m < NODE_COUNT; m = m + 1)
            check(ring_payload0[n][m] == 8'hA0 + m,
                  $sformatf("node %0d ring[node %0d] = %02h, expected %02h",
                            n, m, ring_payload0[n][m], 8'hA0 + m));

    // all observers must agree on which round each entry belongs to
    for (m = 0; m < NODE_COUNT; m = m + 1)
        for (n = 1; n < NODE_COUNT; n = n + 1)
            check(ring_round[n][m] == ring_round[0][m],
                  $sformatf("node %0d and node 0 disagree on the round of node %0d's entry",
                            n, m));

    // ---------------- Test 2: one write per node per round ---------------
    $display("[%0t] Test 2: %0d ring writes per round per node", $realtime, NODE_COUNT);
    for (n = 0; n < NODE_COUNT; n = n + 1) writes_before[n] = ring_writes[n];
    wait_rounds(6);
    for (n = 0; n < NODE_COUNT; n = n + 1) begin
        check(ring_writes[n] - writes_before[n] >= 6*NODE_COUNT - NODE_COUNT &&
              ring_writes[n] - writes_before[n] <= 6*NODE_COUNT + NODE_COUNT,
              $sformatf("node %0d: %0d ring writes over 6 rounds, expected about %0d",
                        n, ring_writes[n] - writes_before[n], 6*NODE_COUNT));
        check(rx_local[n] > 0, $sformatf("node %0d never recorded its own payload", n));
        check(rx_collide[n] == 0,
              $sformatf("node %0d saw %0d ring-port collisions", n, rx_collide[n]));
    end

    // ---------------- Test 3: a stale run_id reaches the core and loses --
    // Which frames count is the core's call, not rx_engine's - the whole reason
    // i_rx_accepted exists instead of a second copy of the rule over here.
    // Only node 2's frames are spoiled, so nodes 0 and 1 keep each other and the
    // cluster stays up while node 2 is squeezed out.
    $display("[%0t] Test 3: stale run_id is rejected by the core", $realtime);
    rejected_before = rx_rejected[0];
    foreign_before  = rx_foreign[0];
    corrupt_src = 8'd2; corrupt_run_id = 1'b1;
    wait_rounds(3);
    corrupt_run_id = 1'b0;

    check(rx_rejected[0] > rejected_before,
          "a frame with a stale run_id should have been rejected by the core");
    check(rx_foreign[0] == foreign_before,
          "a stale run_id is not a foreign frame - it must reach the core first");
    check(!node_halt[0] && !node_halt[1],
          "spoiling one peer must not take down the other two");

    // ---------------- Test 4: a foreign ethertype never reaches the core --
    $display("[%0t] Test 4: wrong ethertype is dropped before the core", $realtime);
    bring_up(32'h0000_0088);
    for (n = 0; n < NODE_COUNT; n = n + 1)
        check(!node_halt[n], $sformatf("precondition: node %0d running", n));

    foreign_before  = rx_foreign[0];
    rejected_before = rx_rejected[0];
    corrupt_src = 8'd2; corrupt_ethertype = 1'b1;
    wait_rounds(3);
    corrupt_ethertype = 1'b0;

    check(rx_foreign[0] > foreign_before, "foreign frames should have been counted");
    check(rx_rejected[0] == rejected_before,
          "a foreign frame must be dropped before the core ever sees it");
    check(!node_halt[0] && !node_halt[1],
          "dropping one peer's frames must not take down the other two");

    $display("--------------------------------------------------");
    for (n = 0; n < NODE_COUNT; n = n + 1)
        $display("node %0d: frames=%0d foreign=%0d rejected=%0d local=%0d writes=%0d halt=%0b",
                 n, rx_frames[n], rx_foreign[n], rx_rejected[n], rx_local[n],
                 ring_writes[n], node_halt[n]);
    $display("checks : %0d", check_count);
    $display("errors : %0d", error_count);
    $display("--------------------------------------------------");
    if (error_count == 0) $display("[%0t] ALL TESTS PASSED", $realtime);
    else                  $display("[%0t] %0d FAILURES", $realtime, error_count);
    $finish;
end

initial begin
    #3_000_000;
    $display("[%0t] TIMEOUT", $realtime);
    $finish;
end

endmodule

`resetall
