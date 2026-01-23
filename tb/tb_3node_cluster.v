`timescale 1ns / 1ps

module tb_3node_cluster;

// Testbench for a 3-node consensus cluster
// This testbench instantiates 3 consensus_nic modules and simulates
// their interactions over a shared medium. It includes a simple
// time source and stimulus for sending packets.
// Parameters
localparam integer P_NODE_COUNT = 3;
localparam integer P_DATA_WIDTH = 512;
localparam integer P_SLOT_LEN_NS = 10000;  // 10us slot length
localparam integer P_GUARD_BAND_NS = 100;
localparam integer P_COMMIT_TIME_NS = 1000;   // save some time for
localparam integer P_ETHERNET_TYPE = 16'h88B5;

// Clock and reset
reg clk;
reg rst_n;

reg [63:0] ptp_ns;

wire [3*P_DATA_WIDTH-1:0]           s_axis_tx_tdata;
wire [2:0]                          s_axis_tx_tvalid;
wire [2:0]                          s_axis_tx_tlast;
wire [3*(P_DATA_WIDTH/8)-1:0]       s_axis_tx_tkeep;
wire [2:0]                          s_axis_tx_tready;

wire [3*P_DATA_WIDTH-1:0]           m_axis_rx_tdata;
wire [2:0]                          m_axis_rx_tvalid;
wire [2:0]                          m_axis_rx_tlast;
wire [3*(P_DATA_WIDTH/8)-1:0]       m_axis_rx_tkeep;
wire [2:0]                          m_axis_rx_tready;

// --- Commit Logs  ---
wire [511:0] commit_data_0, commit_data_1, commit_data_2;
wire         commit_valid_0, commit_valid_1, commit_valid_2;

assign m_axis_rx_tready = 3'b111; // Always ready to receive
assign s_axis_tx_tready = 3'b111; // Always ready to send

// Instantiate the atomic broadcast switch
atomic_broadcast_switch #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_DATA_WIDTH(P_DATA_WIDTH)
) switch_inst (
    .s_axis_tx_tdata(s_axis_tx_tdata),
    .s_axis_tx_tvalid(s_axis_tx_tvalid),
    .s_axis_tx_tlast(s_axis_tx_tlast),
    .s_axis_tx_tkeep(s_axis_tx_tkeep),
    .s_axis_tx_tready(s_axis_tx_tready),

    .m_axis_rx_tdata(m_axis_rx_tdata),
    .m_axis_rx_tvalid(m_axis_rx_tvalid),
    .m_axis_rx_tlast(m_axis_rx_tlast),
    .m_axis_rx_tkeep(m_axis_rx_tkeep),
    .m_axis_rx_tready(m_axis_rx_tready)
);

// Instantiate 3 consensus_nic nodes
// We need offset PTP times for each node
// Node 0
consensus_nic #(
    .P_NODE_ID(0),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_SLOT_LEN_NS(P_SLOT_LEN_NS),
    .P_GUARD_BAND_NS(P_GUARD_BAND_NS),
    .P_COMMIT_TIME_NS(P_COMMIT_TIME_NS),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE)
) node_0 (
    .clk(clk),
    .rst_n(rst_n),
    .i_ptp_ns(ptp_ns + 0),
    .i_tx_payload_vec({5{8'hAA}}), // Dummy payload

    // Network Interface
    .m_axis_tdata(s_axis_tx_tdata[0*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .m_axis_tkeep(s_axis_tx_tkeep[0*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .m_axis_tvalid(s_axis_tx_tvalid[0]),
    .m_axis_tlast(s_axis_tx_tlast[0]),
    .m_axis_tready(s_axis_tx_tready[0]),

    .s_axis_tdata(m_axis_rx_tdata[0*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .s_axis_tkeep(m_axis_rx_tkeep[0*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .s_axis_tvalid(m_axis_rx_tvalid[0]),
    .s_axis_tlast(m_axis_rx_tlast[0]),
    .s_axis_tready(m_axis_rx_tready[0]),

    // Commit log outputs
    .o_host_commit_data(commit_data_0),
    .o_host_commit_keep(),
    .o_host_commit_valid(commit_valid_0),
    .o_host_commit_last(),
    .i_host_commit_ready(1'b1)
);

// Node 1
consensus_nic #(
    .P_NODE_ID(1),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_SLOT_LEN_NS(P_SLOT_LEN_NS),
    .P_GUARD_BAND_NS(P_GUARD_BAND_NS),
    .P_COMMIT_TIME_NS(P_COMMIT_TIME_NS),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE)
) node_1 (
    .clk(clk),
    .rst_n(rst_n),
    .i_ptp_ns(ptp_ns - 100), // Offset PTP time
    .i_tx_payload_vec({5{8'hBB}}), // Dummy payload
    
    // Network Interface
    .m_axis_tdata(s_axis_tx_tdata[1*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .m_axis_tkeep(s_axis_tx_tkeep[1*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .m_axis_tvalid(s_axis_tx_tvalid[1]),
    .m_axis_tlast(s_axis_tx_tlast[1]),
    .m_axis_tready(s_axis_tx_tready[1]),

    .s_axis_tdata(m_axis_rx_tdata[1*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .s_axis_tkeep(m_axis_rx_tkeep[1*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .s_axis_tvalid(m_axis_rx_tvalid[1]),
    .s_axis_tlast(m_axis_rx_tlast[1]),
    .s_axis_tready(m_axis_rx_tready[1]),

    // Commit log outputs
    .o_host_commit_data(commit_data_1),
    .o_host_commit_keep(),
    .o_host_commit_valid(commit_valid_1),
    .o_host_commit_last(),
    .i_host_commit_ready(1'b1)
);

// Node 2
consensus_nic #(
    .P_NODE_ID(2),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_SLOT_LEN_NS(P_SLOT_LEN_NS),
    .P_GUARD_BAND_NS(P_GUARD_BAND_NS),
    .P_COMMIT_TIME_NS(P_COMMIT_TIME_NS),
    .P_ETHERNET_TYPE(P_ETHERNET_TYPE)
) node_2 (
    .clk(clk),
    .rst_n(rst_n),
    .i_ptp_ns(ptp_ns - 200), // Offset PTP time
    .i_tx_payload_vec({5{8'hCC}}), // Dummy payload

    // Network Interface
    .m_axis_tdata(s_axis_tx_tdata[2*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .m_axis_tkeep(s_axis_tx_tkeep[2*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .m_axis_tvalid(s_axis_tx_tvalid[2]),
    .m_axis_tlast(s_axis_tx_tlast[2]),
    .m_axis_tready(s_axis_tx_tready[2]),

    .s_axis_tdata(m_axis_rx_tdata[2*P_DATA_WIDTH +: P_DATA_WIDTH]),
    .s_axis_tkeep(m_axis_rx_tkeep[2*(P_DATA_WIDTH/8) +: (P_DATA_WIDTH/8)]),
    .s_axis_tvalid(m_axis_rx_tvalid[2]),
    .s_axis_tlast(m_axis_rx_tlast[2]),
    .s_axis_tready(m_axis_rx_tready[2]),

    // Commit log outputs
    .o_host_commit_data(commit_data_2),
    .o_host_commit_keep(),
    .o_host_commit_valid(commit_valid_2),
    .o_host_commit_last(),
    .i_host_commit_ready(1'b1)
);

// Main testbench logic

// clock generation
always #5 clk = ~clk; // 100MHz clock

initial begin
    $dumpfile("tb_3node_cluster.vcd");
    $dumpvars(0, tb_3node_cluster);

    // Initialize signals
    clk = 0;
    rst_n = 0;
    ptp_ns = 0;

    // Release reset
    #20;
    rst_n = 1;

    // Run simulation for a certain period
    repeat (10000) begin
        @(posedge clk);
        ptp_ns = ptp_ns + 10; // Increment PTP time by 10ns per clock
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
