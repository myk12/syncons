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
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_IMM_ENABLE = 0,
    parameter DMA_IMM_WIDTH = 32,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,
    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 16,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256 * 2/ RAM_SEG_COUNT, // each segment is 256 bits (32 bytes)
    parameter RAM_SEG_BE_WIDTH = (RAM_SEG_DATA_WIDTH / 8),
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT * RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,

    // Ethernet interface configuration (interface)
    parameter AXIS_IF_DATA_WIDTH = 512,
    parameter AXIS_IF_KEEP_WIDTH = (AXIS_IF_DATA_WIDTH / 8),
    parameter AXIS_IF_TX_ID_WIDTH = 12,
    parameter AXIS_IF_RX_ID_WIDTH = PORTS_PER_IF > 1 ? $clog2(PORTS_PER_IF) : 1,
    parameter AXIS_IF_TX_DEST_WIDTH = $clog2(PORTS_PER_IF) + 4,
    parameter AXIS_IF_RX_DEST_WIDTH = 8,
    parameter AXIS_IF_TX_USER_WIDTH = 1,
    parameter AXIS_IF_RX_USER_WIDTH = 1
)
(
    input  wire                                     clk,
    input  wire                                     rst,

    // --------------------------------------------------------------
    //                 Control/Status Register interface
    // --------------------------------------------------------------
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

    // --------------------------------------------------------------
    //                          DMA interface
    // --------------------------------------------------------------
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

    // --------------------------------------------------------------
    //                          PTP clock
    // --------------------------------------------------------------
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

    // --------------------------------------------------------------
    //                      Ethernet interfaces
    // --------------------------------------------------------------
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

// --------------------------------------------------------------
//                  Register block constants
// --------------------------------------------------------------
localparam SSR_RB_TYPE                              = 32'h53535201; // "SSR" + version 1
localparam SSR_RB_VERSION                           = 32'h00000100; // version 1.0.0
localparam [REG_ADDR_WIDTH-1:0] RBB_COMMON          = 24'h000000; // base address of basic register block
localparam [REG_ADDR_WIDTH-1:0] RBB_PROPOSAL_QUEUE  = 24'h001000; // base address of DMA register block
localparam [REG_ADDR_WIDTH-1:0] RBB_COMMIT_QUEUE    = 24'h002000; // base address of commit queue register block

// DMA proposal queue
localparam RAM_SEL_RPOP = 0;

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

// --------------------------------------------------------------
//                 Control/status register block
// --------------------------------------------------------------
// control registers for common register block
reg                         reg_wr_ack_common_reg  = 1'b0, reg_wr_ack_common_next;
reg [REG_DATA_WIDTH-1:0]    reg_rd_data_common_reg = 0, reg_rd_data_common_next;
reg                         reg_rd_ack_common_reg  = 1'b0, reg_rd_ack_common_next;

// register select signals
wire reg_wr_en_common           = reg_wr_en && reg_wr_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMON[REG_ADDR_WIDTH-1:12];
wire reg_wr_en_proposal_queue   = reg_wr_en && reg_wr_addr[REG_ADDR_WIDTH-1:12] == RBB_PROPOSAL_QUEUE[REG_ADDR_WIDTH-1:12];
wire reg_wr_en_commit_queue     = reg_wr_en && reg_wr_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMIT_QUEUE[REG_ADDR_WIDTH-1:12];
wire reg_wr_wait_common, reg_wr_wait_proposal_queue, reg_wr_wait_commit_queue;
wire reg_wr_ack_common, reg_wr_ack_proposal_queue, reg_wr_ack_commit_queue;

wire reg_rd_en_common           = reg_rd_en && reg_rd_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMON[REG_ADDR_WIDTH-1:12];
wire reg_rd_en_proposal_queue   = reg_rd_en && reg_rd_addr[REG_ADDR_WIDTH-1:12] == RBB_PROPOSAL_QUEUE[REG_ADDR_WIDTH-1:12];
wire reg_rd_en_commit_queue     = reg_rd_en && reg_rd_addr[REG_ADDR_WIDTH-1:12] == RBB_COMMIT_QUEUE[REG_ADDR_WIDTH-1:12];
wire [REG_DATA_WIDTH-1:0]   reg_rd_data_common, reg_rd_data_proposal_queue, reg_rd_data_commit_queue;
wire                        reg_rd_wait_common, reg_rd_wait_proposal_queue, reg_rd_wait_commit_queue;
wire                        reg_rd_ack_common, reg_rd_ack_proposal_queue, reg_rd_ack_commit_queue;

// common assignments
assign reg_wr_ack_common = reg_wr_ack_common_reg;
assign reg_rd_ack_common = reg_rd_ack_common_reg;
assign reg_rd_data_common = reg_rd_data_common_reg;

assign reg_wr_wait_common = 0;
assign reg_rd_wait_common = 0;

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
reg [31:0] ethernet_port_reg, ethernet_port_reg_next;

// replica MAC table (up to MAX_REPLICAS entries)
reg [31:0] replica_mac_lo [0:MAX_REPLICAS-1], replica_mac_lo_next [0:MAX_REPLICAS-1];
reg [31:0] replica_mac_hi [0:MAX_REPLICAS-1], replica_mac_hi_next [0:MAX_REPLICAS-1];

wire config_valid = replica_num_reg != 0 &&
                    replica_num_reg <= MAX_REPLICAS &&
                    round_length_ns_reg != 0 &&
                    replica_id_reg < replica_num_reg;

// --------------------------------------------------------------
//                  Register block logic
// --------------------------------------------------------------
integer i; // loop variable for updating replica MAC table entries

always @* begin
    // default outputs
    reg_wr_ack_common_next     = 1'b0; 
    reg_rd_data_common_next    = 0;
    reg_rd_ack_common_next     = 1'b0;

    // default next state is to hold current values
    control_reg_next    = control_reg;
    //status_reg_next   = status_reg;
    error_reg_next      = error_reg;
    scratch_reg_next    = scratch_reg;

    replica_id_reg_next         = replica_id_reg;
    replica_num_reg_next        = replica_num_reg;
    round_length_ns_reg_next    = round_length_ns_reg;
    ethernet_port_reg_next      = ethernet_port_reg;

    for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
        replica_mac_lo_next[i] = replica_mac_lo[i];
        replica_mac_hi_next[i] = replica_mac_hi[i];
    end

    if (reg_wr_en_common && !reg_wr_ack_common_reg) begin
        // write operation - decode address and update registers
        reg_wr_ack_common_next = 1'b1; // acknowledge the write
        case ({reg_wr_addr[REG_ADDR_WIDTH-1:2], 2'b00}) // align address to 4 bytes
            RBB_COMMON + 12'h000: ; // TYPE is read-only
            RBB_COMMON + 12'h004: ; // VERSION is read-only
            RBB_COMMON + 12'h008: ; // NEXT_PTR is read-only
            RBB_COMMON + 12'h00c: ; // FEATURES is read-only

            RBB_COMMON + 12'h010: control_reg_next  = reg_wr_data; // CONTROL
            RBB_COMMON + 12'h014: ; // STATUS is read-only
            RBB_COMMON + 12'h018: error_reg_next    = error_reg & ~reg_wr_data; // ERROR (write 1 to clear)
            RBB_COMMON + 12'h01c: scratch_reg_next  = reg_wr_data; // SCRATCH

            RBB_COMMON + 12'h020: replica_id_reg_next   = reg_wr_data; // REPLICA_ID
            RBB_COMMON + 12'h024: replica_num_reg_next  = reg_wr_data; // REPLICA_NUM
            RBB_COMMON + 12'h028: round_length_ns_reg_next  = reg_wr_data; // ROUND_LENGTH_NS
            RBB_COMMON + 12'h02c: ethernet_port_reg_next    = reg_wr_data; // ETHERNET_PORT

            // replica MAC table entries
            // replica 0
            RBB_COMMON + 12'h100 + 0: replica_mac_lo_next[0] = reg_wr_data; // REPLICA_MAC_LO[0]
            RBB_COMMON + 12'h100 + 4: replica_mac_hi_next[0] = reg_wr_data; // REPLICA_MAC_HI[0]
            // replica 1
            RBB_COMMON + 12'h100 + 8: replica_mac_lo_next[1] = reg_wr_data; // REPLICA_MAC_LO[1]
            RBB_COMMON + 12'h100 + 12: replica_mac_hi_next[1] = reg_wr_data; // REPLICA_MAC_HI[1]
            // replica 2
            RBB_COMMON + 12'h100 + 16: replica_mac_lo_next[2] = reg_wr_data; // REPLICA_MAC_LO[2]
            RBB_COMMON + 12'h100 + 20: replica_mac_hi_next[2] = reg_wr_data; // REPLICA_MAC_HI[2]
            // replica 3
            RBB_COMMON + 12'h100 + 24: replica_mac_lo_next[3] = reg_wr_data; // REPLICA_MAC_LO[3]
            RBB_COMMON + 12'h100 + 28: replica_mac_hi_next[3] = reg_wr_data; // REPLICA_MAC_HI[3]
            // replica 4
            RBB_COMMON + 12'h100 + 32: replica_mac_lo_next[4] = reg_wr_data; // REPLICA_MAC_LO[4]
            RBB_COMMON + 12'h100 + 36: replica_mac_hi_next[4] = reg_wr_data; // REPLICA_MAC_HI[4]
            // replica 5
            RBB_COMMON + 12'h100 + 40: replica_mac_lo_next[5] = reg_wr_data; // REPLICA_MAC_LO[5]
            RBB_COMMON + 12'h100 + 44: replica_mac_hi_next[5] = reg_wr_data; // REPLICA_MAC_HI[5]
            // replica 6
            RBB_COMMON + 12'h100 + 48: replica_mac_lo_next[6] = reg_wr_data; // REPLICA_MAC_LO[6]
            RBB_COMMON + 12'h100 + 52: replica_mac_hi_next[6] = reg_wr_data; // REPLICA_MAC_HI[6]

            default: reg_wr_ack_common_next = 1'b0; // invalid address, do not acknowledge
        endcase
    end

    if (reg_rd_en_common && !reg_rd_ack_common_reg) begin
        // read operation - decode address and return data
        reg_rd_ack_common_next = 1'b1; // acknowledge the read
        case ({reg_rd_addr[REG_ADDR_WIDTH-1:2], 2'b00}) // align address to 4 bytes
            RBB_COMMON + 12'h000: reg_rd_data_common_next = SSR_RB_TYPE; // TYPE
            RBB_COMMON + 12'h004: reg_rd_data_common_next = SSR_RB_VERSION; // VERSION
            RBB_COMMON + 12'h008: reg_rd_data_common_next = 32'h0000_0000; // NEXT_PTR
            RBB_COMMON + 12'h00c: reg_rd_data_common_next = 32'h0000_000f; // FEATURES (no special features supported)

            RBB_COMMON + 12'h010: reg_rd_data_common_next = control_reg; // CONTROL
            RBB_COMMON + 12'h014: begin
               reg_rd_data_common_next[0] = config_valid; // bit 0 indicates whether configuration is valid
               reg_rd_data_common_next[1] = control_reg[0]; // bit 1 reflects the reset input signal
               reg_rd_data_common_next[2] = control_reg[1]; // bit 2 reflects the reset
            end
            RBB_COMMON + 12'h018: reg_rd_data_common_next = error_reg; // ERROR
            RBB_COMMON + 12'h01c: reg_rd_data_common_next = scratch_reg; // SCRATCH

            RBB_COMMON + 12'h020: reg_rd_data_common_next = replica_id_reg; // REPLICA_ID
            RBB_COMMON + 12'h024: reg_rd_data_common_next = replica_num_reg; // REPLICA_NUM
            RBB_COMMON + 12'h028: reg_rd_data_common_next = round_length_ns_reg; // ROUND_LENGTH_NS
            RBB_COMMON + 12'h02c: reg_rd_data_common_next = ethernet_port_reg; // ETHERNET_PORT

            // replica MAC table entries
            // replica 0
            RBB_COMMON + 12'h100 + 0: reg_rd_data_common_next = replica_mac_lo[0]; // REPLICA_MAC_LO[0]
            RBB_COMMON + 12'h100 + 4: reg_rd_data_common_next = replica_mac_hi[0]; // REPLICA_MAC_HI[0]
            // replica 1
            RBB_COMMON + 12'h100 + 8: reg_rd_data_common_next = replica_mac_lo[1]; // REPLICA_MAC_LO[1]
            RBB_COMMON + 12'h100 + 12: reg_rd_data_common_next = replica_mac_hi[1]; // REPLICA_MAC_HI[1]
            // replica 2
            RBB_COMMON + 12'h100 + 16: reg_rd_data_common_next = replica_mac_lo[2]; // REPLICA_MAC_LO[2]
            RBB_COMMON + 12'h100 + 20: reg_rd_data_common_next = replica_mac_hi[2]; // REPLICA_MAC_HI[2]
            // replica 3
            RBB_COMMON + 12'h100 + 24: reg_rd_data_common_next = replica_mac_lo[3]; // REPLICA_MAC_LO[3]
            RBB_COMMON + 12'h100 + 28: reg_rd_data_common_next = replica_mac_hi[3]; // REPLICA_MAC_HI[3]
            // replica 4
            RBB_COMMON + 12'h100 + 32: reg_rd_data_common_next = replica_mac_lo[4]; // REPLICA_MAC_LO[4]
            RBB_COMMON + 12'h100 + 36: reg_rd_data_common_next = replica_mac_hi[4]; // REPLICA_MAC_HI[4]
            // replica 5
            RBB_COMMON + 12'h100 + 40: reg_rd_data_common_next = replica_mac_lo[5]; // REPLICA_MAC_LO[5]
            RBB_COMMON + 12'h100 + 44: reg_rd_data_common_next = replica_mac_hi[5]; // REPLICA_MAC_HI[5]
            // replica 6
            RBB_COMMON + 12'h100 + 48: reg_rd_data_common_next = replica_mac_lo[6]; // REPLICA_MAC_LO[6]
            RBB_COMMON + 12'h100 + 52: reg_rd_data_common_next = replica_mac_hi[6]; // REPLICA_MAC_HI[6]
            default: begin
                reg_rd_data_common_next = 0; // invalid address, return 0
                reg_rd_ack_common_next = 1'b0; // do not acknowledge
            end
        endcase
    end
end

// sequential logic to update registers on clock edge
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
        ethernet_port_reg   <= 0;

        for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
            replica_mac_lo[i] <= 0;
            replica_mac_hi[i] <= 0;
        end
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
        ethernet_port_reg   <= ethernet_port_reg_next;

        for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
            replica_mac_lo[i] <= replica_mac_lo_next[i];
            replica_mac_hi[i] <= replica_mac_hi_next[i];
        end
    end
end

// --------------------------------------------------------------
//                 DMA proposal queue
// --------------------------------------------------------------

proposal_queue #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .REG_STRB_WIDTH(REG_STRB_WIDTH),
    .RB_BASE_ADDR(RBB_PROPOSAL_QUEUE),

    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE)
)
proposal_queue_inst (
    .clk(clk),
    .rst(rst),

    // Control/status register interface
    .reg_wr_addr(reg_wr_addr),
    .reg_wr_data(reg_wr_data),
    .reg_wr_strb(reg_wr_strb),
    .reg_wr_en(reg_wr_en_proposal_queue),
    .reg_wr_wait(reg_wr_wait_proposal_queue),
    .reg_wr_ack(reg_wr_ack_proposal_queue),

    .reg_rd_addr(reg_rd_addr),
    .reg_rd_en(reg_rd_en_proposal_queue),
    .reg_rd_data(reg_rd_data_proposal_queue),
    .reg_rd_wait(reg_rd_wait_proposal_queue),
    .reg_rd_ack(reg_rd_ack_proposal_queue),

    // DAM read descriptor output interface
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

    // DMA RAM interface (data)
    .dma_ram_wr_cmd_sel(data_dma_ram_wr_cmd_sel),
    .dma_ram_wr_cmd_be(data_dma_ram_wr_cmd_be),
    .dma_ram_wr_cmd_addr(data_dma_ram_wr_cmd_addr),
    .dma_ram_wr_cmd_data(data_dma_ram_wr_cmd_data),
    .dma_ram_wr_cmd_valid(data_dma_ram_wr_cmd_valid),
    .dma_ram_wr_cmd_ready(data_dma_ram_wr_cmd_ready),
    .dma_ram_wr_done(data_dma_ram_wr_done)
);

// --------------------------------------------------------------
//                 DMA commit queue
// --------------------------------------------------------------

commit_queue #(
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
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE)
)
commit_queue_inst (
    .clk(clk),
    .rst(rst),

    // Control/status register interface
    .reg_wr_addr(reg_wr_addr),
    .reg_wr_data(reg_wr_data),
    .reg_wr_strb(reg_wr_strb),
    .reg_wr_en(reg_wr_en_commit_queue),
    .reg_wr_wait(reg_wr_wait_commit_queue),
    .reg_wr_ack(reg_wr_ack_commit_queue),

    .reg_rd_addr(reg_rd_addr),
    .reg_rd_en(reg_rd_en_commit_queue),
    .reg_rd_data(reg_rd_data_commit_queue),
    .reg_rd_wait(reg_rd_wait_commit_queue),
    .reg_rd_ack(reg_rd_ack_commit_queue),

    // DMA write descriptor output interface
    .m_axis_dma_write_desc_dma_addr(m_axis_data_dma_write_desc_dma_addr),
    .m_axis_dma_write_desc_ram_sel(m_axis_data_dma_write_desc_ram_sel),
    .m_axis_dma_write_desc_ram_addr(m_axis_data_dma_write_desc_ram_addr),
    .m_axis_dma_write_desc_imm(m_axis_data_dma_write_desc_imm),
    .m_axis_dma_write_desc_imm_en(m_axis_data_dma_write_desc_imm_en),
    .m_axis_dma_write_desc_len(m_axis_data_dma_write_desc_len),
    .m_axis_dma_write_desc_tag(m_axis_data_dma_write_desc_tag),
    .m_axis_dma_write_desc_valid(m_axis_data_dma_write_desc_valid),
    .m_axis_dma_write_desc_ready(m_axis_data_dma_write_desc_ready),

    // DMA write descriptor status input interface
    .s_axis_dma_write_status_tag(s_axis_data_dma_write_desc_status_tag),
    .s_axis_dma_write_status_error(s_axis_data_dma_write_desc_status_error),
    .s_axis_dma_write_status_valid(s_axis_data_dma_write_desc_status_valid),

    // DMA RAM read interface
    .dma_ram_rd_cmd_sel(data_dma_ram_rd_cmd_sel),
    .dma_ram_rd_cmd_addr(data_dma_ram_rd_cmd_addr),
    .dma_ram_rd_cmd_valid(data_dma_ram_rd_cmd_valid),
    .dma_ram_rd_cmd_ready(data_dma_ram_rd_cmd_ready),
    .dma_ram_rd_resp_data(data_dma_ram_rd_resp_data),
    .dma_ram_rd_resp_valid(data_dma_ram_rd_resp_valid),
    .dma_ram_rd_resp_ready(data_dma_ram_rd_resp_ready)
);

// --------------------------------------------------------------
//                 Ethernet interface modules
// --------------------------------------------------------------
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
