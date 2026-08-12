`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * SSR dataplane wrapper with a minimal control/status register block.
 *
 * -----------------------------------------------------
 *            Basic Configuration Registers
 * -----------------------------------------------------
 * + BASE_ADDR = 0x0000_0000
 * + ADDR_WIDTH = 24 bits (16KB register space)
 *
 * // Header
 *      - 0x0000 TYPE
 *      - 0x0004 VERSION
 *      - 0x0008 NEXT_PTR
 *      - 0x000c FEATURES

 *  // Control/status
 *      - 0x0010 CONTROL
 *      - 0x0014 STATUS
 *      - 0x0018 ERROR
 *      - 0x001c SCRATCH

 *  // SSR configuration
 *      - 0x0020 REPLICA_ID
 *      - 0x0024 REPLICA_NUM
 *      - 0x0028 ROUND_LEN_NS
 *      - 0x002c ETHERNET_TYPE

 *  // TEST Only Registers
 *      - 0x0040 GEN_COUNT
 *      - 0x0044 GEN_CONTROL
 *          bit 0: start
 *          bit 1: stop
 *          bit 2: clear
 *
 *      - 0x0048 GEN_STATUS
 *          bit 0: busy
 *          bit 1: done
 *
 *      - 0x004c GEN_COUNT_BEAT
 *      - 0x0050 GEN_COUNT_SLOT        

 *  // Replica MAC table
 *  > Each entry is 8 bytes:
 *      - 0x0100 + (i * 8) + 0x0  REPLICA_MAC_LO[i]
 *      - 0x0104 + (i * 8) + 0x4  REPLICA_MAC_HI[i]
 *
 *  > MAC address format:
 *      - REPLICA_MAC_LO[i]    = mac[31:0]
 *      - REPLICA_MAC_HI[i][15:0] = mac[47:32]
 *      - REPLICA_MAC_HI[i][31:16] reserved / future flags
 * 
 * -----------------------------------------------------
 *         DMA Queue Registers
 * -----------------------------------------------------
 *
 * DMA Proposal Queue register block (RBB_PROPOSAL_QUEUE):
 *  - BASE_ADDR = 0x0000_1000
 *  - ADDR_WIDTH = 24 bits (16KB register space)
 *
 * DMA Commit Queue register block (RBB_COMMIT_QUEUE):
 *  - BASE_ADDR = 0x0000_2000
 *  - ADDR_WIDTH = 24 bits (16KB register space)
 *   
 */

module ssr_dataplane #
(
    parameter APP_ID = 0,

    // Register interface configuration
    parameter REG_ADDR_WIDTH    = 24,
    parameter REG_DATA_WIDTH    = 32,
    parameter REG_STRB_WIDTH    = (REG_DATA_WIDTH / 8),
    parameter RB_BASE_ADDR      = 0,
    parameter RB_NEXT_PTR       = 0,

    // SSR configuration parameters
    parameter MAX_REPLICAS  = 7,

    parameter IF_COUNT      = 1,
    parameter PORTS_PER_IF  = 1,
    parameter SCHED_PER_IF  = PORTS_PER_IF, // number of schedulers per interface (must be <= PORTS_PER_IF)
    parameter PORT_COUNT    = IF_COUNT * PORTS_PER_IF,

    // PTP configuration parameters
    parameter PTP_CLK_PERIOD_NS_NUM     = 4,
    parameter PTP_CLK_PERIOD_NS_DENOM   = 1,
    parameter PTP_PORT_CDC_PIPELINE     = 0,
    parameter PTP_PEROUT_ENABLE         = 0,
    parameter PTP_PEROUT_COUNT          = 1,

    // Interface configuration
    parameter PTP_TS_ENABLE     = 1,
    parameter PTP_TS_FMT_TOD    = 1,
    parameter PTP_TS_WIDTH      = PTP_TS_FMT_TOD ? 96 : 64,
    parameter TX_TAG_WIDTH      = 16,
    parameter MAX_TX_SIZE       = 9214,
    parameter MAX_RX_SIZE       = 9214,

    // DMA interface configuration
    parameter DMA_ADDR_WIDTH        = 64,
    parameter DMA_IMM_ENABLE        = 0,
    parameter DMA_IMM_WIDTH         = 32,
    parameter DMA_LEN_WIDTH         = 16,
    parameter DMA_TAG_WIDTH         = 16,
    parameter RAM_SEL_WIDTH         = 4,
    parameter RAM_ADDR_WIDTH        = 16,
    parameter RAM_SEG_COUNT         = 2,
    parameter RAM_SEG_DATA_WIDTH    = 256 * 2/ RAM_SEG_COUNT, // each segment is 256 bits (32 bytes)
    parameter RAM_SEG_BE_WIDTH      = (RAM_SEG_DATA_WIDTH / 8),
    parameter RAM_SEG_ADDR_WIDTH    = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT * RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE          = 2,

    // RAM BUFFER configuration
    parameter RAM_BUFF_SLOT_BYTES = 1024,
    parameter RAM_BUFF_SLOT_COUNT = 64,

    // Ethernet interface configuration (interface)
    parameter AXIS_IF_DATA_WIDTH    = 512,
    parameter AXIS_IF_KEEP_WIDTH    = (AXIS_IF_DATA_WIDTH / 8),
    parameter AXIS_IF_TX_ID_WIDTH   = 12,
    parameter AXIS_IF_RX_ID_WIDTH   = PORTS_PER_IF > 1 ? $clog2(PORTS_PER_IF) : 1,
    parameter AXIS_IF_TX_DEST_WIDTH = $clog2(PORTS_PER_IF) + 4,
    parameter AXIS_IF_RX_DEST_WIDTH = 8,
    parameter AXIS_IF_TX_USER_WIDTH = 1,
    parameter AXIS_IF_RX_USER_WIDTH = 1
)
(
    input  wire                                     clk,
    input  wire                                     rst,

    // Control/status register interface
    input  wire [REG_ADDR_WIDTH-1:0]                reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]                reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]                reg_wr_strb,
    input  wire                                     reg_wr_en,
    output wire                                     reg_wr_wait,
    output wire                                     reg_wr_ack,
    input  wire [REG_ADDR_WIDTH-1:0]                reg_rd_addr,
    input  wire                                     reg_rd_en,
    output wire [REG_DATA_WIDTH-1:0]                reg_rd_data,
    output wire                                     reg_rd_wait,
    output wire                                     reg_rd_ack,

    // DMA interface
    // DMA read descriptor output interface
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_data_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_data_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_data_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_data_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_data_dma_read_desc_tag,
    output wire                                     m_axis_data_dma_read_desc_valid,
    input  wire                                     m_axis_data_dma_read_desc_ready,

    // DMA read descriptor status input interface
    input wire [DMA_TAG_WIDTH-1:0]                  s_axis_data_dma_read_desc_status_tag,
    input wire [3:0]                                s_axis_data_dma_read_desc_status_error,
    input wire                                      s_axis_data_dma_read_desc_status_valid,

    // DMA write descriptor output interface
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_data_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_data_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_data_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                 m_axis_data_dma_write_desc_imm,
    output wire                                     m_axis_data_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_data_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_data_dma_write_desc_tag,
    output wire                                     m_axis_data_dma_write_desc_valid,
    input  wire                                     m_axis_data_dma_write_desc_ready,


    // DMA write descriptor status input interface
    input wire [DMA_TAG_WIDTH-1:0]                  s_axis_data_dma_write_desc_status_tag,
    input wire [3:0]                                s_axis_data_dma_write_desc_status_error,
    input wire                                      s_axis_data_dma_write_desc_status_valid,
    
    // DMA RAM write interface
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]            data_dma_ram_wr_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]         data_dma_ram_wr_cmd_be,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]       data_dma_ram_wr_cmd_addr,
    input wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]       data_dma_ram_wr_cmd_data,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_wr_done,
    
    // DMA RAM read interface
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]            data_dma_ram_rd_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]       data_dma_ram_rd_cmd_addr,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      data_dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_rd_resp_valid,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_rd_resp_ready,

    // PTP clock and timestamping interface
    input wire                                          ptp_clk,
    input wire                                          ptp_rst,
    input wire                                          ptp_sample_clk,
    input wire                                          ptp_td_sd,
    input wire                                          ptp_pps,
    input wire                                          ptp_pps_str,
    input wire                                          ptp_sync_locked,
    input wire [PTP_TS_WIDTH-1:0]                       ptp_sync_ts_rel,
    input wire                                          ptp_sync_ts_rel_step,
    input wire [PTP_TS_WIDTH-1:0]                       ptp_sync_ts_tod,
    input wire                                          ptp_sync_ts_tod_step,
    input wire                                          ptp_sync_pps,
    input wire                                          ptp_sync_pps_str,
    input wire [PTP_PEROUT_COUNT-1:0]                   ptp_perout_locked,
    input wire [PTP_PEROUT_COUNT-1:0]                   ptp_perout_error,
    input wire [PTP_PEROUT_COUNT-1:0]                   ptp_perout_pulse,

    // Ethernet interface
    // Ethernet (internal at interface module)
    // TX interface (from DMA to MAC)
    input  wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           s_axis_if_tx_tdata,
    input  wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           s_axis_if_tx_tkeep,
    input  wire [IF_COUNT-1:0]                              s_axis_if_tx_tvalid,
    output wire [IF_COUNT-1:0]                              s_axis_if_tx_tready,
    input  wire [IF_COUNT-1:0]                              s_axis_if_tx_tlast,
    input  wire [IF_COUNT*AXIS_IF_TX_ID_WIDTH-1:0]          s_axis_if_tx_tid,
    input  wire [IF_COUNT*AXIS_IF_TX_DEST_WIDTH-1:0]        s_axis_if_tx_tdest,
    input  wire [IF_COUNT*AXIS_IF_TX_USER_WIDTH-1:0]        s_axis_if_tx_tuser,

    // TX interface (from MAC to DMA)
    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           m_axis_if_tx_tdata,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           m_axis_if_tx_tkeep,
    output wire [IF_COUNT-1:0]                              m_axis_if_tx_tvalid,
    input  wire [IF_COUNT-1:0]                              m_axis_if_tx_tready,
    output wire [IF_COUNT-1:0]                              m_axis_if_tx_tlast,
    output wire [IF_COUNT*AXIS_IF_TX_ID_WIDTH-1:0]          m_axis_if_tx_tid,
    output wire [IF_COUNT*AXIS_IF_TX_DEST_WIDTH-1:0]        m_axis_if_tx_tdest,
    output wire [IF_COUNT*AXIS_IF_TX_USER_WIDTH-1:0]        m_axis_if_tx_tuser,

    // TX CPL from MAC
    input  wire [IF_COUNT*PTP_TS_WIDTH-1:0]                 s_axis_if_tx_cpl_ts,
    input  wire [IF_COUNT*TX_TAG_WIDTH-1:0]                 s_axis_if_tx_cpl_tag,
    input  wire [IF_COUNT-1:0]                              s_axis_if_tx_cpl_valid,
    output wire [IF_COUNT-1:0]                              s_axis_if_tx_cpl_ready,

    // TX CPL to DMA
    output wire [IF_COUNT*PTP_TS_WIDTH-1:0]                 m_axis_if_tx_cpl_ts,
    output wire [IF_COUNT*TX_TAG_WIDTH-1:0]                 m_axis_if_tx_cpl_tag,
    output wire [IF_COUNT-1:0]                              m_axis_if_tx_cpl_valid,
    input  wire [IF_COUNT-1:0]                              m_axis_if_tx_cpl_ready,

    // RX interface (from MAC to DMA)
    input  wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           s_axis_if_rx_tdata,
    input  wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           s_axis_if_rx_tkeep,
    input  wire [IF_COUNT-1:0]                              s_axis_if_rx_tvalid,
    output wire [IF_COUNT-1:0]                              s_axis_if_rx_tready,
    input  wire [IF_COUNT-1:0]                              s_axis_if_rx_tlast,
    input  wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]          s_axis_if_rx_tid,
    input  wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]        s_axis_if_rx_tdest,
    input  wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]        s_axis_if_rx_tuser,

    // RX interface (from DMA to MAC)
    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           m_axis_if_rx_tdata,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           m_axis_if_rx_tkeep,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tvalid,
    input  wire [IF_COUNT-1:0]                              m_axis_if_rx_tready,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tlast,
    output wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]          m_axis_if_rx_tid,
    output wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]        m_axis_if_rx_tdest,
    output wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]        m_axis_if_rx_tuser
);

localparam SSR_RB_TYPE                              = 32'h53535201; // "SSR" + version 1
localparam SSR_RB_VERSION                           = 32'h00000100; // version 1.0.0
localparam [REG_ADDR_WIDTH-1:0] RBB_COMMON          = 24'h000000; // base address of basic register block
localparam [REG_ADDR_WIDTH-1:0] RBB_PROPOSAL_QUEUE  = 24'h001000; // base address of proposal datapath
localparam [REG_ADDR_WIDTH-1:0] RBB_COMMIT_QUEUE    = 24'h002000; // base address of commit datapath

localparam RAM_SEL_PROP = 0; // RAM selector for proposal buffer read operations
localparam DMA_TAG_PROP = 0; // DMA tag for proposal buffer read operations
localparam RAM_SEL_COMMIT = 1; // RAM selector for commit buffer write operations
localparam DMA_TAG_COMMIT = 0;

// check configuration parameters
initial begin
    if (REG_DATA_WIDTH != 32) begin
        $error("Error: Register interface data width must be 32 bits");
        $finish;
    end

    if (REG_STRB_WIDTH != (REG_DATA_WIDTH / 8)) begin
        $error("Error: Register interface strobe width must be data width / 8");
        $finish;
    end

    if (REG_ADDR_WIDTH < 12) begin
        $error("Error: Register interface address width must be at least 12 bits");
        $finish;
    end
end

// ==============================================================
//                 Basic Control/Status Register Block
// ==============================================================
localparam REG_TYPE             = RBB_COMMON + 24'h000000;
localparam REG_VERSION          = RBB_COMMON + 24'h000004;
localparam REG_NEXT_PTR         = RBB_COMMON + 24'h000008;
localparam REG_FEATURES         = RBB_COMMON + 24'h00000c;
localparam REG_CONTROL          = RBB_COMMON + 24'h000010;
localparam REG_STATUS           = RBB_COMMON + 24'h000014;
localparam REG_ERROR            = RBB_COMMON + 24'h000018;
localparam REG_SCRATCH          = RBB_COMMON + 24'h00001c;
localparam REG_REPLICA_ID       = RBB_COMMON + 24'h000020;
localparam REG_REPLICA_NUM      = RBB_COMMON + 24'h000024;
localparam REG_ROUND_LEN_NS     = RBB_COMMON + 24'h000028;
localparam REG_ETHERNET_TYPE    = RBB_COMMON + 24'h00002c;

localparam REG_REPLICA_MAC0_LO   = RBB_COMMON + 24'h000100; 
localparam REG_REPLICA_MAC0_HI   = RBB_COMMON + 24'h000104; 
localparam REG_REPLICA_MAC1_LO   = RBB_COMMON + 24'h000108; 
localparam REG_REPLICA_MAC1_HI   = RBB_COMMON + 24'h00010c; 
localparam REG_REPLICA_MAC2_LO   = RBB_COMMON + 24'h000110; 
localparam REG_REPLICA_MAC2_HI   = RBB_COMMON + 24'h000114; 
localparam REG_REPLICA_MAC3_LO   = RBB_COMMON + 24'h000118; 
localparam REG_REPLICA_MAC3_HI   = RBB_COMMON + 24'h00011c; 
localparam REG_REPLICA_MAC4_LO   = RBB_COMMON + 24'h000120; 
localparam REG_REPLICA_MAC4_HI   = RBB_COMMON + 24'h000124; 
localparam REG_REPLICA_MAC5_LO   = RBB_COMMON + 24'h000128; 
localparam REG_REPLICA_MAC5_HI   = RBB_COMMON + 24'h00012c; 
localparam REG_REPLICA_MAC6_LO   = RBB_COMMON + 24'h000130; 
localparam REG_REPLICA_MAC6_HI   = RBB_COMMON + 24'h000134; 

localparam REG_PROPOSAL_SINK_CONTROL        = RBB_COMMON + 24'h000200;
localparam REG_PROPOSAL_SINK_SLOT_COUNT     = RBB_COMMON + 24'h000204;
localparam REG_PROPOSAL_SINK_BEAT_COUNT     = RBB_COMMON + 24'h000208;
localparam REG_PROPOSAL_SINK_ERROR_COUNT    = RBB_COMMON + 24'h00020c;

localparam REG_COMMIT_GEN_COUNT        = RBB_COMMON + 24'h000210;
localparam REG_COMMIT_GEN_CONTROL      = RBB_COMMON + 24'h000214;
localparam REG_COMMIT_GEN_STATUS       = RBB_COMMON + 24'h000218;
localparam REG_COMMIT_GEN_GENERATED_SLOT_COUNT   = RBB_COMMON + 24'h00021c;
localparam REG_COMMIT_GEN_GENERATED_BEAT_COUNT   = RBB_COMMON + 24'h000220;

// control registers for common register block
reg                         reg_wr_ack_common_reg  = 1'b0, reg_wr_ack_common_next;
reg                         reg_rd_ack_common_reg  = 1'b0, reg_rd_ack_common_next;
reg [REG_DATA_WIDTH-1:0]    reg_rd_data_common_reg = 0, reg_rd_data_common_next;

// register select signals
wire reg_wr_en_common           = reg_wr_en && reg_wr_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMON[REG_ADDR_WIDTH-1:12];
wire reg_wr_en_proposal_queue   = reg_wr_en && reg_wr_addr[REG_ADDR_WIDTH-1:12] == RBB_PROPOSAL_QUEUE[REG_ADDR_WIDTH-1:12];
wire reg_wr_en_commit_queue     = reg_wr_en && reg_wr_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMIT_QUEUE[REG_ADDR_WIDTH-1:12];
wire reg_wr_ack_common, reg_wr_ack_proposal_queue, reg_wr_ack_commit_queue;

wire reg_rd_en_common           = reg_rd_en && reg_rd_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMON[REG_ADDR_WIDTH-1:12];
wire reg_rd_en_proposal_queue   = reg_rd_en && reg_rd_addr[REG_ADDR_WIDTH-1:12] == RBB_PROPOSAL_QUEUE[REG_ADDR_WIDTH-1:12];
wire reg_rd_en_commit_queue     = reg_rd_en && reg_rd_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMIT_QUEUE[REG_ADDR_WIDTH-1:12];
wire [REG_DATA_WIDTH-1:0]   reg_rd_data_common, reg_rd_data_proposal_queue, reg_rd_data_commit_queue;
wire                        reg_rd_ack_common, reg_rd_ack_proposal_queue, reg_rd_ack_commit_queue;

// common assignments
assign reg_wr_ack_common = reg_wr_ack_common_reg;
assign reg_rd_ack_common = reg_rd_ack_common_reg;
assign reg_rd_data_common = reg_rd_data_common_reg;

// selecting which block's acknowledge and data signals to return based on the accessed address
assign reg_wr_wait  = 0; // this module can always accept write commands (no wait states)
assign reg_rd_wait  = 0; // this module can always accept read commands (no wait states)
assign reg_wr_ack   = reg_wr_ack_common || reg_wr_ack_proposal_queue || reg_wr_ack_commit_queue; // acknowledge if any of the blocks acknowledges
assign reg_rd_ack   = reg_rd_ack_common || reg_rd_ack_proposal_queue || reg_rd_ack_commit_queue; // acknowledge if any of the blocks acknowledges
assign reg_rd_data  = reg_rd_ack_common ? reg_rd_data_common : 
                    reg_rd_ack_proposal_queue ? reg_rd_data_proposal_queue : 
                    reg_rd_ack_commit_queue ? reg_rd_data_commit_queue : {REG_DATA_WIDTH{1'b0}}; // return data from the appropriate block based on which one acknowledges

// control/status registers
reg [31:0] control_reg, control_reg_next;
//reg [31:0] status_reg, status_reg_next;
reg [31:0] error_reg, error_reg_next;
reg [31:0] scratch_reg, scratch_reg_next;

// SSR configuration registers
reg [31:0] replica_id_reg, replica_id_reg_next;
reg [31:0] replica_num_reg, replica_num_reg_next;
reg [31:0] round_length_ns_reg, round_length_ns_reg_next;
reg [31:0] ethernet_type_reg, ethernet_type_reg_next;

// replica MAC table (up to MAX_REPLICAS entries)
reg [31:0] replica_mac_lo [0:MAX_REPLICAS-1], replica_mac_lo_next [0:MAX_REPLICAS-1];
reg [31:0] replica_mac_hi [0:MAX_REPLICAS-1], replica_mac_hi_next [0:MAX_REPLICAS-1];

wire config_valid = replica_num_reg != 0 &&
                    replica_num_reg <= MAX_REPLICAS &&
                    round_length_ns_reg != 0 &&
                    replica_id_reg < replica_num_reg;

// Test proposal sink control
reg proposal_sink_enable_reg = 1'b0, proposal_sink_enable_next = 1'b0;
reg proposal_sink_clear_reg = 1'b0, proposal_sink_clear_next = 1'b0;

// Test proposal sink status
wire [31:0] proposal_sink_slot_count;
wire [31:0] proposal_sink_beat_count;
wire [31:0] proposal_sink_error_count;

// Test commit generator control
reg commit_gen_start_reg = 1'b0, commit_gen_start_next = 1'b0;
reg commit_gen_stop_reg = 1'b0, commit_gen_stop_next = 1'b0;
reg commit_gen_clear_reg = 1'b0, commit_gen_clear_next = 1'b0;

// Test commit generator status
reg [31:0] commit_gen_count_reg = 32'd0, commit_gen_count_next = 32'd0;

// Test commit generator status outputs
wire commit_gen_busy;
wire commit_gen_done;
wire [31:0] commit_gen_generated_count;
wire [31:0] commit_gen_generated_beat_count;

// --------------------------------------------------------
//      Combinatorial Logic: BASIC CONTROL/STATUS REGISTER
// --------------------------------------------------------
integer i; // loop variable for updating replica MAC table entries

always @* begin
    // default outputs
    reg_wr_ack_common_next     = 1'b0; 
    reg_rd_ack_common_next     = 1'b0;
    reg_rd_data_common_next    = 0;

    // default next state is to hold current values
    control_reg_next    = control_reg;
    error_reg_next      = error_reg;
    scratch_reg_next    = scratch_reg;

    replica_id_reg_next         = replica_id_reg;
    replica_num_reg_next        = replica_num_reg;
    round_length_ns_reg_next    = round_length_ns_reg;
    ethernet_type_reg_next      = ethernet_type_reg;

    proposal_sink_enable_next = proposal_sink_enable_reg;
    proposal_sink_clear_next = proposal_sink_clear_reg;

    commit_gen_start_next = 0;
    commit_gen_stop_next = 0;
    commit_gen_clear_next = 0;

    for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
        replica_mac_lo_next[i] = replica_mac_lo[i];
        replica_mac_hi_next[i] = replica_mac_hi[i];
    end

    if (reg_wr_en_common && !reg_wr_ack_common_reg) begin
        // write operation - decode address and update registers
        reg_wr_ack_common_next = 1'b1; // acknowledge the write
        case ({reg_wr_addr[REG_ADDR_WIDTH-1:2], 2'b00}) // align address to 4 bytes
            REG_TYPE: ; // TYPE is read-only
            REG_VERSION: ; // VERSION is read-only
            REG_NEXT_PTR: ; // NEXT_PTR is read-only
            REG_FEATURES: ; // FEATURES is read-only

            REG_CONTROL: control_reg_next  = reg_wr_data; // CONTROL
            REG_STATUS: ; // STATUS is read-only
            REG_ERROR: error_reg_next    = error_reg & ~reg_wr_data; // ERROR (write 1 to clear)
            REG_SCRATCH: scratch_reg_next  = reg_wr_data; // SCRATCH

            REG_REPLICA_ID: replica_id_reg_next   = reg_wr_data; // REPLICA_ID
            REG_REPLICA_NUM: replica_num_reg_next  = reg_wr_data; // REPLICA_NUM
            REG_ROUND_LEN_NS: round_length_ns_reg_next  = reg_wr_data; // ROUND_LENGTH_NS
            REG_ETHERNET_TYPE: ethernet_type_reg_next    = reg_wr_data; // ETHERNET_TYPE

            // replica MAC table entries
            REG_REPLICA_MAC0_LO: replica_mac_lo_next[0] = reg_wr_data;
            REG_REPLICA_MAC0_HI: replica_mac_hi_next[0] = reg_wr_data;
            REG_REPLICA_MAC1_LO: replica_mac_lo_next[1] = reg_wr_data;
            REG_REPLICA_MAC1_HI: replica_mac_hi_next[1] = reg_wr_data;
            REG_REPLICA_MAC2_LO: replica_mac_lo_next[2] = reg_wr_data;
            REG_REPLICA_MAC2_HI: replica_mac_hi_next[2] = reg_wr_data;
            REG_REPLICA_MAC3_LO: replica_mac_lo_next[3] = reg_wr_data;
            REG_REPLICA_MAC3_HI: replica_mac_hi_next[3] = reg_wr_data;
            REG_REPLICA_MAC4_LO: replica_mac_lo_next[4] = reg_wr_data;
            REG_REPLICA_MAC4_HI: replica_mac_hi_next[4] = reg_wr_data;
            REG_REPLICA_MAC5_LO: replica_mac_lo_next[5] = reg_wr_data;
            REG_REPLICA_MAC5_HI: replica_mac_hi_next[5] = reg_wr_data;
            REG_REPLICA_MAC6_LO: replica_mac_lo_next[6] = reg_wr_data;
            REG_REPLICA_MAC6_HI: replica_mac_hi_next[6] = reg_wr_data;

            // test registers for proposal sinker
            REG_PROPOSAL_SINK_CONTROL: begin
                proposal_sink_enable_next = reg_wr_data[0]; // SINK_CONTROL bit 0: enable
                proposal_sink_clear_next = reg_wr_data[1]; // SINK_CONTROL bit 1: clear
            end

            // test registers for commit generator
            REG_COMMIT_GEN_COUNT: commit_gen_count_next = reg_wr_data; // GEN_COUNT
            REG_COMMIT_GEN_CONTROL: begin
                commit_gen_start_next = reg_wr_data[0]; // GEN_CONTROL bit 0: start
                commit_gen_stop_next = reg_wr_data[1]; // GEN_CONTROL bit 1: stop
                commit_gen_clear_next = reg_wr_data[2]; // GEN_CONTROL bit 2: clear
            end

            default: reg_wr_ack_common_next = 1'b0; // invalid address, do not acknowledge
        endcase
    end

    if (reg_rd_en_common && !reg_rd_ack_common_reg) begin
        // read operation - decode address and return data
        reg_rd_ack_common_next = 1'b1; // acknowledge the read
        case ({reg_rd_addr[REG_ADDR_WIDTH-1:2], 2'b00}) // align address to 4 bytes
            REG_TYPE: reg_rd_data_common_next = SSR_RB_TYPE; 
            REG_VERSION: reg_rd_data_common_next = SSR_RB_VERSION;
            REG_FEATURES: reg_rd_data_common_next = 32'hf;
            REG_CONTROL: reg_rd_data_common_next = control_reg; 
            REG_STATUS: begin
               reg_rd_data_common_next[0] = config_valid; 
               reg_rd_data_common_next[1] = control_reg[0];
               reg_rd_data_common_next[2] = control_reg[1];
            end
            REG_ERROR: reg_rd_data_common_next = error_reg;
            REG_SCRATCH: reg_rd_data_common_next = scratch_reg;

            REG_REPLICA_ID: reg_rd_data_common_next = replica_id_reg;
            REG_REPLICA_NUM: reg_rd_data_common_next = replica_num_reg;
            REG_ROUND_LEN_NS: reg_rd_data_common_next = round_length_ns_reg;
            REG_ETHERNET_TYPE: reg_rd_data_common_next = ethernet_type_reg;

            // replica MAC table entries
            REG_REPLICA_MAC0_LO: reg_rd_data_common_next = replica_mac_lo[0]; 
            REG_REPLICA_MAC0_HI: reg_rd_data_common_next = replica_mac_hi[0]; 
            REG_REPLICA_MAC1_LO: reg_rd_data_common_next = replica_mac_lo[1]; 
            REG_REPLICA_MAC1_HI: reg_rd_data_common_next = replica_mac_hi[1]; 
            REG_REPLICA_MAC2_LO: reg_rd_data_common_next = replica_mac_lo[2]; 
            REG_REPLICA_MAC2_HI: reg_rd_data_common_next = replica_mac_hi[2]; 
            REG_REPLICA_MAC3_LO: reg_rd_data_common_next = replica_mac_lo[3]; 
            REG_REPLICA_MAC3_HI: reg_rd_data_common_next = replica_mac_hi[3]; 
            REG_REPLICA_MAC4_LO: reg_rd_data_common_next = replica_mac_lo[4]; 
            REG_REPLICA_MAC4_HI: reg_rd_data_common_next = replica_mac_hi[4]; 
            REG_REPLICA_MAC5_LO: reg_rd_data_common_next = replica_mac_lo[5]; 
            REG_REPLICA_MAC5_HI: reg_rd_data_common_next = replica_mac_hi[5]; 
            REG_REPLICA_MAC6_LO: reg_rd_data_common_next = replica_mac_lo[6]; 
            REG_REPLICA_MAC6_HI: reg_rd_data_common_next = replica_mac_hi[6]; 

            // test registers for proposal sinker
            REG_PROPOSAL_SINK_CONTROL: begin
                reg_rd_data_common_next[0] = proposal_sink_enable_reg; // bit 0: enable
                reg_rd_data_common_next[1] = proposal_sink_clear_reg; // bit 1: clear
            end
            REG_PROPOSAL_SINK_SLOT_COUNT: reg_rd_data_common_next = proposal_sink_slot_count; // SINK_SLOT_COUNT
            REG_PROPOSAL_SINK_BEAT_COUNT: reg_rd_data_common_next = proposal_sink_beat_count; // SINK_BEAT_COUNT
            REG_PROPOSAL_SINK_ERROR_COUNT: reg_rd_data_common_next = proposal_sink_error_count; // SINK_ERROR_COUNT

            // test registers for commit generator
            REG_COMMIT_GEN_COUNT: reg_rd_data_common_next = commit_gen_count_reg; // GEN_COUNT
            REG_COMMIT_GEN_CONTROL: begin
                reg_rd_data_common_next[0] = commit_gen_busy; // bit 0: busy
                reg_rd_data_common_next[1] = commit_gen_done; // bit 1: done
            end
            REG_COMMIT_GEN_GENERATED_SLOT_COUNT: reg_rd_data_common_next = commit_gen_generated_count; // GEN_COUNT
            REG_COMMIT_GEN_GENERATED_BEAT_COUNT: reg_rd_data_common_next = commit_gen_generated_beat_count; // GEN_BEAT_COUNT

            default: begin
                reg_rd_data_common_next = 0; // invalid address, return 0
                reg_rd_ack_common_next = 1'b0; // do not acknowledge
            end
        endcase
    end
end

// --------------------------------------------------------------
//         Sequential logic: BASIC CONTROL/STATUS REGISTER
// --------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        reg_wr_ack_common_reg  <= 1'b0;
        reg_rd_data_common_reg <= 0;
        reg_rd_ack_common_reg  <= 1'b0;

        control_reg     <= 0;
        //status_reg <= 0;
        error_reg       <= 0;
        scratch_reg     <= 0;
        replica_id_reg  <= 0;
        replica_num_reg <= 0;
        round_length_ns_reg <= 0;
        ethernet_type_reg   <= 0;

        for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
            replica_mac_lo[i] <= 0;
            replica_mac_hi[i] <= 0;
        end

        proposal_sink_enable_reg <= 1'b0;
        proposal_sink_clear_reg <= 1'b0;

        commit_gen_start_reg <= 1'b0;
        commit_gen_stop_reg <= 1'b0;
        commit_gen_clear_reg <= 1'b0;
        commit_gen_count_reg <= 32'd0;

    end else begin
        reg_wr_ack_common_reg  <= reg_wr_ack_common_next;
        reg_rd_data_common_reg <= reg_rd_data_common_next;
        reg_rd_ack_common_reg  <= reg_rd_ack_common_next;

        control_reg     <= control_reg_next;
        //status_reg <= status_reg_next;
        error_reg       <= error_reg_next;
        scratch_reg     <= scratch_reg_next;
        replica_id_reg  <= replica_id_reg_next;
        replica_num_reg <= replica_num_reg_next;
        round_length_ns_reg <= round_length_ns_reg_next;
        ethernet_type_reg   <= ethernet_type_reg_next;

        for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
            replica_mac_lo[i] <= replica_mac_lo_next[i];
            replica_mac_hi[i] <= replica_mac_hi_next[i];
        end

        proposal_sink_enable_reg <= proposal_sink_enable_next;
        proposal_sink_clear_reg <= proposal_sink_clear_next;

        commit_gen_start_reg <= commit_gen_start_next;
        commit_gen_stop_reg <= commit_gen_stop_next;
        commit_gen_clear_reg <= commit_gen_clear_next;
        commit_gen_count_reg <= commit_gen_count_next;
    end
end

// ==============================================================
//                      SSR CORE LOGIC
// ==============================================================



// ==============================================================
//                          TX datapath
// ==============================================================
wire                            proposal_tail_slot_valid;
wire [RAM_ADDR_WIDTH-1:0]       proposal_tail_slot_addr;
wire [DMA_LEN_WIDTH-1:0]        proposal_tail_slot_len;

wire proposal_tail_commit_valid;
wire proposal_tail_commit_ready;

// proposal -> tx_engine/sink
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]     proposal_buf_rd_data;
wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]       proposal_buf_rd_be;
wire                                            proposal_buf_rd_valid;
wire                                            proposal_buf_rd_ready;
wire                                            proposal_buf_tx_last;
wire [DMA_LEN_WIDTH-1:0]                        proposal_buf_tx_len;

// ------------------------------------------------
//      instance of proposal DMA reader
// ------------------------------------------------
proposal_dma_reader #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .RB_BASE_ADDR(RBB_PROPOSAL_QUEUE),

    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),

    .RAM_SEL_PROP(RAM_SEL_PROP),
    .DMA_TAG_PROP(DMA_TAG_PROP),
    .PROPOSAL_SLOT_BYTES(RAM_BUFF_SLOT_BYTES)
)
proposal_dma_reader_inst (
    .clk(clk),
    .rst(rst),

    // CSR interface
    .reg_wr_en(reg_wr_en_proposal_queue),
    .reg_wr_addr(reg_wr_addr),
    .reg_wr_data(reg_wr_data),
    .reg_wr_strb(reg_wr_strb),
    .reg_wr_wait(),
    .reg_wr_ack(reg_wr_ack_proposal_queue),

    .reg_rd_en(reg_rd_en_proposal_queue),
    .reg_rd_addr(reg_rd_addr),
    .reg_rd_data(reg_rd_data_proposal_queue),
    .reg_rd_wait(),
    .reg_rd_ack(reg_rd_ack_proposal_queue),

    // DMA read descriptor output interface
    .m_axis_dma_read_desc_dma_addr(m_axis_data_dma_read_desc_dma_addr),
    .m_axis_dma_read_desc_ram_sel(m_axis_data_dma_read_desc_ram_sel),
    .m_axis_dma_read_desc_ram_addr(m_axis_data_dma_read_desc_ram_addr),
    .m_axis_dma_read_desc_len(m_axis_data_dma_read_desc_len),
    .m_axis_dma_read_desc_tag(m_axis_data_dma_read_desc_tag),
    .m_axis_dma_read_desc_valid(m_axis_data_dma_read_desc_valid),
    .m_axis_dma_read_desc_ready(m_axis_data_dma_read_desc_ready),

    // DMA read descriptor status input interface
    .s_axis_dma_read_desc_status_tag(s_axis_data_dma_read_desc_status_tag),
    .s_axis_dma_read_desc_status_error(s_axis_data_dma_read_desc_status_error),
    .s_axis_dma_read_desc_status_valid(s_axis_data_dma_read_desc_status_valid),

    // proposal tail slot interface
    .tail_slot_valid(proposal_tail_slot_valid),
    .tail_slot_addr(proposal_tail_slot_addr),
    .tail_slot_len(proposal_tail_slot_len),

    // proposal tail commit interface
    .commit_valid(proposal_tail_commit_valid),
    .commit_ready(proposal_tail_commit_ready)
);


// -------------------------------------------------
//     instance of proposal buffer
// -------------------------------------------------
proposal_buffer #(
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_SEL_PROP(RAM_SEL_PROP),

    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE),

    .PROPOSAL_SLOT_BYTES(RAM_BUFF_SLOT_BYTES),
    .PROPOSAL_SLOT_COUNT(RAM_BUFF_SLOT_COUNT)
)
proposal_buffer_inst (
    .clk(clk),
    .rst(rst),

    // Direct DMA RAM write endpoint
    .dma_ram_wr_cmd_sel(data_dma_ram_wr_cmd_sel),
    .dma_ram_wr_cmd_be(data_dma_ram_wr_cmd_be),
    .dma_ram_wr_cmd_addr(data_dma_ram_wr_cmd_addr),
    .dma_ram_wr_cmd_data(data_dma_ram_wr_cmd_data),
    .dma_ram_wr_cmd_valid(data_dma_ram_wr_cmd_valid),
    .dma_ram_wr_cmd_ready(data_dma_ram_wr_cmd_ready),
    .dma_ram_wr_done(data_dma_ram_wr_done),

    // Writable tail slot
    .tail_slot_valid(proposal_tail_slot_valid),
    .tail_slot_addr(proposal_tail_slot_addr),
    .tail_slot_len(proposal_tail_slot_len),

    // Commit completed slot
    .tail_commit_valid(proposal_tail_commit_valid),
    .tail_commit_ready(proposal_tail_commit_ready),

    // Stream to tx_engine/sink
    .buf_rd_data(proposal_buf_rd_data),
    .buf_rd_be(proposal_buf_rd_be),
    .buf_rd_valid(proposal_buf_rd_valid),
    .buf_rd_ready(proposal_buf_rd_ready),
    .buf_tx_last(proposal_buf_tx_last),
    .buf_tx_len(proposal_buf_tx_len)
);

// -------------------------------------------------
//     instance of proposal buffer sink
// -------------------------------------------------
proposal_buffer_sink #(
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),

    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),

    .PROPOSAL_SLOT_BYTES(RAM_BUFF_SLOT_BYTES)
)
proposal_buffer_sink_inst (
    .clk(clk),
    .rst(rst),

    // read interface from proposal buffer
    .buf_rd_data(proposal_buf_rd_data),
    .buf_rd_be(proposal_buf_rd_be),
    .buf_rd_valid(proposal_buf_rd_valid),
    .buf_rd_ready(proposal_buf_rd_ready),
    .buf_tx_last(proposal_buf_tx_last),

    // Control/status outputs
    .sink_enable(proposal_sink_enable_reg),
    .sink_clear(proposal_sink_clear_reg),

    .sink_slot_count(proposal_sink_slot_count),
    .sink_beat_count(proposal_sink_beat_count),
    .sink_error_count(proposal_sink_error_count)
);

// ==============================================================
//                          RX datapath
// ==============================================================
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]     commit_in_data;
wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]       commit_in_be;
wire                                            commit_in_valid;
wire                                            commit_in_ready;
wire                                            commit_in_last;

wire                                            commit_head_slot_valid;
wire [RAM_ADDR_WIDTH-1:0]                       commit_head_slot_addr;
wire [DMA_LEN_WIDTH-1:0]                        commit_head_slot_len;

wire                                            commit_head_slot_pop_valid;
wire                                            commit_head_slot_pop_ready;

wire [31:0]                                      commit_buffer_error_count;

// -------------------------------------------------
//     instance of commit generator
// -------------------------------------------------
commit_generator #(
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .COMMIT_SLOT_BYTES(RAM_BUFF_SLOT_BYTES)
)
commit_generator_inst (
    .clk(clk),
    .rst(rst),

    .start(commit_gen_start_reg),
    .stop(commit_gen_stop_reg),
    .clear(commit_gen_clear_reg),
    .commit_count(commit_gen_count_reg),

    .busy(commit_gen_busy),
    .done(commit_gen_done),
    .generated_count(commit_gen_generated_count),
    .generated_beat_count(commit_gen_generated_beat_count),

    .commit_in_data(commit_in_data),
    .commit_in_be(commit_in_be),
    .commit_in_valid(commit_in_valid),
    .commit_in_ready(commit_in_ready),
    .commit_in_last(commit_in_last)
);

// -------------------------------------------------
//     instance of commit buffer
// -------------------------------------------------
commit_buffer #(
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_SEL_COMMIT(RAM_SEL_COMMIT),
    
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE),

    .COMMIT_SLOT_BYTES(RAM_BUFF_SLOT_BYTES),
    .COMMIT_SLOT_COUNT(RAM_BUFF_SLOT_COUNT)
)
commit_buffer_inst (
    .clk(clk),
    .rst(rst),

    // write interface from commit generator
    .commit_in_data(commit_in_data),
    .commit_in_be(commit_in_be),
    .commit_in_valid(commit_in_valid),
    .commit_in_ready(commit_in_ready),
    .commit_in_last(commit_in_last),

    // commit head slot interface
    .head_slot_valid(commit_head_slot_valid),
    .head_slot_addr(commit_head_slot_addr),
    .head_slot_len(commit_head_slot_len),

    // commit head slot pop interface
    .head_slot_pop_valid(commit_head_slot_pop_valid),
    .head_slot_pop_ready(commit_head_slot_pop_ready),

    // control/status outputs
    .commit_error_count(commit_buffer_error_count),

    .dma_ram_rd_cmd_sel(data_dma_ram_rd_cmd_sel),
    .dma_ram_rd_cmd_addr(data_dma_ram_rd_cmd_addr),
    .dma_ram_rd_cmd_valid(data_dma_ram_rd_cmd_valid),
    .dma_ram_rd_cmd_ready(data_dma_ram_rd_cmd_ready),

    .dma_ram_rd_resp_data(data_dma_ram_rd_resp_data),
    .dma_ram_rd_resp_valid(data_dma_ram_rd_resp_valid),
    .dma_ram_rd_resp_ready(data_dma_ram_rd_resp_ready)
);

// -------------------------------------------------
//     instance of commit DMA writer
// -------------------------------------------------
commit_dma_writer #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .REG_STRB_WIDTH(REG_STRB_WIDTH),
    .RB_BASE_ADDR(RBB_COMMIT_QUEUE),

    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_IMM_ENABLE(DMA_IMM_ENABLE),
    .DMA_IMM_WIDTH(DMA_IMM_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH)
)
commit_dma_writer_inst (
    .clk(clk),
    .rst(rst),

    .reg_wr_addr(reg_wr_addr),
    .reg_wr_data(reg_wr_data),
    .reg_wr_strb(reg_wr_strb),
    .reg_wr_en(reg_wr_en_commit_queue),
    .reg_wr_wait(),
    .reg_wr_ack(reg_wr_ack_commit_queue),

    .reg_rd_addr(reg_rd_addr),
    .reg_rd_en(reg_rd_en_commit_queue),
    .reg_rd_data(reg_rd_data_commit_queue),
    .reg_rd_wait(),
    .reg_rd_ack(reg_rd_ack_commit_queue),

    .m_axis_dma_write_desc_dma_addr(m_axis_data_dma_write_desc_dma_addr),
    .m_axis_dma_write_desc_ram_sel(m_axis_data_dma_write_desc_ram_sel),
    .m_axis_dma_write_desc_ram_addr(m_axis_data_dma_write_desc_ram_addr),
    .m_axis_dma_write_desc_imm(m_axis_data_dma_write_desc_imm),
    .m_axis_dma_write_desc_imm_en(m_axis_data_dma_write_desc_imm_en),
    .m_axis_dma_write_desc_len(m_axis_data_dma_write_desc_len),
    .m_axis_dma_write_desc_tag(m_axis_data_dma_write_desc_tag),
    .m_axis_dma_write_desc_valid(m_axis_data_dma_write_desc_valid),
    .m_axis_dma_write_desc_ready(m_axis_data_dma_write_desc_ready),

    .s_axis_dma_write_desc_status_tag(s_axis_data_dma_write_desc_status_tag),
    .s_axis_dma_write_desc_status_error(s_axis_data_dma_write_desc_status_error),
    .s_axis_dma_write_desc_status_valid(s_axis_data_dma_write_desc_status_valid),

    .head_slot_valid(commit_head_slot_valid),
    .head_slot_addr(commit_head_slot_addr),
    .head_slot_len(commit_head_slot_len),

    .head_slot_pop_valid(commit_head_slot_pop_valid),
    .head_slot_pop_ready(commit_head_slot_pop_ready)
);

// ==================================================================
//                 Ethernet interface modules
// ==================================================================
// direct through 
assign m_axis_if_tx_tdata = s_axis_if_tx_tdata;
assign m_axis_if_tx_tkeep = s_axis_if_tx_tkeep;
assign m_axis_if_tx_tvalid = s_axis_if_tx_tvalid;
assign s_axis_if_tx_tready = m_axis_if_tx_tready;
assign m_axis_if_tx_tlast = s_axis_if_tx_tlast;
assign m_axis_if_tx_tid = s_axis_if_tx_tid;
assign m_axis_if_tx_tdest = s_axis_if_tx_tdest;
assign m_axis_if_tx_tuser = s_axis_if_tx_tuser;

assign m_axis_if_tx_cpl_ts = s_axis_if_tx_cpl_ts;
assign m_axis_if_tx_cpl_tag = s_axis_if_tx_cpl_tag;
assign m_axis_if_tx_cpl_valid = s_axis_if_tx_cpl_valid;
assign s_axis_if_tx_cpl_ready = m_axis_if_tx_cpl_ready;

assign m_axis_if_rx_tdata = s_axis_if_rx_tdata;
assign m_axis_if_rx_tkeep = s_axis_if_rx_tkeep;
assign m_axis_if_rx_tvalid = s_axis_if_rx_tvalid;
assign s_axis_if_rx_tready = m_axis_if_rx_tready;
assign m_axis_if_rx_tlast = s_axis_if_rx_tlast;
assign m_axis_if_rx_tid = s_axis_if_rx_tid;
assign m_axis_if_rx_tdest = s_axis_if_rx_tdest;
assign m_axis_if_rx_tuser = s_axis_if_rx_tuser;

endmodule
