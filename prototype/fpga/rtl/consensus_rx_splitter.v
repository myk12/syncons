`timescale 1ns / 1ps
`default_nettype none

/*
 * Shared application RX dispatcher.
 *
 * The datapath only distinguishes host traffic from application-owned traffic.
 * Once a frame has been classified as "app RX", this block performs the
 * second-stage demultiplexing inside the application cluster:
 * - consensus EtherType frames are delivered to the consensus app
 * - AI replay EtherType frames are delivered to the AI app
 *
 * Like the datapath, this dispatcher is frame-aware.  The route is decided on
 * the first beat of the frame and held until tlast so downstream apps always
 * see complete AXI-stream frames.
 */
module consensus_rx_splitter #(
    parameter [15:0] P_CONSENSUS_ETHERTYPE = 16'h88B5,
    parameter [15:0] P_DMA_ETHERTYPE = 16'h88B6,
    parameter integer P_HDR_ETHERTYPE_OFFSET_BYTES = 12,
    
    parameter IF_COUNT      = 1,
    parameter PORTS_PER_IF  = 1,
    parameter SCHED_PER_IF  = PORTS_PER_IF, // number of schedulers per interface (must be <= PORTS_PER_IF)
    parameter PORT_COUNT    = IF_COUNT * PORTS_PER_IF,

    parameter AXIS_IF_DATA_WIDTH = 512,
    parameter AXIS_IF_KEEP_WIDTH = (AXIS_IF_DATA_WIDTH / 8),
    parameter AXIS_IF_RX_ID_WIDTH = PORTS_PER_IF > 1 ? $clog2(PORTS_PER_IF) : 1,
    parameter AXIS_IF_RX_DEST_WIDTH = 8,
    parameter AXIS_IF_RX_USER_WIDTH = 1
) (
    input  wire                                 clk,
    input  wire                                 rst,

    // RX interface (from MAC to DMA) from MAC to rx splitter
    input  wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           s_axis_if_rx_tdata,
    input  wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           s_axis_if_rx_tkeep,
    input  wire [IF_COUNT-1:0]                              s_axis_if_rx_tvalid,
    output wire [IF_COUNT-1:0]                              s_axis_if_rx_tready,
    input  wire [IF_COUNT-1:0]                              s_axis_if_rx_tlast,
    input  wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]          s_axis_if_rx_tid,
    input  wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]        s_axis_if_rx_tdest,
    input  wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]        s_axis_if_rx_tuser,

    // RX interface (from DMA to MAC) from rx splitter to host DMA
    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           m_axis_if_rx_tdata_dma,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           m_axis_if_rx_tkeep_dma,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tvalid_dma,
    input  wire [IF_COUNT-1:0]                              m_axis_if_rx_tready_dma,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tlast_dma,
    output wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]          m_axis_if_rx_tid_dma,
    output wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]        m_axis_if_rx_tdest_dma,
    output wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]        m_axis_if_rx_tuser_dma,

    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           m_axis_if_rx_tdata_cons,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           m_axis_if_rx_tkeep_cons,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tvalid_cons,
    input  wire [IF_COUNT-1:0]                              m_axis_if_rx_tready_cons,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tlast_cons,
    output wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]          m_axis_if_rx_tid_cons,
    output wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]        m_axis_if_rx_tdest_cons,
    output wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]        m_axis_if_rx_tuser_cons
);

localparam [1:0] RX_ROUTE_DROP = 2'd0;
localparam [1:0] RX_ROUTE_CONS = 2'd1;
localparam [1:0] RX_ROUTE_DMA  = 2'd2;

wire consensus_ethertype_match = s_axis_app_rx_tvalid &&
    (s_axis_app_rx_tdata[P_HDR_ETHERTYPE_OFFSET_BYTES*8 +: 16] === {P_CONSENSUS_ETHERTYPE[7:0], P_CONSENSUS_ETHERTYPE[15:8]});
wire dma_ethertype_match = s_axis_app_rx_tvalid &&
    (s_axis_app_rx_tdata[P_HDR_ETHERTYPE_OFFSET_BYTES*8 +: 16] === {P_DMA_ETHERTYPE[7:0], P_DMA_ETHERTYPE[15:8]});

wire [1:0] rx_route_eff = (consensus_ethertype_match ? RX_ROUTE_CONS : (dma_ethertype_match ? RX_ROUTE_DMA : RX_ROUTE_DROP));


always @(*) begin
    m_axis_cons_rx_tdata  = {AXIS_DATA_WIDTH{1'b0}};
    m_axis_cons_rx_tkeep  = {AXIS_KEEP_WIDTH{1'b0}};
    m_axis_cons_rx_tvalid = 1'b0;
    m_axis_cons_rx_tlast  = 1'b0;
    m_axis_cons_rx_tuser  = {AXIS_RX_USER_WIDTH{1'b0}};
    m_axis_dma_rx_tdata   = {AXIS_DATA_WIDTH{1'b0}};
    m_axis_dma_rx_tkeep   = {AXIS_KEEP_WIDTH{1'b0'}};
    m_axis_dma_rx_tvalid  = 1'b0;
    m_axis_dma_rx_tlast   = 1'b0;
    m_axis_dma_rx_tuser   = {AXIS_RX_USER_WIDTH{1'b0}};

    s_axis_app_rx_tready  = 1'b1;

    case (rx_route_eff)
        RX_ROUTE_CONS: begin
            if (s_axis_app_rx_tvalid) begin
                m_axis_cons_rx_tdata    = s_axis_app_rx_tdata;
                m_axis_cons_rx_tkeep    = s_axis_app_rx_tkeep;
                m_axis_cons_rx_tvalid   = s_axis_app_rx_tvalid;
                m_axis_cons_rx_tlast    = s_axis_app_rx_tlast;
                m_axis_cons_rx_tuser    = s_axis_app_rx_tuser;
                s_axis_cons_rx_tready   = m_axis_cons_rx_tready;
            end
        end
        RX_ROUTE_DMA: begin
            if (s_axis_app_rx_tvalid) begin
                m_axis_dma_rx_tdata    = s_axis_app_rx_tdata;
                m_axis_dma_rx_tkeep    = s_axis_app_rx_tkeep;
                m_axis_dma_rx_tvalid   = s_axis_app_rx_tvalid;
                m_axis_dma_rx_tlast    = s_axis_app_rx_tlast;
                m_axis_dma_rx_tuser    = s_axis_app_rx_tuser;
                s_axis_dma_rx_tready   = m_axis_dma_rx_tready;
            end
        end
        default: begin
            // Unknown application traffic is dropped at the app boundary.  The
            // datapath should only send app-owned traffic here, so this case is
            // mainly a guard against inconsistent configuration.
            s_axis_app_rx_tready = 1'b1;
        end
    endcase
end

endmodule

`default_nettype wire