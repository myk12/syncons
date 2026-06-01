`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * SSR dataplane wrapper with a minimal control/status register block.
 *
 * Register map:
 * // Header
 *  0x000 TYPE
 *  0x004 VERSION
 *  0x008 NEXT_PTR
 *  0x00c FEATURES

 *  // Control/status
 *  0x010 CONTROL
 *  0x014 STATUS
 *  0x018 ERROR
 *  0x01c SCRATCH

 *  // SSR configuration
 *  0x020 REPLICA_ID
 *  0x024 REPLICA_NUM
 *  0x028 ROUND_LENGTH_NS
 *  0x02c ETHERNET_PORT

 * Replica MAC table
 * Each entry is 8 bytes:
 * 0x100 + (i * 8) + 0x0  REPLICA_MAC_LO[i]
 * 0x100 + (i * 8) + 0x4  REPLICA_MAC_HI[i]
 *
 * MAC address format:
 *   REPLICA_MAC_LO[i]    = mac[31:0]
 *   REPLICA_MAC_HI[i][15:0] = mac[47:32]
 *   REPLICA_MAC_HI[i][31:16] reserved / future flags
 */

module ssr_dataplane #
(
    parameter APP_ID = 0,
    parameter REG_ADDR_WIDTH = 12,
    parameter REG_DATA_WIDTH = 32,
    parameter REG_STRB_WIDTH = (REG_DATA_WIDTH / 8),
    parameter RB_BASE_ADDR = 0,
    parameter RB_NEXT_PTR = 0,

    parameter MAX_REPLICAS = 7
)
(
    input  wire                           clk,
    input  wire                           rst,

    //input  wire                           reset_in,
    ///output wire                           reset_out,

    /*
     * Register interface
     */
    input  wire [REG_ADDR_WIDTH-1:0]      reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]      reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]      reg_wr_strb,
    input  wire                           reg_wr_en,
    output wire                           reg_wr_wait,
    output wire                           reg_wr_ack,
    input  wire [REG_ADDR_WIDTH-1:0]      reg_rd_addr,
    input  wire                           reg_rd_en,
    output wire [REG_DATA_WIDTH-1:0]      reg_rd_data,
    output wire                           reg_rd_wait,
    output wire                           reg_rd_ack
);

// --------------------------------------------------------------
//                  Register block constants
// --------------------------------------------------------------
localparam SSR_RB_TYPE      = 32'h53535201; // "SSR" + version 1
localparam SSR_RB_VERSION   = 32'h00000100; // version 1.0.0
localparam RBB = RB_BASE_ADDR & {REG_ADDR_WIDTH{1'b1}}; // base address of register block

localparam CONTROL_START = 12'h010;
localparam CONTROL_END = 12'h01c;

localparam CONFIG_START = 12'h020;
localparam CONFIG_END = 12'h02c;

localparam REPLICA_MAC_START = 12'h100;
localparam REPLICA_MAC_END = REPLICA_MAC_START + MAX_REPLICAS * 8 - 1; // each entry is 8 bytes

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


// control registers
reg reg_wr_ack_reg = 1'b0, reg_wr_ack_next;
reg [REG_DATA_WIDTH-1:0] reg_rd_data_reg = 0, reg_rd_data_next;
reg reg_rd_ack_reg = 1'b0, reg_rd_ack_next;

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

assign reg_wr_wait = 1'b0;
assign reg_wr_ack = reg_wr_ack_reg;
assign reg_rd_data = reg_rd_data_reg;
assign reg_rd_wait = 1'b0;
assign reg_rd_ack = reg_rd_ack_reg;

wire config_valid = replica_num_reg != 0 &&
                    replica_num_reg <= MAX_REPLICAS &&
                    round_length_ns_reg != 0 &&
                    replica_id_reg < replica_num_reg;

//assign reset_out = 0;

// --------------------------------------------------------------
//                  Register block logic
// --------------------------------------------------------------
integer i; // loop variable for updating replica MAC table entries

always @* begin
    // default outputs
    reg_wr_ack_next = 1'b0;
    reg_rd_data_next = 0;
    reg_rd_ack_next = 1'b0;

    // default next state is to hold current values
    control_reg_next = control_reg;
    //status_reg_next = status_reg;
    error_reg_next = error_reg;
    scratch_reg_next = scratch_reg;

    replica_id_reg_next = replica_id_reg;
    replica_num_reg_next = replica_num_reg;
    round_length_ns_reg_next = round_length_ns_reg;
    ethernet_port_reg_next = ethernet_port_reg;

    for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
        replica_mac_lo_next[i] = replica_mac_lo[i];
        replica_mac_hi_next[i] = replica_mac_hi[i];
    end

    if (reg_wr_en && !reg_wr_ack_reg) begin
        // write operation - decode address and update registers
        reg_wr_ack_next = 1'b1; // acknowledge the write
        case ({reg_wr_addr >> 2, 2'b00}) // align address to 4 bytes
            RBB + 12'h000: ; // TYPE is read-only
            RBB + 12'h004: ; // VERSION is read-only
            RBB + 12'h008: ; // NEXT_PTR is read-only
            RBB + 12'h00c: ; // FEATURES is read-only

            RBB + 12'h010: control_reg_next = reg_wr_data; // CONTROL
            RBB + 12'h014: ; // STATUS is read-only
            RBB + 12'h018: error_reg_next = error_reg & ~reg_wr_data; // ERROR (write 1 to clear)
            RBB + 12'h01c: scratch_reg_next = reg_wr_data; // SCRATCH

            RBB + 12'h020: replica_id_reg_next = reg_wr_data; // REPLICA_ID
            RBB + 12'h024: replica_num_reg_next = reg_wr_data; // REPLICA_NUM
            RBB + 12'h028: round_length_ns_reg_next = reg_wr_data; // ROUND_LENGTH_NS
            RBB + 12'h02c: ethernet_port_reg_next = reg_wr_data; // ETHERNET_PORT

            // replica MAC table entries
            // replica 0
            RBB + 12'h100 + 0: replica_mac_lo_next[0] = reg_wr_data; // REPLICA_MAC_LO[0]
            RBB + 12'h100 + 4: replica_mac_hi_next[0] = reg_wr_data; // REPLICA_MAC_HI[0]
            // replica 1
            RBB + 12'h100 + 8: replica_mac_lo_next[1] = reg_wr_data; // REPLICA_MAC_LO[1]
            RBB + 12'h100 + 12: replica_mac_hi_next[1] = reg_wr_data; // REPLICA_MAC_HI[1]
            // replica 2
            RBB + 12'h100 + 16: replica_mac_lo_next[2] = reg_wr_data; // REPLICA_MAC_LO[2]
            RBB + 12'h100 + 20: replica_mac_hi_next[2] = reg_wr_data; // REPLICA_MAC_HI[2]
            // replica 3
            RBB + 12'h100 + 24: replica_mac_lo_next[3] = reg_wr_data; // REPLICA_MAC_LO[3]
            RBB + 12'h100 + 28: replica_mac_hi_next[3] = reg_wr_data; // REPLICA_MAC_HI[3]
            // replica 4
            RBB + 12'h100 + 32: replica_mac_lo_next[4] = reg_wr_data; // REPLICA_MAC_LO[4]
            RBB + 12'h100 + 36: replica_mac_hi_next[4] = reg_wr_data; // REPLICA_MAC_HI[4]
            // replica 5
            RBB + 12'h100 + 40: replica_mac_lo_next[5] = reg_wr_data; // REPLICA_MAC_LO[5]
            RBB + 12'h100 + 44: replica_mac_hi_next[5] = reg_wr_data; // REPLICA_MAC_HI[5]
            // replica 6
            RBB + 12'h100 + 48: replica_mac_lo_next[6] = reg_wr_data; // REPLICA_MAC_LO[6]
            RBB + 12'h100 + 52: replica_mac_hi_next[6] = reg_wr_data; // REPLICA_MAC_HI[6]

            default: reg_wr_ack_next = 1'b0; // invalid address, do not acknowledge
        endcase
    end

    if (reg_rd_en && !reg_rd_ack_reg) begin
        // read operation - decode address and return data
        reg_rd_ack_next = 1'b1; // acknowledge the read
        case ({reg_rd_addr >> 2, 2'b00}) // align address to 4 bytes
            RBB + 12'h000: reg_rd_data_next = SSR_RB_TYPE; // TYPE
            RBB + 12'h004: reg_rd_data_next = SSR_RB_VERSION; // VERSION
            RBB + 12'h008: reg_rd_data_next = RB_NEXT_PTR; // NEXT_PTR
            RBB + 12'h00c: reg_rd_data_next = 32'h0000_000f; // FEATURES (no special features supported)

            RBB + 12'h010: reg_rd_data_next = control_reg; // CONTROL
            RBB + 12'h014: begin
               reg_rd_data_next[0] = config_valid; // bit 0 indicates whether configuration is valid
               reg_rd_data_next[1] = control_reg[0]; // bit 1 reflects the reset input signal
               reg_rd_data_next[2] = control_reg[1]; // bit 2 reflects the reset
            end
            RBB + 12'h018: reg_rd_data_next = error_reg; // ERROR
            RBB + 12'h01c: reg_rd_data_next = scratch_reg; // SCRATCH

            RBB + 12'h020: reg_rd_data_next = replica_id_reg; // REPLICA_ID
            RBB + 12'h024: reg_rd_data_next = replica_num_reg; // REPLICA_NUM
            RBB + 12'h028: reg_rd_data_next = round_length_ns_reg; // ROUND_LENGTH_NS
            RBB + 12'h02c: reg_rd_data_next = ethernet_port_reg; // ETHERNET_PORT

            // replica MAC table entries
            // replica 0
            RBB + 12'h100 + 0: reg_rd_data_next = replica_mac_lo[0]; // REPLICA_MAC_LO[0]
            RBB + 12'h100 + 4: reg_rd_data_next = replica_mac_hi[0]; // REPLICA_MAC_HI[0]
            // replica 1
            RBB + 12'h100 + 8: reg_rd_data_next = replica_mac_lo[1]; // REPLICA_MAC_LO[1]
            RBB + 12'h100 + 12: reg_rd_data_next = replica_mac_hi[1]; // REPLICA_MAC_HI[1]
            // replica 2
            RBB + 12'h100 + 16: reg_rd_data_next = replica_mac_lo[2]; // REPLICA_MAC_LO[2]
            RBB + 12'h100 + 20: reg_rd_data_next = replica_mac_hi[2]; // REPLICA_MAC_HI[2]
            // replica 3
            RBB + 12'h100 + 24: reg_rd_data_next = replica_mac_lo[3]; // REPLICA_MAC_LO[3]
            RBB + 12'h100 + 28: reg_rd_data_next = replica_mac_hi[3]; // REPLICA_MAC_HI[3]
            // replica 4
            RBB + 12'h100 + 32: reg_rd_data_next = replica_mac_lo[4]; // REPLICA_MAC_LO[4]
            RBB + 12'h100 + 36: reg_rd_data_next = replica_mac_hi[4]; // REPLICA_MAC_HI[4]
            // replica 5
            RBB + 12'h100 + 40: reg_rd_data_next = replica_mac_lo[5]; // REPLICA_MAC_LO[5]
            RBB + 12'h100 + 44: reg_rd_data_next = replica_mac_hi[5]; // REPLICA_MAC_HI[5]
            // replica 6
            RBB + 12'h100 + 48: reg_rd_data_next = replica_mac_lo[6]; // REPLICA_MAC_LO[6]
            RBB + 12'h100 + 52: reg_rd_data_next = replica_mac_hi[6]; // REPLICA_MAC_HI[6]
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
        reg_wr_ack_reg <= 1'b0;
        reg_rd_data_reg <= 0;
        reg_rd_ack_reg <= 1'b0;
        control_reg <= 0;
        //status_reg <= 0;
        error_reg <= 0;
        scratch_reg <= 0;
        replica_id_reg <= 0;
        replica_num_reg <= 0;
        round_length_ns_reg <= 0;
        ethernet_port_reg <= 0;
        for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
            replica_mac_lo[i] <= 0;
            replica_mac_hi[i] <= 0;

        end
    end else begin
        reg_wr_ack_reg <= reg_wr_ack_next;
        reg_rd_data_reg <= reg_rd_data_next;
        reg_rd_ack_reg <= reg_rd_ack_next;
        control_reg <= control_reg_next;
        //status_reg <= status_reg_next;
        error_reg <= error_reg_next;
        scratch_reg <= scratch_reg_next;
        replica_id_reg <= replica_id_reg_next;
        replica_num_reg <= replica_num_reg_next;
        round_length_ns_reg <= round_length_ns_reg_next;
        ethernet_port_reg <= ethernet_port_reg_next;
        for (i = 0; i < MAX_REPLICAS; i = i + 1) begin
            replica_mac_lo[i] <= replica_mac_lo_next[i];
            replica_mac_hi[i] <= replica_mac_hi_next[i];
        end
    end
end
endmodule

`resetall
