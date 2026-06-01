`timescale 1ns / 1ps

module tb_3node_cluster;

// Testbench for a 3-node consensus cluster
// This testbench instantiates 3 consensus_nic modules and simulates
// their interactions over a shared medium. It includes a simple
// time source and stimulus for sending packets.
// Parameters
localparam integer P_NODE_COUNT             = 3;
localparam integer P_DATA_WIDTH             = 512;
localparam integer P_SLOT_LEN_NS            = 4000;  // 4us slot length
localparam integer P_GUARD_BAND_NS          = 100;
localparam integer P_COMMIT_TIME_NS         = 1000;   // save some time for
localparam integer P_ETHERNET_TYPE          = 16'h88B5;
localparam integer P_LOG_ITEM_LEN           = 40; // bytes

// Clock and reset
reg             clk;
reg             rst_n;

reg [P_NODE_COUNT-1:0]    node_enable;
reg [63:0]      ptp_ns;

wire [3*P_DATA_WIDTH-1:0]           s_axis_tx_tdata;
wire [2:0]                          s_axis_tx_tvalid;
wire [2:0]                          s_axis_tx_tlast;
wire [3*(P_DATA_WIDTH/8)-1:0]       s_axis_tx_tkeep;
wire [3*(P_DATA_WIDTH/8)-1:0]       s_axis_tx_tuser;
wire [2:0]                          s_axis_tx_tready;

reg [3*P_DATA_WIDTH-1:0]           m_axis_rx_tdata;
reg [2:0]                          m_axis_rx_tvalid;
reg [2:0]                          m_axis_rx_tlast;
reg [3*(P_DATA_WIDTH/8)-1:0]       m_axis_rx_tkeep;
reg [3*(P_DATA_WIDTH/8)-1:0]       m_axis_rx_tuser;
reg [2:0]                          m_axis_rx_tready;

wire [P_NODE_COUNT-1:0]             o_system_halt;
wire [P_NODE_COUNT*4-1:0]           o_debug_state;

wire [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]        commit_data_0;
wire [P_NODE_COUNT-1:0]                         commit_valid_0;
wire                                            commit_ready_0;
wire                                            commit_last_0;

wire [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]        commit_data_1;
wire [P_NODE_COUNT-1:0]                         commit_valid_1;
wire                                            commit_ready_1;
wire                                            commit_last_1;

wire [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]        commit_data_2;
wire [P_NODE_COUNT-1:0]                         commit_valid_2;
wire                                            commit_ready_2;
wire                                            commit_last_2;

//------------------------------------------------
//          Instantiate 3 nodes
//------------------------------------------------
// We need offset PTP times for each node
// Node 0
consensus_node #(
    .P_NODE_ID(0),
    .P_NODE_COUNT(P_NODE_COUNT),

    .P_SLOT_DURATION_NS(P_SLOT_LEN_NS),
    .P_GUARD_BAND_NS(P_GUARD_BAND_NS),
    .P_COMMIT_TIME_NS(P_COMMIT_TIME_NS),

    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE),
    .P_NODE_MAC_ADDR(48'h00_0a_35_06_50_94)
) node_0 (
    .clk(clk),
    .rst_n(rst_n),

    .i_enable(node_enable[0]),
    .i_ptp_time_ns(ptp_ns + 0),

    // Network Interface
    .m_axis_tdata(s_axis_tx_tdata[0*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .m_axis_tkeep(s_axis_tx_tkeep[0*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .m_axis_tvalid(s_axis_tx_tvalid[0]),
    .m_axis_tlast(s_axis_tx_tlast[0]),
    .m_axis_tuser(s_axis_tx_tuser[0]),
    .m_axis_tready(s_axis_tx_tready[0]),

    .s_axis_tdata(m_axis_rx_tdata[0*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .s_axis_tkeep(m_axis_rx_tkeep[0*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .s_axis_tvalid(m_axis_rx_tvalid[0]),
    .s_axis_tlast(m_axis_rx_tlast[0]),
    .s_axis_tuser(m_axis_rx_tuser[0]),
    .s_axis_tready(m_axis_rx_tready[0]),

    // System outputs
    .o_system_halt(o_system_halt[0]),
    .o_debug_state(o_debug_state[0*4 +: 4]),

    // Commit log outputs
    .o_host_commit_data(commit_data_0),
    .o_host_commit_keep(),
    .o_host_commit_valid(commit_valid_0),
    .o_host_commit_last(commit_last_0),
    .i_host_commit_ready(1'b1)
);

// Node 1
consensus_node #(
    .P_NODE_ID(1),
    .P_NODE_COUNT(P_NODE_COUNT),

    .P_SLOT_DURATION_NS(P_SLOT_LEN_NS),
    .P_GUARD_BAND_NS(P_GUARD_BAND_NS),
    .P_COMMIT_TIME_NS(P_COMMIT_TIME_NS),

    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE),
    .P_NODE_MAC_ADDR(48'h00_0a_35_06_09_24)
) node_1 (
    .clk(clk),
    .rst_n(rst_n),

    .i_enable(node_enable[1]),
    .i_ptp_time_ns(ptp_ns - 50), // Offset PTP time

    // System outputs
    .o_system_halt(o_system_halt[1]),
    .o_debug_state(o_debug_state[1*4 +: 4]),

    // Network Interface
    .m_axis_tdata(s_axis_tx_tdata[1*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .m_axis_tkeep(s_axis_tx_tkeep[1*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .m_axis_tvalid(s_axis_tx_tvalid[1]),
    .m_axis_tlast(s_axis_tx_tlast[1]),
    .m_axis_tuser(s_axis_tx_tuser[1]),
    .m_axis_tready(s_axis_tx_tready[1]),

    .s_axis_tdata(m_axis_rx_tdata[1*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .s_axis_tkeep(m_axis_rx_tkeep[1*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .s_axis_tvalid(m_axis_rx_tvalid[1]),
    .s_axis_tlast(m_axis_rx_tlast[1]),
    .s_axis_tuser(m_axis_rx_tuser[1]),
    .s_axis_tready(m_axis_rx_tready[1]),

    // Commit log outputs
    .o_host_commit_data(commit_data_1),
    .o_host_commit_keep(),
    .o_host_commit_valid(commit_valid_1),
    .o_host_commit_last(commit_last_1),
    .i_host_commit_ready(1'b1)
);

// Node 2
consensus_node #(
    .P_NODE_ID(2),
    .P_NODE_COUNT(P_NODE_COUNT),

    .P_SLOT_DURATION_NS(P_SLOT_LEN_NS),
    .P_GUARD_BAND_NS(P_GUARD_BAND_NS),
    .P_COMMIT_TIME_NS(P_COMMIT_TIME_NS),

    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE),
    .P_NODE_MAC_ADDR(48'h00_0a_35_06_0b_84)
) node_2 (
    .clk(clk),
    .rst_n(rst_n),

    .i_enable(node_enable[2]),
    .i_ptp_time_ns(ptp_ns - 100), // Offset PTP time

    // Network Interface
    .m_axis_tdata(s_axis_tx_tdata[2*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .m_axis_tkeep(s_axis_tx_tkeep[2*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .m_axis_tvalid(s_axis_tx_tvalid[2]),
    .m_axis_tlast(s_axis_tx_tlast[2]),
    .m_axis_tuser(s_axis_tx_tuser[2]),
    .m_axis_tready(s_axis_tx_tready[2]),

    .s_axis_tdata(m_axis_rx_tdata[2*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .s_axis_tkeep(m_axis_rx_tkeep[2*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .s_axis_tvalid(m_axis_rx_tvalid[2]),
    .s_axis_tlast(m_axis_rx_tlast[2]),
    .s_axis_tuser(m_axis_rx_tuser[2]),
    .s_axis_tready(m_axis_rx_tready[2]),

    // Commit log outputs
    .o_host_commit_data(commit_data_2),
    .o_host_commit_keep(),
    .o_host_commit_valid(commit_valid_2),
    .o_host_commit_last(commit_last_2),
    .i_host_commit_ready(1'b1)
);

//------------------------------------------------
//              Routing Switch Logic
//------------------------------------------------
integer src, dst;
always @(*) begin
    // clear all RX ports default
    for (dst = 0; dst < P_NODE_COUNT; dst = dst + 1) begin
        m_axis_rx_tdata[dst*P_DATA_WIDTH +: P_DATA_WIDTH] = {P_DATA_WIDTH{1'b0}};
        m_axis_rx_tkeep[dst*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)] = {P_DATA_WIDTH/8{1'b0}};
        m_axis_rx_tvalid[dst] = 1'b0;
        m_axis_rx_tlast[dst]  = 1'b0;
        m_axis_rx_tuser[dst]  = 1'b0;
    end

    // route TX to RX of other nodes
    for (src = 0; src < P_NODE_COUNT; src = src + 1) begin
        if (s_axis_tx_tvalid[src]) begin
            for (dst = 0; dst < P_NODE_COUNT; dst = dst + 1) begin
                if (dst != src) begin
                    m_axis_rx_tdata[dst*P_DATA_WIDTH +: P_DATA_WIDTH]  = s_axis_tx_tdata[src*P_DATA_WIDTH +: P_DATA_WIDTH];
                    m_axis_rx_tkeep[dst*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)] = s_axis_tx_tkeep[src*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)];
                    m_axis_rx_tvalid[dst] = 1'b1;
                    m_axis_rx_tlast[dst]  = s_axis_tx_tlast[src];
                    m_axis_rx_tuser[dst]  = s_axis_tx_tuser[src];
                end
            end
        end
    end
end

// Connect tready signals - always ready to accept data
assign s_axis_tx_tready = 3'b111;

//------------------------------------------------
//              Testbench Stimulus
//------------------------------------------------
// clock generation
always begin
    clk = 0;
    forever #2 clk = ~clk; // 250MHz clock
end

initial begin
    $dumpfile("tb_3node_cluster.vcd");
    $dumpvars(0, tb_3node_cluster);

    // Initialize signals
    clk = 0;
    rst_n = 0;
    node_enable = 3'b000;
    ptp_ns = 0;

    // Release reset
    #20;
    rst_n = 1;
    node_enable = 3'b111; // Enable all nodes
    #20;

    // Run simulation for a certain period
    repeat (4000) begin
        @(posedge clk);
        ptp_ns = ptp_ns + 4; // Increment PTP time by 4ns per clock cycle
    end

    $display("Simulation complete.");
    $finish;
end

// log monitoring
always @(posedge clk) begin
    if (commit_valid_0) begin
        $display("Node 0 committed data: %h at time %d ns", commit_data_0, ptp_ns);
    end
    if (commit_valid_1) begin
        $display("Node 1 committed data: %h at time %d ns", commit_data_1, ptp_ns);
    end
    if (commit_valid_2) begin
        $display("Node 2 committed data: %h at time %d ns", commit_data_2, ptp_ns);
    end
end

endmodule
