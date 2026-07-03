`timescale 1ns / 1ps

module consensus_tx_arbiter #(
    parameter integer AXIS_DATA_WIDTH = 512,
    parameter integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8,
    parameter integer AXIS_TX_USER_WIDTH = 1,
    parameter integer AXIS_IF_TX_ID_WIDTH = 12,
    parameter integer AXIS_IF_TX_DEST_WIDTH = 4
) (
    input  wire [AXIS_DATA_WIDTH-1:0]           s_axis_cons_tx_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0]           s_axis_cons_tx_tkeep,
    input  wire                                 s_axis_cons_tx_tvalid,
    input  wire                                 s_axis_cons_tx_tlast,
    input  wire [AXIS_TX_USER_WIDTH-1:0]        s_axis_cons_tx_tuser,
    input  wire [AXIS_IF_TX_ID_WIDTH-1:0]       s_axis_cons_tx_tid,
    input  wire [AXIS_IF_TX_DEST_WIDTH-1:0]     s_axis_cons_tx_tdest,
    output reg                                  s_axis_cons_tx_tready,

    input  wire [AXIS_DATA_WIDTH-1:0]           s_axis_dma_tx_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0]           s_axis_dma_tx_tkeep,
    input  wire                                 s_axis_dma_tx_tvalid,
    input  wire                                 s_axis_dma_tx_tlast,
    input  wire [AXIS_TX_USER_WIDTH-1:0]        s_axis_dma_tx_tuser,
    input  wire [AXIS_IF_TX_ID_WIDTH-1:0]       s_axis_dma_tx_tid,
    input  wire [AXIS_IF_TX_DEST_WIDTH-1:0]     s_axis_dma_tx_tdest,
    output reg                                  s_axis_dma_tx_tready,

    // TX CPL from MAC
    input  wire [IF_COUNT*PTP_TS_WIDTH-1:0]                 s_axis_tx_cpl_ts,
    input  wire [IF_COUNT*TX_TAG_WIDTH-1:0]                 s_axis_tx_cpl_tag,
    input  wire [IF_COUNT-1:0]                              s_axis_tx_cpl_valid,
    output wire [IF_COUNT-1:0]                              s_axis_tx_cpl_ready,

    // TX CPL to DMA
    output wire [IF_COUNT*PTP_TS_WIDTH-1:0]                 m_axis_tx_cpl_ts,
    output wire [IF_COUNT*TX_TAG_WIDTH-1:0]                 m_axis_tx_cpl_tag,
    output wire [IF_COUNT-1:0]                              m_axis_tx_cpl_valid,
    input  wire [IF_COUNT-1:0]                              m_axis_tx_cpl_ready,

    output reg  [AXIS_DATA_WIDTH-1:0]           m_axis_tx_tdata,
    output reg  [AXIS_KEEP_WIDTH-1:0]           m_axis_tx_tkeep,
    output reg                                  m_axis_tx_tvalid,
    output reg                                  m_axis_tx_tlast,
    output reg  [AXIS_TX_USER_WIDTH-1:0]        m_axis_tx_tuser,
    input  wire                                 m_axis_tx_tready,
    output wire [AXIS_IF_TX_ID_WIDTH-1:0]       m_axis_tx_tid,
    output wire [AXIS_IF_TX_DEST_WIDTH-1:0]     m_axis_tx_tdest
);


always @(*) begin
    m_axis_tx_tdata = {AXIS_DATA_WIDTH{1'b0}};
    m_axis_tx_tkeep = {AXIS_KEEP_WIDTH{1'b0}};
    m_axis_tx_tvalid = 1'b0;
    m_axis_tx_tlast = 1'b0;
    m_axis_tx_tid = {AXIS_IF_TX_ID_WIDTH{1'b0}};
    m_axis_tx_tdest = {AXIS_IF_TX_DEST_WIDTH{1'b0}};
    m_axis_tx_tuser = {AXIS_TX_USER_WIDTH{1'b0}};

    s_axis_cons_tx_tready = 1'b0;
    s_axis_dma_tx_tready = 1'b0;

    if (s_axis_cons_tx_tvalid) begin
            m_axis_tx_tdata = s_axis_cons_tx_tdata;
            m_axis_tx_tkeep = s_axis_cons_tx_tkeep;
            m_axis_tx_tvalid = s_axis_cons_tx_tvalid;
            m_axis_tx_tlast = s_axis_cons_tx_tlast;
            m_axis_tx_tid = s_axis_cons_tx_tid;
            m_axis_tx_tdest = s_axis_cons_tx_tdest;
            m_axis_tx_tuser = s_axis_cons_tx_tuser;
            s_axis_cons_tx_tready = m_axis_tx_tready;
        end
    else if (s_axis_dma_tx_tvalid) begin
            m_axis_tx_tdata = s_axis_dma_tx_tdata;
            m_axis_tx_tkeep = s_axis_dma_tx_tkeep;
            m_axis_tx_tvalid = s_axis_dma_tx_tvalid;
            m_axis_tx_tlast = s_axis_dma_tx_tlast;
            m_axis_tx_tid = s_axis_dma_tx_tid;
            m_axis_tx_tdest = s_axis_dma_tx_tdest;
            m_axis_tx_tuser = s_axis_dma_tx_tuser;
            s_axis_dma_tx_tready = m_axis_tx_tready;
    end
end

// pass-through

assign m_axis_tx_cpl_ts = s_axis_tx_cpl_ts;
assign m_axis_tx_cpl_tag = s_axis_tx_cpl_tag;
assign m_axis_tx_cpl_valid = s_axis_tx_cpl_valid;
assign s_axis_tx_cpl_ready = m_axis_tx_cpl_ready;

endmodule
