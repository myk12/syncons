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
 *      - 0x0100 CONTROL
 *      - 0x0104 STATUS
 *      - 0x0108 ERROR
 *      - 0x010c SCRATCH

 *  // SSR configuration
 *      - 0x0200 REPLICA_ID
 *      - 0x0204 REPLICA_NUM
 *      - 0x0280 ROUND_LENGTH_NS
 *      - 0x02c0 ETHERNET_PORT

 *  // Replica MAC table
 *  > Each entry is 8 bytes:
 *      - 0x0300 + (i * 8) + 0x0  REPLICA_MAC_LO[i]
 *      - 0x0304 + (i * 8) + 0x4  REPLICA_MAC_HI[i]
 *
 *  > MAC address format:
 *      - REPLICA_MAC_LO[i]    = mac[31:0]
 *      - REPLICA_MAC_HI[i][15:0] = mac[47:32]
 *      - REPLICA_MAC_HI[i][31:16] reserved / future flags
 * 
 * -----------------------------------------------------
 *         DMA Queue Registers
 * -----------------------------------------------------
 * BASE_ADDR = 0x0000_1000
 * ADDR_WIDTH = 24 bits (16KB register space)
 *  // DMA Proposal Queue interface:
 *      - 0x1000 PROPOSAL_DMA_ADDR_LO
 *      - 0x1004 PROPOSAL_DMA_ADDR_HI
 *      - 0x1008 PROPOSAL_DMA_LEN
 *      - 0x100c PROPOSAL_DMA_CONTROL
 *      - 0x1010 PROPOSAL_DMA_STATUS
 *      - 0x1014 PROPOSAL_DMA_ERROR
 *      - 0x1018 PROPOSAL_QUEUE_STATUS
 *      - 0x101c PROPOSAL_QUEUE_ENTRY_COUNT
 *      - 0x1020 PROPOSAL_QUEUE_CONSUMED_COUNT
 *
 * // DMA Commit Queue interface
 *      - 0x1100 COMMIT_DMA_ADDR_LO
 *      - 0x1104 COMMIT_DMA_ADDR_HI
 *      - 0x1108 COMMIT_DMA_LEN
 *      - 0x110c COMMIT_DMA_CONTROL
 *      - 0x1110 COMMIT_DMA_STATUS
 *      - 0x1114 COMMIT_DMA_ERROR
 *      - 0x1118 COMMIT_QUEUE_STATUS
 *      - 0x111c COMMIT_QUEUE_ENTRY_COUNT
 *      - 0x1120 COMMIT_QUEUE_CONSUMED_COUNT    
 */

module ssr_dataplane #
(
    parameter APP_ID = 0,
    parameter REG_ADDR_WIDTH = 24,
    parameter REG_DATA_WIDTH = 32,
    parameter REG_STRB_WIDTH = (REG_DATA_WIDTH / 8),
    parameter RB_BASE_ADDR = 0,
    parameter RB_NEXT_PTR = 0,

    // SSR configuration parameters
    parameter MAX_REPLICAS = 7,

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
    parameter RAM_PIPELINE = 2
)
(
    input  wire                                     clk,
    input  wire                                     rst,

    /*
     * Register interface
     */
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

    /*
     * DMA read descriptor output interface
     */
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_data_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_data_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_data_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_data_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_data_dma_read_desc_tag,
    output wire                                     m_axis_data_dma_read_desc_valid,
    input  wire                                     m_axis_data_dma_read_desc_ready,

    /*
     * DMA read descriptor status input interface
     */
    input wire [DMA_TAG_WIDTH-1:0]                  s_axis_data_dma_read_desc_status_tag,
    input wire [3:0]                                s_axis_data_dma_read_desc_status_error,
    input wire                                      s_axis_data_dma_read_desc_status_valid,

    /*
     * DMA RAM interface (data)
     */
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]            data_dma_ram_wr_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]         data_dma_ram_wr_cmd_be,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]       data_dma_ram_wr_cmd_addr,
    input wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]       data_dma_ram_wr_cmd_data,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_wr_done,

    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]            data_dma_ram_rd_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]       data_dma_ram_rd_cmd_addr,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      data_dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_rd_resp_valid,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_rd_resp_ready
);

// --------------------------------------------------------------
//                  Register block constants
// --------------------------------------------------------------
localparam SSR_RB_TYPE      = 32'h53535201; // "SSR" + version 1
localparam SSR_RB_VERSION   = 32'h00000100; // version 1.0.0
localparam [REG_ADDR_WIDTH-1:0] SSR_RBB_COMMON    = 24'h000000; // base address of basic register block
localparam [REG_ADDR_WIDTH-1:0] SSR_RBB_DMA      = 24'h001000; // base address of DMA register block

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
wire reg_wr_sel_common          = reg_wr_addr[REG_ADDR_WIDTH-1:12] == SSR_RBB_COMMON[REG_ADDR_WIDTH-1:12];
wire reg_rd_sel_common          = reg_rd_addr[REG_ADDR_WIDTH-1:12] == SSR_RBB_COMMON[REG_ADDR_WIDTH-1:12];

wire reg_wr_sel_dma_proposal    = reg_wr_addr[REG_ADDR_WIDTH-1:12] == SSR_RBB_DMA[REG_ADDR_WIDTH-1:12];
wire reg_rd_sel_dma_proposal    = reg_rd_addr[REG_ADDR_WIDTH-1:12] == SSR_RBB_DMA[REG_ADDR_WIDTH-1:12];

wire common_reg_wr_en           = reg_wr_en && reg_wr_sel_common;
wire common_reg_rd_en           = reg_rd_en && reg_rd_sel_common;

wire dma_proposal_reg_wr_en     = reg_wr_en && reg_wr_sel_dma_proposal;
wire dma_proposal_reg_rd_en     = reg_rd_en && reg_rd_sel_dma_proposal;

wire dma_proposal_reg_wr_wait;
wire dma_proposal_reg_wr_ack;

wire [REG_DATA_WIDTH-1:0]   dma_proposal_reg_rd_data;
wire                        dma_proposal_reg_rd_wait;
wire                        dma_proposal_reg_rd_ack;

// control registers
reg                         reg_wr_ack_reg  = 1'b0, reg_wr_ack_next;
reg [REG_DATA_WIDTH-1:0]    reg_rd_data_reg = 0, reg_rd_data_next;
reg                         reg_rd_ack_reg  = 1'b0, reg_rd_ack_next;

assign reg_wr_wait  = 0; // this module can always accept write commands (no wait states)
assign reg_rd_wait  = 0; // this module can always accept read commands (no wait states)
assign reg_wr_ack   = reg_wr_ack_reg || dma_proposal_reg_wr_ack; // acknowledge if either the common register block or the DMA proposal block acknowledges
assign reg_rd_ack   = reg_rd_ack_reg || dma_proposal_reg_rd_ack; // acknowledge if either the common register block or the DMA proposal block acknowledges
assign reg_rd_data  = dma_proposal_reg_rd_ack ? dma_proposal_reg_rd_data : 
                      reg_rd_ack_reg ? reg_rd_data_reg : {REG_DATA_WIDTH{1'b0}}; // return data from the appropriate block based on which one acknowledges

wire reg_wr_sel_any = reg_wr_sel_common || reg_wr_sel_dma_proposal;
wire reg_rd_sel_any = reg_rd_sel_common || reg_rd_sel_dma_proposal;

reg unmapped_wr_ack_reg = 1'b0, unmapped_wr_ack_next;
reg unmapped_rd_ack_reg = 1'b0, unmapped_rd_ack_next;

assign reg_wr_ack = reg_wr_ack_reg || dma_proposal_reg_wr_ack || unmapped_wr_ack_reg;
assign reg_rd_ack = reg_rd_ack_reg || dma_proposal_reg_rd_ack || unmapped_rd_ack_reg;

assign reg_rd_data = dma_proposal_reg_rd_ack ? dma_proposal_reg_rd_data : 
                 reg_rd_ack_reg ? reg_rd_data_reg : {REG_DATA_WIDTH{1'b0}}; // return data from the appropriate block based on which one acknowledges

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
    reg_wr_ack_next     = 1'b0;
    reg_rd_data_next    = 0;
    reg_rd_ack_next     = 1'b0;

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

    unmapped_wr_ack_next = 1'b0;
    unmapped_rd_ack_next = 1'b0;

    if (reg_wr_en && !reg_wr_sel_any && !unmapped_wr_ack_reg) begin
        unmapped_wr_ack_next = 1'b1; // acknowledge writes to unmapped addresses to prevent blocking
    end

    if (reg_rd_en && !reg_rd_sel_any && !unmapped_rd_ack_reg) begin
        unmapped_rd_ack_next = 1'b1; // acknowledge reads to unmapped addresses to prevent blocking
    end

    if (common_reg_wr_en && !reg_wr_ack_reg) begin
        // write operation - decode address and update registers
        reg_wr_ack_next = 1'b1; // acknowledge the write
        case ({reg_wr_addr >> 2, 2'b00}) // align address to 4 bytes
            SSR_RBB_COMMON + 16'h0000: ; // TYPE is read-only
            SSR_RBB_COMMON + 16'h0004: ; // VERSION is read-only
            SSR_RBB_COMMON + 16'h0008: ; // NEXT_PTR is read-only
            SSR_RBB_COMMON + 16'h000c: ; // FEATURES is read-only

            SSR_RBB_COMMON + 16'h0010: control_reg_next  = reg_wr_data; // CONTROL
            SSR_RBB_COMMON + 16'h0014: ; // STATUS is read-only
            SSR_RBB_COMMON + 16'h0018: error_reg_next    = error_reg & ~reg_wr_data; // ERROR (write 1 to clear)
            SSR_RBB_COMMON + 16'h001c: scratch_reg_next  = reg_wr_data; // SCRATCH

            SSR_RBB_COMMON + 16'h0020: replica_id_reg_next   = reg_wr_data; // REPLICA_ID
            SSR_RBB_COMMON + 16'h0024: replica_num_reg_next  = reg_wr_data; // REPLICA_NUM
            SSR_RBB_COMMON + 16'h0028: round_length_ns_reg_next  = reg_wr_data; // ROUND_LENGTH_NS
            SSR_RBB_COMMON + 16'h002c: ethernet_port_reg_next    = reg_wr_data; // ETHERNET_PORT

            // replica MAC table entries
            // replica 0
            SSR_RBB_COMMON + 16'h0100 + 0: replica_mac_lo_next[0] = reg_wr_data; // REPLICA_MAC_LO[0]
            SSR_RBB_COMMON + 16'h0100 + 4: replica_mac_hi_next[0] = reg_wr_data; // REPLICA_MAC_HI[0]
            // replica 1
            SSR_RBB_COMMON + 16'h0100 + 8: replica_mac_lo_next[1] = reg_wr_data; // REPLICA_MAC_LO[1]
            SSR_RBB_COMMON + 16'h0100 + 12: replica_mac_hi_next[1] = reg_wr_data; // REPLICA_MAC_HI[1]
            // replica 2
            SSR_RBB_COMMON + 16'h0100 + 16: replica_mac_lo_next[2] = reg_wr_data; // REPLICA_MAC_LO[2]
            SSR_RBB_COMMON + 16'h0100 + 20: replica_mac_hi_next[2] = reg_wr_data; // REPLICA_MAC_HI[2]
            // replica 3
            SSR_RBB_COMMON + 16'h0100 + 24: replica_mac_lo_next[3] = reg_wr_data; // REPLICA_MAC_LO[3]
            SSR_RBB_COMMON + 16'h0100 + 28: replica_mac_hi_next[3] = reg_wr_data; // REPLICA_MAC_HI[3]
            // replica 4
            SSR_RBB_COMMON + 16'h0100 + 32: replica_mac_lo_next[4] = reg_wr_data; // REPLICA_MAC_LO[4]
            SSR_RBB_COMMON + 16'h0100 + 36: replica_mac_hi_next[4] = reg_wr_data; // REPLICA_MAC_HI[4]
            // replica 5
            SSR_RBB_COMMON + 16'h0100 + 40: replica_mac_lo_next[5] = reg_wr_data; // REPLICA_MAC_LO[5]
            SSR_RBB_COMMON + 16'h0100 + 44: replica_mac_hi_next[5] = reg_wr_data; // REPLICA_MAC_HI[5]
            // replica 6
            SSR_RBB_COMMON + 16'h0100 + 48: replica_mac_lo_next[6] = reg_wr_data; // REPLICA_MAC_LO[6]
            SSR_RBB_COMMON + 16'h0100 + 52: replica_mac_hi_next[6] = reg_wr_data; // REPLICA_MAC_HI[6]

            default: reg_wr_ack_next = 1'b0; // invalid address, do not acknowledge
        endcase
    end

    if (common_reg_rd_en && !reg_rd_ack_reg) begin
        // read operation - decode address and return data
        reg_rd_ack_next = 1'b1; // acknowledge the read
        case ({reg_rd_addr >> 2, 2'b00}) // align address to 4 bytes
            SSR_RBB_COMMON + 16'h0000: reg_rd_data_next = SSR_RB_TYPE; // TYPE
            SSR_RBB_COMMON + 16'h0004: reg_rd_data_next = SSR_RB_VERSION; // VERSION
            SSR_RBB_COMMON + 16'h0008: reg_rd_data_next = 32'h0000_0000; // NEXT_PTR
            SSR_RBB_COMMON + 16'h000c: reg_rd_data_next = 32'h0000_000f; // FEATURES (no special features supported)

            SSR_RBB_COMMON + 16'h0010: reg_rd_data_next = control_reg; // CONTROL
            SSR_RBB_COMMON + 16'h0014: begin
               reg_rd_data_next[0] = config_valid; // bit 0 indicates whether configuration is valid
               reg_rd_data_next[1] = control_reg[0]; // bit 1 reflects the reset input signal
               reg_rd_data_next[2] = control_reg[1]; // bit 2 reflects the reset
            end
            SSR_RBB_COMMON + 16'h0018: reg_rd_data_next = error_reg; // ERROR
            SSR_RBB_COMMON + 16'h001c: reg_rd_data_next = scratch_reg; // SCRATCH

            SSR_RBB_COMMON + 16'h0020: reg_rd_data_next = replica_id_reg; // REPLICA_ID
            SSR_RBB_COMMON + 16'h0024: reg_rd_data_next = replica_num_reg; // REPLICA_NUM
            SSR_RBB_COMMON + 16'h0028: reg_rd_data_next = round_length_ns_reg; // ROUND_LENGTH_NS
            SSR_RBB_COMMON + 16'h002c: reg_rd_data_next = ethernet_port_reg; // ETHERNET_PORT

            // replica MAC table entries
            // replica 0
            SSR_RBB_COMMON + 16'h0100 + 0: reg_rd_data_next = replica_mac_lo[0]; // REPLICA_MAC_LO[0]
            SSR_RBB_COMMON + 16'h0100 + 4: reg_rd_data_next = replica_mac_hi[0]; // REPLICA_MAC_HI[0]
            // replica 1
            SSR_RBB_COMMON + 16'h0100 + 8: reg_rd_data_next = replica_mac_lo[1]; // REPLICA_MAC_LO[1]
            SSR_RBB_COMMON + 16'h0100 + 12: reg_rd_data_next = replica_mac_hi[1]; // REPLICA_MAC_HI[1]
            // replica 2
            SSR_RBB_COMMON + 16'h0100 + 16: reg_rd_data_next = replica_mac_lo[2]; // REPLICA_MAC_LO[2]
            SSR_RBB_COMMON + 16'h0100 + 20: reg_rd_data_next = replica_mac_hi[2]; // REPLICA_MAC_HI[2]
            // replica 3
            SSR_RBB_COMMON + 16'h0100 + 24: reg_rd_data_next = replica_mac_lo[3]; // REPLICA_MAC_LO[3]
            SSR_RBB_COMMON + 16'h0100 + 28: reg_rd_data_next = replica_mac_hi[3]; // REPLICA_MAC_HI[3]
            // replica 4
            SSR_RBB_COMMON + 16'h0100 + 32: reg_rd_data_next = replica_mac_lo[4]; // REPLICA_MAC_LO[4]
            SSR_RBB_COMMON + 16'h0100 + 36: reg_rd_data_next = replica_mac_hi[4]; // REPLICA_MAC_HI[4]
            // replica 5
            SSR_RBB_COMMON + 16'h0100 + 40: reg_rd_data_next = replica_mac_lo[5]; // REPLICA_MAC_LO[5]
            SSR_RBB_COMMON + 16'h0100 + 44: reg_rd_data_next = replica_mac_hi[5]; // REPLICA_MAC_HI[5]
            // replica 6
            SSR_RBB_COMMON + 16'h0100 + 48: reg_rd_data_next = replica_mac_lo[6]; // REPLICA_MAC_LO[6]
            SSR_RBB_COMMON + 16'h0100 + 52: reg_rd_data_next = replica_mac_hi[6]; // REPLICA_MAC_HI[6]
            default: begin
                reg_rd_data_next = 0; // invalid address, return 0
                reg_rd_ack_next = 1'b0; // do not acknowledge
            end
        endcase
    end
end

// sequential logic to update registers on clock edge
always @(posedge clk) begin
    if (rst) begin
        reg_wr_ack_reg  <= 1'b0;
        reg_rd_data_reg <= 0;
        reg_rd_ack_reg  <= 1'b0;
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

        unmapped_wr_ack_reg <= 1'b0;
        unmapped_rd_ack_reg <= 1'b0;
    end else begin
        reg_wr_ack_reg  <= reg_wr_ack_next;
        reg_rd_data_reg <= reg_rd_data_next;
        reg_rd_ack_reg  <= reg_rd_ack_next;
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

        unmapped_wr_ack_reg <= unmapped_wr_ack_next;
        unmapped_rd_ack_reg <= unmapped_rd_ack_next;
    end
end

// --------------------------------------------------------------
//                 DMA proposal queue
// --------------------------------------------------------------

assign data_dma_ram_rd_cmd_ready = 0; // this module does not issue read commands to the DMA RAM
assign data_dma_ram_rd_resp_data = 0; // this module does not receive read responses from the DMA RAM
assign data_dma_ram_rd_resp_valid = 0;

proposal_queue #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .REG_STRB_WIDTH(REG_STRB_WIDTH),
    .RB_BASE_ADDR(SSR_RBB_DMA),

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
    .reg_wr_en(dma_proposal_reg_wr_en),
    .reg_wr_wait(dma_proposal_reg_wr_wait),
    .reg_wr_ack(dma_proposal_reg_wr_ack),

    .reg_rd_addr(reg_rd_addr),
    .reg_rd_en(dma_proposal_reg_rd_en),
    .reg_rd_data(dma_proposal_reg_rd_data),
    .reg_rd_wait(dma_proposal_reg_rd_wait),
    .reg_rd_ack(dma_proposal_reg_rd_ack),

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
    .proposal_dma_ram_wr_cmd_sel(data_dma_ram_wr_cmd_sel),
    .proposal_dma_ram_wr_cmd_be(data_dma_ram_wr_cmd_be),
    .proposal_dma_ram_wr_cmd_addr(data_dma_ram_wr_cmd_addr),
    .proposal_dma_ram_wr_cmd_data(data_dma_ram_wr_cmd_data),
    .proposal_dma_ram_wr_cmd_valid(data_dma_ram_wr_cmd_valid),
    .proposal_dma_ram_wr_cmd_ready(data_dma_ram_wr_cmd_ready),
    .proposal_dma_ram_wr_done(data_dma_ram_wr_done)
);

endmodule
