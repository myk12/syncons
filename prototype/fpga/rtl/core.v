`resetall
`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------
//              Register Map
// ------------------------------------------------
// --- Identity and Configuration Registers
//  - 0x000 MAGIC           RO "cons" = 0x636F6E73
//  - 0x004 VERSION         RO 0x00000100
//  - 0x008 FEATURES        RO
//  - 0x00C CONTROL         RW bit 0: enable (level)
//                             bit 1: activate (write-1-pulse)
//                             bit 2: reboot   (write-1-pulse)
//  - 0x010 STATUS          RO bit 0: system halt
//                             bit 1: timing armed
//                             bit 2: ptp time valid
//                             bit 3: activation pending
//                             bit 4: last activation was rejected because the
//                                    named membership does not include this
//                                    node (cleared by the next reboot)
//  - 0x014 ROUND_LENGTH_NS    RO (compiled-in; software reads it to learn the geometry)
//  - 0x018 REPLICA_ID         RO
//  - 0x01C REPLICA_COUNT      RO
//
// --- Control plane configuration registers
//  - 0x100 CONFIG_RUN_ID        RW
//  - 0x104 CONFIG_MEMBERSHIP    RW
//  - 0x108 CONFIG_EFFECTIVE_ROUND_LOW  RW
//  - 0x10C CONFIG_EFFECTIVE_ROUND_HIGH  RW
//
// --- Runtime status registers
//  - 0x110 CURRENT_ROUND_ID_LOW     RO
//  - 0x114 CURRENT_ROUND_ID_HIGH     RO
//  - 0x118 CURRENT_RUN_ID          RO
//  - 0x11C CURRENT_SOUND_SET       RO
//  - 0x120 INSTALLED_MEMBERSHIP    RO the membership the control plane installed.
//                                     Constant for a whole run - it is the sound
//                                     set that shrinks, not this.
//
// --- Halt
//  - 0x200 HALT_REASON         RO 0 none
//                                 1 no agreed row
//                                 2 commit set not valid (a member of the
//                                   agreed row never delivered its proposal)
//                                 3 no sound set
//                                 4 local node excluded from the sound set
//                                 5 sound set not a subset of the previous one
//                                 6 timing fault (PTP step / backward / unlocked)
//  - 0x204 HALT_ROUND_LOW       RO round_id of the stage that failed, not the
//  - 0x208 HALT_ROUND_HIGH      RO round in which the failure was detected
//  - 0x20C HALT_SELF_ROW       RO this node's own row in the failed evaluation
//  - 0x210 HALT_MEMBERSHIP     RO membership the failed stage was evaluated under
//  - 0x214 HALT_SOUND_SET      RO [7:0] sound set the evaluation produced
//                                 [15:8] sound set held before the evaluation
//  - 0x218 HALT_ROWS_LOW       RO observation matrix at the halt, nodes 0..3,
//  - 0x21C HALT_ROWS_HIGH      RO one byte per node, nodes 4..7. This is what
//                                 tells the control plane WHICH peer diverged
//                                 rather than merely that someone did.
//
// --- statistics
//  - 0x300 ROUND_COUNT_LOW      RO
//  - 0x304 ROUND_COUNT_HIGH      RO
//  - 0x308 TIME_FAULT_COUNT    RO
//  - 0x30C COMMIT_COUNT_LOW     RO rounds committed. Round count advancing while
//  - 0x310 COMMIT_COUNT_HIGH    RO this stands still is a stall - a node that is
//                                  alive and agreeing but making no progress.
//  - 0x314 HALT_COUNT          RO halts since reset; counts reboot thrash


module consensus_core #(
    parameter integer P_NODE_COUNT = 3,
    parameter integer P_NODE_ID = 0,

    // CSR parameters
    parameter integer REG_ADDR_WIDTH = 24,
    parameter integer REG_DATA_WIDTH = 32,
    parameter integer REG_STRB_WIDTH = REG_DATA_WIDTH/8,
    parameter [23:0]  RB_BASE_ADDR  = 24'h003000,

    // Timing
    parameter integer ROUND_LENGTH_NS  = 4000,
    parameter integer GUARD_TIME_NS      = 200, // guard time in ns
    parameter integer TX_SUBSLOT_NS    = 400,
    parameter integer TX_ADMIT_MARGIN_NS = 100
) (
    input wire                              clk,
    input wire                              rst,
    input wire                              i_enable,

    // PTP timestamp interface
    input wire [47:0]                       i_ptp_tod_sec,
    input wire [31:0]                       i_ptp_tod_ns,
    input wire                              i_ptp_time_valid,
    input wire                              i_ptp_step,

    // CSR interface
    input wire [REG_ADDR_WIDTH-1:0]         reg_wr_addr,
    input wire [REG_DATA_WIDTH-1:0]         reg_wr_data,
    input wire [REG_STRB_WIDTH-1:0]         reg_wr_strb,
    input wire                              reg_wr_en,
    output wire                             reg_wr_wait,
    output wire                             reg_wr_ack,
    input wire [REG_ADDR_WIDTH-1:0]         reg_rd_addr,
    input wire                              reg_rd_en,
    output wire [REG_DATA_WIDTH-1:0]        reg_rd_data,
    output wire                             reg_rd_wait,
    output wire                             reg_rd_ack,

    // Timing signals
    output wire [63:0]                      o_round_id,
    output wire                             o_round_start_pulse,
    output wire                             o_round_boundary_pulse,
    output wire                             o_tx_start_pulse,
    output wire                             o_tx_end_pulse,
    output wire                             o_tx_window,
    output wire                             o_rx_start_pulse,
    output wire                             o_rx_end_pulse,
    output wire                             o_rx_window,

    output reg [63:0]                       o_tx_round_id,
    output reg [31:0]                       o_tx_run_id,
    output reg [7:0]                        o_tx_row,

    // RX row evidence
    input wire                              i_rx_valid,
    input wire [7:0]                        i_rx_node_id,
    input wire [7:0]                        i_rx_row,
    input wire [31:0]                       i_rx_run_id,
    input wire [63:0]                       i_rx_round_id,

    // The verdict on the packet presented this cycle. rx_engine gates its ring
    // write on this rather than re-deriving the rule: reproducing it there would
    // mean exporting the sound set, the run id, the current round and the FSM
    // state, and then keeping two copies of the rule in step forever. One
    // arbiter, one wire.
    output wire                             o_rx_accepted,

    output reg                              o_commit_valid,
    output reg [63:0]                       o_commit_round_id,
    output reg [7:0]                        o_commit_set,

    output wire                             o_halt,
    output wire                             o_time_fault,
    output wire [31:0]                      o_time_fault_count
);

localparam integer ROUNDS_PER_SECOND  = 1_000_000_000 / ROUND_LENGTH_NS;
localparam integer TX_START_OFFSET_NS = GUARD_TIME_NS + P_NODE_ID * TX_SUBSLOT_NS;
localparam integer TX_END_OFFSET_NS   = TX_START_OFFSET_NS + TX_SUBSLOT_NS;
localparam integer TX_ADMIT_OFFSET_NS = TX_END_OFFSET_NS - TX_ADMIT_MARGIN_NS;
localparam integer RX_START_OFFSET_NS = GUARD_TIME_NS;
localparam integer RX_END_OFFSET_NS   = ROUND_LENGTH_NS - GUARD_TIME_NS;

initial begin
    if (1_000_000_000 % ROUND_LENGTH_NS != 0) begin
        $error("ROUND_LENGTH_NS (%0d) must divide 1e9 evenly, otherwise every second ends with a short round and TDMA sub-slots may not fit", ROUND_LENGTH_NS);
        $finish;
    end

    if (GUARD_TIME_NS + P_NODE_COUNT * TX_SUBSLOT_NS >= ROUND_LENGTH_NS) begin
        $error("TDMA sub-slots do not fit in the round length, please adjust GUARD_TIME_NS and TX_SUBSLOT_NS");
        $finish;
    end

    if (TX_ADMIT_MARGIN_NS >= TX_SUBSLOT_NS) begin
        $error("TX_ADMIT_MARGIN_NS (%0d) must be smaller than TX_SUBSLOT_NS (%0d)", TX_ADMIT_MARGIN_NS, TX_SUBSLOT_NS);
        $finish;
    end

    if (P_NODE_ID >= P_NODE_COUNT) begin
        $error("P_NODE_ID (%0d) must be smaller than P_NODE_COUNT (%0d)", P_NODE_ID, P_NODE_COUNT);
        $finish;
    end

    if (P_NODE_COUNT > 8) begin
        $error("P_NODE_COUNT (%0d) exceeds 8; the sound-set bitmap ports are 8 bits wide", P_NODE_COUNT);
        $finish;
    end
end

// ================================================================
//              SECTION 1:  CSR Interface
// ================================================================
localparam [31:0] CORE_MAGIC    = 32'h636F6E73;  // "cons"
localparam [31:0] CORE_VERSION  = 32'h00000100;
localparam [31:0] CORE_FEATURES = 32'h00000001;

localparam [REG_ADDR_WIDTH-1:0] REG_MAGIC                       = RB_BASE_ADDR + 24'h000;
localparam [REG_ADDR_WIDTH-1:0] REG_VERSION                     = RB_BASE_ADDR + 24'h004;
localparam [REG_ADDR_WIDTH-1:0] REG_FEATURES                    = RB_BASE_ADDR + 24'h008;
localparam [REG_ADDR_WIDTH-1:0] REG_CONTROL                     = RB_BASE_ADDR + 24'h00C;
localparam [REG_ADDR_WIDTH-1:0] REG_STATUS                      = RB_BASE_ADDR + 24'h010;
localparam [REG_ADDR_WIDTH-1:0] REG_ROUND_LENGTH_NS             = RB_BASE_ADDR + 24'h014;
localparam [REG_ADDR_WIDTH-1:0] REG_REPLICA_ID                  = RB_BASE_ADDR + 24'h018;
localparam [REG_ADDR_WIDTH-1:0] REG_REPLICA_COUNT               = RB_BASE_ADDR + 24'h01C;

localparam [REG_ADDR_WIDTH-1:0] REG_CONFIG_RUN_ID               = RB_BASE_ADDR + 24'h100;
localparam [REG_ADDR_WIDTH-1:0] REG_CONFIG_MEMBERSHIP           = RB_BASE_ADDR + 24'h104;
localparam [REG_ADDR_WIDTH-1:0] REG_CONFIG_EFFECTIVE_ROUND_LOW  = RB_BASE_ADDR + 24'h108;
localparam [REG_ADDR_WIDTH-1:0] REG_CONFIG_EFFECTIVE_ROUND_HIGH = RB_BASE_ADDR + 24'h10C;

localparam [REG_ADDR_WIDTH-1:0] REG_CURRENT_ROUND_ID_LOW        = RB_BASE_ADDR + 24'h110;
localparam [REG_ADDR_WIDTH-1:0] REG_CURRENT_ROUND_ID_HIGH       = RB_BASE_ADDR + 24'h114;
localparam [REG_ADDR_WIDTH-1:0] REG_CURRENT_RUN_ID              = RB_BASE_ADDR + 24'h118;
localparam [REG_ADDR_WIDTH-1:0] REG_CURRENT_SOUND_SET           = RB_BASE_ADDR + 24'h11C;
localparam [REG_ADDR_WIDTH-1:0] REG_INSTALLED_MEMBERSHIP          = RB_BASE_ADDR + 24'h120;

localparam [REG_ADDR_WIDTH-1:0] REG_HALT_REASON                 = RB_BASE_ADDR + 24'h200;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_ROUND_LOW              = RB_BASE_ADDR + 24'h204;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_ROUND_HIGH             = RB_BASE_ADDR + 24'h208;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_SELF_ROW               = RB_BASE_ADDR + 24'h20C;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_MEMBERSHIP             = RB_BASE_ADDR + 24'h210;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_SOUND_SET              = RB_BASE_ADDR + 24'h214;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_ROWS_LOW               = RB_BASE_ADDR + 24'h218;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_ROWS_HIGH              = RB_BASE_ADDR + 24'h21C;

localparam [REG_ADDR_WIDTH-1:0] REG_ROUND_COUNT_LOW             = RB_BASE_ADDR + 24'h300;
localparam [REG_ADDR_WIDTH-1:0] REG_ROUND_COUNT_HIGH            = RB_BASE_ADDR + 24'h304;
localparam [REG_ADDR_WIDTH-1:0] REG_TIME_FAULT_COUNT            = RB_BASE_ADDR + 24'h308;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_COUNT_LOW            = RB_BASE_ADDR + 24'h30C;
localparam [REG_ADDR_WIDTH-1:0] REG_COMMIT_COUNT_HIGH           = RB_BASE_ADDR + 24'h310;
localparam [REG_ADDR_WIDTH-1:0] REG_HALT_COUNT                  = RB_BASE_ADDR + 24'h314;

reg                         reg_wr_ack_reg  = 1'b0, reg_wr_ack_next;
reg                         reg_rd_ack_reg  = 1'b0, reg_rd_ack_next;
reg [REG_DATA_WIDTH-1:0]    reg_rd_data_reg = {REG_DATA_WIDTH{1'b0}}, reg_rd_data_next;

// Control-plane owned configuration
reg         control_enable_reg      = 1'b0, control_enable_next;
reg [31:0]  config_run_id_reg       = 32'd0, config_run_id_next;
reg [31:0]  config_membership_reg   = 32'd0, config_membership_next;
reg [63:0]  config_effective_round_reg    = 64'd0, config_effective_round_next;

// Write-1-pulse commands, consumed by SECTION 3
reg         control_activate_pulse, control_reboot_pulse;
reg         activate_pending_reg = 1'b0, activate_pending_next;

// Forward declarations from SECTION 2 / 3
wire        timing_armed;
wire [63:0] current_round_id;
wire [31:0] time_fault_count;
wire [63:0] round_count;

// SECTION 3 state, published through the CUR_* registers
reg [31:0]  current_run_id_reg     = 32'd0;
reg [7:0]   current_sound_set_reg  = 8'd0;
reg [7:0]   installed_membership_reg = 8'd0;

// SECTION 3 consumes the activate request once round_id reaches the effective
// round; the CSR block clears activate_pending_reg when it sees this.
wire        protocol_activate_consumed;

// SECTION 4 halt record, published through the 0x200 register block
reg [3:0]   halt_reason_reg          = 4'd0;
reg [63:0]  halt_round_id_reg        = 64'd0;
reg [7:0]   halt_self_row_reg        = 8'd0;
reg [7:0]   halt_membership_reg      = 8'd0;
reg [7:0]   halt_sound_set_reg       = 8'd0;
reg [7:0]   halt_previous_sound_set_reg  = 8'd0;
reg [63:0]  halt_rows_reg            = 64'd0;   // one byte per member
reg [63:0]  commit_count_reg         = 64'd0;
reg [31:0]  halt_count_reg           = 32'd0;
// Set when an activation was consumed but the named config did not include this
// node. Without it that path is silent and looks identical to "never activated".
reg         config_excludes_self_reg = 1'b0;

assign reg_wr_wait = 1'b0;
assign reg_wr_ack  = reg_wr_ack_reg;
assign reg_rd_wait = 1'b0;
assign reg_rd_ack  = reg_rd_ack_reg;
assign reg_rd_data = reg_rd_data_reg;

always @* begin
    reg_wr_ack_next  = 1'b0;
    reg_rd_ack_next  = 1'b0;
    reg_rd_data_next = {REG_DATA_WIDTH{1'b0}};

    control_enable_next      = control_enable_reg;
    config_run_id_next       = config_run_id_reg;
    config_membership_next   = config_membership_reg;
    config_effective_round_next    = config_effective_round_reg;
    activate_pending_next = activate_pending_reg;

    control_activate_pulse = 1'b0;
    control_reboot_pulse   = 1'b0;

    // SECTION 3 has taken the activation; drop the request. Placed before the
    // write decode so that a software write landing on the very same cycle wins
    // - that write is a newer request, aimed at a later effective round.
    if (protocol_activate_consumed) activate_pending_next = 1'b0;

    // ------------------------------ write ------------------------------
    if (reg_wr_en && !reg_wr_ack_reg) begin
        reg_wr_ack_next = 1'b1;
        case ({reg_wr_addr[REG_ADDR_WIDTH-1:2], 2'b00})
            REG_MAGIC:         ; // read-only
            REG_VERSION:       ; // read-only
            REG_FEATURES:      ; // read-only
            REG_STATUS:        ; // read-only
            REG_ROUND_LENGTH_NS:  ; // read-only, compiled in
            REG_REPLICA_ID:    ; // read-only
            REG_REPLICA_COUNT: ; // read-only

            REG_CONTROL: begin
                control_enable_next    = reg_wr_data[0];
                control_activate_pulse = reg_wr_data[1];
                control_reboot_pulse   = reg_wr_data[2];
                // activate is a command, not a sticky level: latch the request and
                // let SECTION 3 consume it when round_id reaches CFG_EFF_ROUND.
                if (reg_wr_data[1]) activate_pending_next = 1'b1;
                if (reg_wr_data[2]) activate_pending_next = 1'b0;
            end

            // One rule for all four: a config may be rewritten freely until it is
            // ARMED, and never after. activate_pending_reg is the armed flag.
            //
            // This is what makes a 64-bit effective round safe to write as two
            // 32-bit halves: activation cannot fire before the CONTROL write
            // that arms it, so the torn intermediate value is never examined.
            // Gating on !control_enable_reg instead - as an earlier version did -
            // would also forbid staging a new config while the core is running,
            // which is exactly what live reconfiguration needs to do.
            REG_CONFIG_RUN_ID:               if (!activate_pending_reg) config_run_id_next                 = reg_wr_data;
            REG_CONFIG_MEMBERSHIP:           if (!activate_pending_reg) config_membership_next             = reg_wr_data;
            REG_CONFIG_EFFECTIVE_ROUND_LOW:  if (!activate_pending_reg) config_effective_round_next[31:0]  = reg_wr_data;
            REG_CONFIG_EFFECTIVE_ROUND_HIGH: if (!activate_pending_reg) config_effective_round_next[63:32] = reg_wr_data;

            default: reg_wr_ack_next = 1'b0;   // unmapped: do not acknowledge
        endcase
    end

    // ------------------------------ read -------------------------------
    if (reg_rd_en && !reg_rd_ack_reg) begin
        reg_rd_ack_next = 1'b1;
        case ({reg_rd_addr[REG_ADDR_WIDTH-1:2], 2'b00})
            REG_MAGIC:         reg_rd_data_next = CORE_MAGIC;
            REG_VERSION:       reg_rd_data_next = CORE_VERSION;
            REG_FEATURES:      reg_rd_data_next = CORE_FEATURES;
            REG_CONTROL:       reg_rd_data_next = {31'd0, control_enable_reg};
            REG_STATUS:        reg_rd_data_next = {27'd0,
                                                   config_excludes_self_reg, // bit 4
                                                   activate_pending_reg,   // bit 3
                                                   i_ptp_time_valid,            // bit 2
                                                   timing_armed,            // bit 1
                                                   o_halt};                // bit 0
            REG_ROUND_LENGTH_NS:  reg_rd_data_next = ROUND_LENGTH_NS;
            REG_REPLICA_ID:    reg_rd_data_next = P_NODE_ID;
            REG_REPLICA_COUNT: reg_rd_data_next = P_NODE_COUNT;

            REG_CONFIG_RUN_ID:       reg_rd_data_next = config_run_id_reg;
            REG_CONFIG_MEMBERSHIP:   reg_rd_data_next = config_membership_reg;
            REG_CONFIG_EFFECTIVE_ROUND_LOW: reg_rd_data_next = config_effective_round_reg[31:0];
            REG_CONFIG_EFFECTIVE_ROUND_HIGH: reg_rd_data_next = config_effective_round_reg[63:32];

            REG_CURRENT_ROUND_ID_LOW:  reg_rd_data_next = current_round_id[31:0];
            REG_CURRENT_ROUND_ID_HIGH:  reg_rd_data_next = current_round_id[63:32];
            REG_CURRENT_RUN_ID:       reg_rd_data_next = current_run_id_reg;
            REG_CURRENT_SOUND_SET:    reg_rd_data_next = {24'd0, current_sound_set_reg};
            REG_INSTALLED_MEMBERSHIP:   reg_rd_data_next = {24'd0, installed_membership_reg};

            REG_HALT_REASON:      reg_rd_data_next = {28'd0, halt_reason_reg};
            REG_HALT_ROUND_LOW:    reg_rd_data_next = halt_round_id_reg[31:0];
            REG_HALT_ROUND_HIGH:    reg_rd_data_next = halt_round_id_reg[63:32];
            REG_HALT_SELF_ROW:    reg_rd_data_next = {24'd0, halt_self_row_reg};
            REG_HALT_MEMBERSHIP:  reg_rd_data_next = {24'd0, halt_membership_reg};
            // [7:0] the sound set the failed evaluation produced,
            // [15:8] the one the node held going in - the pair is what makes a
            // "sound set grew" halt diagnosable.
            REG_HALT_SOUND_SET:   reg_rd_data_next = {16'd0, halt_previous_sound_set_reg, halt_sound_set_reg};
            REG_HALT_ROWS_LOW:    reg_rd_data_next = halt_rows_reg[31:0];
            REG_HALT_ROWS_HIGH:   reg_rd_data_next = halt_rows_reg[63:32];

            REG_ROUND_COUNT_LOW:   reg_rd_data_next = round_count[31:0];
            REG_ROUND_COUNT_HIGH:   reg_rd_data_next = round_count[63:32];
            REG_TIME_FAULT_COUNT: reg_rd_data_next = time_fault_count;
            REG_COMMIT_COUNT_LOW:  reg_rd_data_next = commit_count_reg[31:0];
            REG_COMMIT_COUNT_HIGH: reg_rd_data_next = commit_count_reg[63:32];
            REG_HALT_COUNT:       reg_rd_data_next = halt_count_reg;

            default: begin
                reg_rd_ack_next  = 1'b0;       // unmapped: do not acknowledge
                reg_rd_data_next = {REG_DATA_WIDTH{1'b0}};
            end
        endcase
    end
end

always @(posedge clk) begin
    reg_wr_ack_reg  <= reg_wr_ack_next;
    reg_rd_ack_reg  <= reg_rd_ack_next;
    reg_rd_data_reg <= reg_rd_data_next;

    control_enable_reg      <= control_enable_next;
    config_run_id_reg       <= config_run_id_next;
    config_membership_reg   <= config_membership_next;
    config_effective_round_reg    <= config_effective_round_next;
    activate_pending_reg <= activate_pending_next;

    if (rst) begin
        reg_wr_ack_reg       <= 1'b0;
        reg_rd_ack_reg       <= 1'b0;
        reg_rd_data_reg      <= {REG_DATA_WIDTH{1'b0}};
        control_enable_reg      <= 1'b0;
        config_run_id_reg       <= 32'd0;
        config_membership_reg   <= 32'd0;
        config_effective_round_reg    <= 64'd0;
        activate_pending_reg <= 1'b0;
    end
end

// ================================================================
//          SECTION 2: Timing and Round Generation
// ================================================================
//
//  round_id = sec * ROUNDS_PER_SECOND + ns / ROUND_LENGTH_NS
//
//  round_id is a pure function of absolute PTP time, therefore:
//    - every node agrees by construction, regardless of when it was enabled
//    - it is recomputed from the clock at every boundary, so it cannot drift
//      and PTP frequency adjustment (slew) is absorbed automatically
//    - a node that halts and reboots re-derives it without any resync protocol
//
//  ROUND_LENGTH_NS must divide 1e9 so that the second rollover coincides exactly
//  with a round boundary; otherwise every second ends with a short round and
//  the TDMA sub-slots may not fit inside it.
//
//  A PTP step, a loss of lock, or time moving backwards is treated as a fault:
//  the scheduler disarms and raises o_time_fault so the FSM can halt. Recovery
//  is deliberately NOT automatic - the control plane must re-activate with a
//  fresh run_id, otherwise the node would rejoin reusing round_ids it has
//  already spoken for.
// ================================================================
reg [47:0]      previous_second_reg = 48'd0;
reg             second_valid_reg = 1'b0;
reg             timing_armed_reg = 1'b0;
reg [63:0]      round_id_reg = 64'd0;
reg [31:0]      next_boundary_ns_reg = ROUND_LENGTH_NS;
reg [31:0]      round_base_ns_reg = 32'd0;
reg             round_start_pulse_reg = 1'b0;
reg [31:0]      time_fault_count_reg = 32'd0;
reg             time_fault_previous_reg = 1'b0;
reg [63:0]      round_count_reg = 64'd0;

wire timing_running = i_enable && control_enable_reg && i_ptp_time_valid;

// second counter: normal increment vs jump
wire second_changed     = second_valid_reg && (i_ptp_tod_sec != previous_second_reg);
wire second_advanced    = timing_running && second_changed && (i_ptp_tod_sec == previous_second_reg + 48'd1);
wire second_jumped      = timing_running && second_changed && (i_ptp_tod_sec != previous_second_reg + 48'd1);

// round boundary detection
wire round_boundary_hit = timing_running && timing_armed_reg && (i_ptp_tod_ns >= next_boundary_ns_reg);

// Time faults. i_ptp_step is Corundum's own "the timestamp was stepped" flag;
// the backward check is a belt-and-braces fallback.
wire time_moved_backward = timing_running && timing_armed_reg && (i_ptp_tod_ns < round_base_ns_reg) && !second_changed;
wire time_fault  = timing_running && (i_ptp_step || second_jumped || time_moved_backward);

// Second base. ROUNDS_PER_SECOND is a compile-time constant, so this is not a
// DSP multiply - the synthesiser expands it into shifted copies of the seconds
// field summed in a compressor tree (250000 = 0b11_1101_0000_1001_0000, seven
// set bits, so seven terms). That tree is the longest combinational path in
// this module.
//
// The two bases share one tree: (sec + 1) * RPS == sec * RPS + RPS, so the
// "next" base is the same tree followed by a constant add. That is the same
// depth the old form had (it needed a 48-bit increment *before* the tree), so
// this costs nothing in delay and saves a whole tree in area.
//
// TIMING: sec only changes once per second - 250,000,000 cycles at 250 MHz -
// so this path has enormous slack that the timing engine cannot see. If it ever
// fails timing, see syn/vivado/consensus_core.tcl; that file also documents the
// RTL precondition that must be satisfied before the constraint is enabled.
// Do NOT add pipeline stages here without reading the note at the arm branch.
wire [63:0] second_base = i_ptp_tod_sec * ROUNDS_PER_SECOND;

reg [63:0] current_second_base_reg  = 64'd0;
reg [63:0] next_second_base_reg = 64'd0;

always @(posedge clk) begin
    current_second_base_reg <= second_base;
    next_second_base_reg    <= second_base + ROUNDS_PER_SECOND;
end

// One-shot positioning at arm time. Constant division synthesises to a
// multiply-by-reciprocal; it is only consumed on the arming cycle.
wire [31:0] round_index_in_second_at_arm = i_ptp_tod_ns / ROUND_LENGTH_NS;

always @(posedge clk) begin
    previous_second_reg     <= i_ptp_tod_sec;
    second_valid_reg        <= 1'b1;
    round_start_pulse_reg   <= 1'b0;
    time_fault_previous_reg <= time_fault;

    if (rst) begin
        previous_second_reg     <= 48'd0;
        second_valid_reg    <= 1'b0;
        timing_armed_reg    <= 1'b0;
        round_id_reg        <= 64'd0;
        next_boundary_ns_reg    <= ROUND_LENGTH_NS;
        round_base_ns_reg       <= 32'd0;
        time_fault_count_reg    <= 32'd0;
        round_count_reg         <= 64'd0;
        time_fault_previous_reg <= 1'b0;
    end
    else if (!timing_running) begin
        timing_armed_reg    <= 1'b0;
        round_id_reg        <= 64'd0;
        next_boundary_ns_reg   <= ROUND_LENGTH_NS;
        round_base_ns_reg      <= 32'd0;
    end
    else if (time_fault) begin
        // Give up the current alignment. Count only the rising edge so a
        // sustained fault (e.g. loss of lock) does not inflate the counter.
        timing_armed_reg <= 1'b0;
        if (!time_fault_previous_reg) time_fault_count_reg <= time_fault_count_reg + 32'd1;
    end
    else if (!timing_armed_reg && !second_changed) begin
        // Align to absolute time immediately. The round we land in is a partial
        // one, so no round_start is emitted for it; the first pulse comes from
        // the next natural boundary.
        //
        // The !second_changed guard means "sec has been stable for at least one
        // cycle", which is exactly the latency of current_second_base_reg. This
        // pairing is load-bearing: any extra latency added to the second-base
        // path - a pipeline stage, or a multicycle constraint that lets the
        // register hold an unsettled value for N cycles - must be matched by
        // deepening this guard to "sec stable for >= that many cycles". Get it
        // wrong and arming picks up the previous second's base, putting round_id
        // off by ROUNDS_PER_SECOND, but only ever on the cycle after a rollover.
        //
        // next_second_base_reg needs no such guard: it is consumed on the
        // rollover cycle itself, and the value it holds there was computed from
        // a seconds field that had been stable for the whole preceding second.
        timing_armed_reg    <= 1'b1;
        round_id_reg        <= current_second_base_reg + {32'd0, round_index_in_second_at_arm};
        round_base_ns_reg    <=  round_index_in_second_at_arm * ROUND_LENGTH_NS;
        next_boundary_ns_reg <= (round_index_in_second_at_arm + 32'd1) * ROUND_LENGTH_NS;
    end
    else if (second_advanced) begin
        // Second rollover. Because ROUND_LENGTH_NS divides 1e9 this is also a round
        // boundary, so realigning here costs nothing and cancels any drift.
        round_id_reg        <= next_second_base_reg;
        round_base_ns_reg   <= 32'd0;
        next_boundary_ns_reg    <= ROUND_LENGTH_NS;
        round_start_pulse_reg   <= 1'b1;
        round_count_reg     <= round_count_reg + 64'd1;
    end
    else if (round_boundary_hit) begin
        round_id_reg            <= round_id_reg + 64'd1;
        round_base_ns_reg       <= next_boundary_ns_reg;
        next_boundary_ns_reg    <= next_boundary_ns_reg + ROUND_LENGTH_NS;
        round_start_pulse_reg   <= 1'b1;
        round_count_reg         <= round_count_reg + 64'd1;
    end
end

// ---------------- windows: offset -> level -> edge pulse ----------------
wire [31:0] round_offset_ns = i_ptp_tod_ns - round_base_ns_reg;

wire tx_window_active   = timing_armed_reg && (round_offset_ns >= TX_START_OFFSET_NS) && (round_offset_ns < TX_END_OFFSET_NS);
wire tx_admit_active    = timing_armed_reg && (round_offset_ns >= TX_START_OFFSET_NS) && (round_offset_ns < TX_ADMIT_OFFSET_NS);
wire rx_window_active   = timing_armed_reg && (round_offset_ns >= RX_START_OFFSET_NS) && (round_offset_ns < RX_END_OFFSET_NS);

reg tx_window_previous_reg = 1'b0, tx_admit_previous_reg = 1'b0, rx_window_previous_reg = 1'b0;
reg tx_start_pulse_reg = 1'b0, tx_end_pulse_reg = 1'b0;
reg rx_start_pulse_reg = 1'b0, rx_end_pulse_reg = 1'b0;

always @(posedge clk) begin
    if (rst || !timing_running) begin
        tx_window_previous_reg  <= 1'b0;
        tx_admit_previous_reg   <= 1'b0;
        rx_window_previous_reg  <= 1'b0;
        tx_start_pulse_reg      <= 1'b0;
        tx_end_pulse_reg        <= 1'b0;
        rx_start_pulse_reg      <= 1'b0;
        rx_end_pulse_reg        <= 1'b0;
    end else begin
        tx_window_previous_reg  <= tx_window_active;
        tx_admit_previous_reg   <= tx_admit_active;
        rx_window_previous_reg  <= rx_window_active;

        tx_start_pulse_reg <=  tx_window_active && !tx_window_previous_reg;
        tx_end_pulse_reg   <= !tx_window_active &&  tx_window_previous_reg;
        rx_start_pulse_reg <=  rx_window_active && !rx_window_previous_reg;
        rx_end_pulse_reg   <= !rx_window_active &&  rx_window_previous_reg;
    end
end

// Driven by the SECTION 3 FSM. Gates every protocol-visible output, so a halted
// or not-yet-activated node stays silent on the wire.
wire protocol_active;

assign timing_armed   = timing_armed_reg;
assign current_round_id    = round_id_reg;
assign time_fault_count = time_fault_count_reg;
assign round_count = round_count_reg;

assign o_round_id             = round_id_reg;
assign o_round_start_pulse    = round_start_pulse_reg;                      // pure timing
assign o_round_boundary_pulse = round_start_pulse_reg && protocol_active;   // protocol boundary
assign o_tx_start_pulse       = tx_start_pulse_reg   && protocol_active;
assign o_tx_end_pulse         = tx_end_pulse_reg;
// Admission gate, closes early on purpose. Also gated by protocol_active so a
// halted node's datapath is shut at the door; safe to drop mid-window because
// this is admission only - the tx engine never aborts a frame already in flight.
assign o_tx_window            = tx_admit_previous_reg && protocol_active;
// Gated with the window they bracket, so the receive datapath sees a consistent
// story: a node that is halted or not yet activated opens no window and emits
// no edges for one.
assign o_rx_start_pulse     = rx_start_pulse_reg && protocol_active;
assign o_rx_end_pulse       = rx_end_pulse_reg   && protocol_active;
assign o_rx_window          = rx_window_previous_reg && protocol_active;
assign o_time_fault         = time_fault;
assign o_time_fault_count   = time_fault_count_reg;

// ================================================================
//              SECTION 3:  Consensus Logic
// ================================================================
//
//  Two-round pipeline, mirroring Node.advance_round in sim/protocol/node.py.
//  A stage is one round's worth of evidence and lives through exactly two
//  communication rounds:
//
//    round N     as CURRENT   collects proposals: who sent me a packet for N.
//                             That same bitmap IS our observation row for N.
//    round N+1   as PREVIOUS  collects the peers' observation rows for round N,
//                             piggybacked on their round N+1 packets
//    boundary N+2             judged: commits or halts
//
//  Two rounds is the floor, not a tuning constant: a node cannot know whom it
//  heard in round N until N is over, and its peers cannot learn that until N+1.
//  The judgement itself is one cycle of combinational logic and lands inside the
//  guard band, ~GUARD_TIME_NS before anyone transmits, so it costs no round.
//  After activation this shows up as two boundaries that shift and skip before
//  the first real evaluation.
//
//  What travels in a round N+1 packet is the RAW OBSERVATION of round N - "these
//  are the peers I actually heard" - not the sound set the boundary derived. The
//  distinction is the whole safety argument: with raw observations, two nodes
//  agreeing on a row means they genuinely had identical reception, so quorum
//  intersection pins the committed set. Broadcasting the derived sound set
//  instead makes every node emit the same value even when their receptions
//  differed, which hides asymmetric loss from everyone except its victim.
//
//  At every round boundary the pipeline shifts one place and exactly one
//  evaluation runs. That single evaluation feeds all four consumers - the halt
//  decision, the sound-set update, the row we broadcast, and the commit output -
//  which is what the old consensus_core got wrong: it evaluated one stage for
//  the broadcast and a different one for the halt, so a node could halt on one
//  round's evidence while advertising another's.
//
//  Bitmaps are 8 bits wide throughout to match the ports; only the low
//  P_NODE_COUNT bits are ever populated.
// ================================================================

// Naming rule in this module: the "current_" prefix is reserved for state that
// changes every round - current_stage, current_sound_set. Anything that only
// moves when the control plane reconfigures carries "installed_" or "config_".
// Getting that wrong reads as a safety bug even when the logic is right, which
// is exactly what happened to installed_membership_reg when it was called
// current_membership_reg.
localparam integer N = P_NODE_COUNT;
localparam [7:0] MEMBER_MASK = (8'd1 << N) - 8'd1;

localparam [3:0] HALT_NONE              = 4'd0;
localparam [3:0] HALT_NO_AGREED_ROW     = 4'd1;
localparam [3:0] HALT_COMMIT_SET_INVALID= 4'd2;
localparam [3:0] HALT_NO_SOUND_SET      = 4'd3;
localparam [3:0] HALT_SELF_EXCLUDED     = 4'd4;
localparam [3:0] HALT_SOUND_SET_GREW    = 4'd5;
localparam [3:0] HALT_TIME_FAULT        = 4'd6;

localparam [1:0] S_IDLE          = 2'd0;   // disabled, or waiting for the timing to arm
localparam [1:0] S_WAIT_ACTIVATE = 2'd1;   // armed, waiting for round_id >= effective round
localparam [1:0] S_RUN           = 2'd2;   // participating
localparam [1:0] S_HALT          = 2'd3;   // ambiguity detected; silent until rebooted

reg [1:0] state_reg = S_IDLE;

// ------------------ pipeline registers ------------------

reg [63:0] current_stage_round_id_reg  = 64'd0;
reg [63:0] previous_stage_round_id_reg = 64'd0;

reg        current_stage_valid_reg  = 1'b0;
reg        previous_stage_valid_reg = 1'b0;

reg [7:0]  current_stage_proposals_reg  = 8'd0;
reg [7:0]  previous_stage_proposals_reg = 8'd0;

reg [7:0]  previous_stage_rows_reg [0:7];

integer init_i;
initial begin
    for (init_i = 0; init_i < 8; init_i = init_i + 1)
        previous_stage_rows_reg[init_i] = 8'd0;
end

// ------------------ boundary evaluation ------------------
// Combinational, evaluated continuously; only sampled on a round boundary.
// There are ~GUARD_TIME_NS of slack between the boundary pulse and the earliest
// transmit, so there is no reason to pipeline this.
integer   eval_i;
reg [7:0] eval_row;
reg [7:0] eval_local_row;
reg [7:0] eval_witness_mask;
reg [3:0] eval_witness_count;
reg       eval_row_self_missing;

// Calculate the witness set and agreed row from the previous stage's rows. 
// - The witness set is the set of members whose row equals this node's own row, and 
// - the agreed row is this node's own row if a quorum of witnesses exists. 
// - The sound set is the witness set, and 
// - the commit set is the agreed row if all members of the agreed row have delivered their proposals.
always @* begin
    eval_row_self_missing = 1'b0;
    eval_witness_mask     = 8'd0;
    eval_witness_count    = 4'd0;

    // rows.get(self, 0): a node with no row reads as empty
    eval_local_row = current_sound_set_reg[P_NODE_ID]
                   ? previous_stage_rows_reg[P_NODE_ID] : 8'd0;

    // Scan only peers we still consider sound. Everyone else was already dropped
    // on the receive side, so their row is 0 and could never match a non-empty
    // local row anyway - but scanning explicitly means the witness set is
    // contained in the current sound set by construction of this loop, rather
    // than by an argument about what the receive path does.
    //
    // current_sound_set_reg decides WHOSE ROW TO READ here. It must never decide
    // how many rows are needed - that is QUORUM, and conflating the two is the
    // bug this module already shipped once.
    for (eval_i = 0; eval_i < N; eval_i = eval_i + 1) begin
        if (current_sound_set_reg[eval_i]) begin
            eval_row = previous_stage_rows_reg[eval_i];

            // A peer that claims a non-empty sound set must be inside it. A row
            // that fails this is self-contradictory and poisons the whole
            // evaluation - we cannot tell which part of it to believe.
            if (eval_row != 8'd0 && !eval_row[eval_i])
                eval_row_self_missing = 1'b1;

            if (eval_row == eval_local_row) begin
                eval_witness_mask  = eval_witness_mask | (8'd1 << eval_i);
                eval_witness_count = eval_witness_count + 4'd1;
            end
        end
    end
end

// nodes alive.
localparam integer QUORUM = (P_NODE_COUNT >> 1) + 1;

// The agreed row is this node's own row, once a quorum of members report a row
// identical to it.
wire       eval_agreed_row_valid = !eval_row_self_missing
                                && (eval_local_row != 8'd0)
                                && (eval_witness_count >= QUORUM[3:0]);
wire [7:0] eval_agreed_row = eval_local_row;

// The witnesses ARE the sound set: both are "members whose row equals the
// agreed row", so popcount(sound_set) == witness_count >= quorum by construction.
wire [7:0] eval_sound_set = eval_witness_mask;

// The agreed row may only be committed once every node it names has actually
// delivered its proposal. Missing this check is how a node commits a round
// whose payload it never received.
wire eval_commit_set_valid = eval_agreed_row_valid
                          && ((eval_agreed_row & ~previous_stage_proposals_reg) == 8'd0);

// The sound set may shrink but never grow: that monotonicity is what keeps two
// partitions from both believing they hold the agreement.
//
// Mind which of the two is newer. current_sound_set_reg is not written until the
// end of this boundary, so right here it still holds the value derived at the
// PREVIOUS boundary, while eval_sound_set is the newer of the two. The test
// therefore reads "new must be contained in old", despite the word "current"
// sitting on the right-hand side.
wire eval_sound_set_shrinks =
        ((eval_sound_set & current_sound_set_reg) == eval_sound_set);

reg [3:0] eval_halt_reason;
always @* begin
    if      (!eval_agreed_row_valid)                eval_halt_reason = HALT_NO_AGREED_ROW;
    else if (!eval_commit_set_valid)                eval_halt_reason = HALT_COMMIT_SET_INVALID;
    // The last three are defensive: none can fire once agreed_row_valid holds.
    //   NO_SOUND_SET   - a valid agreed row means our own row is non-empty and
    //                    we are inside the scan mask, so we witness ourselves
    //                    and the witness mask cannot be empty.
    //   SELF_EXCLUDED  - same argument, one step further.
    //   SOUND_SET_GREW - the witness mask is built by scanning
    //                    current_sound_set_reg, so it is a subset of it by
    //                    construction of the loop above.
    // They are kept so this block stays a line-by-line mirror of
    // _evaluate_round_boundary - which is what makes a co-simulation diff
    // against sim/ mean anything - and because an unreachable check costing a
    // handful of gates is worth having when the thing it guards is the safety
    // argument. Delete them only together with that mirror.
    else if (eval_sound_set == 8'd0)                eval_halt_reason = HALT_NO_SOUND_SET;
    else if (!eval_sound_set[P_NODE_ID])            eval_halt_reason = HALT_SELF_EXCLUDED;
    else if (!eval_sound_set_shrinks)               eval_halt_reason = HALT_SOUND_SET_GREW;
    else                                            eval_halt_reason = HALT_NONE;
end

wire eval_runs   = previous_stage_valid_reg;
wire eval_halts  = eval_runs && (eval_halt_reason != HALT_NONE);
wire eval_commits = eval_runs && (eval_halt_reason == HALT_NONE);

// ------------------------------------------------------------- activation
// Cold start and reconfiguration are the same event: wait until absolute time
// reaches the round the control plane named, then install and go.
// S_RUN is here too: a running node must be able to take a new membership at
// the round the control plane picked, without being stopped first. Requiring a
// stop would mean the cluster has to halt in order to reconfigure.
//
// S_HALT is deliberately absent. A halted node has to be rebooted before it can
// rejoin; letting an activation lift it straight out of S_HALT would be the
// automatic recovery this design rules out everywhere else.
wire activation_due = ((state_reg == S_WAIT_ACTIVATE) || (state_reg == S_RUN))
                   && activate_pending_reg
                   && (round_id_reg >= config_effective_round_reg);

// A config that does not name this node is not something to activate into; the
// node would have to halt on its first evaluation anyway.
wire activation_includes_self = config_membership_reg[P_NODE_ID];

// No cross-config overlap rule is needed: with a fixed quorum universe, a group
// that splits off under a new config and the group that stays under the old one
// draw their quorums from the same set, so at most one of them can ever reach
// quorum. A config too small to hold a quorum simply halts its own members.
wire activation_fires = activation_due && activation_includes_self;

assign protocol_activate_consumed = round_start_pulse_reg && activation_due;

// -------------------------------------------------------------- timing loss
// A step, a backward jump or a lost lock all mean the same thing: this node can
// no longer say which round it is in. Recovery is never automatic - the control
// plane must reactivate with a fresh run_id, otherwise the node rejoins reusing
// round_ids it has already spoken for.
wire timing_lost = time_fault || !i_ptp_time_valid;

// Software deliberately stopping us is a clean shutdown to S_IDLE. Note this is
// NOT !timing_running: that also covers !i_ptp_time_valid, which is a fault and
// must reach S_HALT instead. Folding the two together would turn every PTP
// unlock into a silent, auto-recovering restart.
wire protocol_stop = control_reboot_pulse || !i_enable || !control_enable_reg;

// ---------------------------------------------------------------- receive
// Node.receive: the sender must be inside our current sound set, the run must
// match, and the packet must belong to the round we are actually in.
//
// The src != self test has no counterpart in node.py, where routing makes it
// impossible. On a wire it is not: a packet claiming to come from us would
// overwrite our own row in the matrix, which is the one input the evaluation
// has to be able to trust.
wire        rx_node_in_range = (i_rx_node_id < N) && (i_rx_node_id != P_NODE_ID);
wire [2:0]  rx_index         = i_rx_node_id[2:0];
wire        rx_accept = i_rx_valid
                     && (state_reg == S_RUN)
                     && rx_node_in_range
                     && current_sound_set_reg[rx_index]
                     && (i_rx_run_id  == current_run_id_reg)
                     && (i_rx_round_id == round_id_reg);

// What goes on the wire is the raw observation accumulated over the round that
// just ended: "these are the peers I actually heard from". Under the current
// packet format a peer's proposal and its row arrive together, so "whose
// proposal I hold" and "whom I heard from" are the same bitmap - they separate
// only once the RX datapath reports payload landing independently of header
// parsing. Name the wire-visible meaning now so that split stays easy.
wire [7:0]  current_stage_row = current_stage_proposals_reg;

// --------------------------------------------------------------- sequential
integer shift_i;

always @(posedge clk) begin
    o_commit_valid <= 1'b0;

    // ---- packet arrival -------------------------------------------------
    // ONE packet feeds TWO different stages. A round-N packet carries the
    // sender's proposal for round N, and separately its observation of round
    // N-1. So the proposal bit lands in CURRENT while the row lands in
    // PREVIOUS. Getting this split wrong shifts the whole protocol by a round.
    if (rx_accept) begin
        current_stage_proposals_reg <= current_stage_proposals_reg | (8'd1 << rx_index);
        previous_stage_rows_reg[rx_index] <= i_rx_row & MEMBER_MASK;
    end

    // ---- round boundary -------------------------------------------------
    // Written after the receive block on purpose: a packet landing exactly on
    // the boundary cycle is ambiguous about which round it belongs to, so the
    // shift overwrites it and the packet is dropped. RX is gated to the receive
    // window anyway, which is GUARD_TIME_NS clear of both edges.
    if (round_start_pulse_reg) begin
        // Activation is checked ahead of the state machine so there is exactly
        // one install site, reachable from both S_WAIT_ACTIVATE (cold start) and
        // S_RUN (live reconfiguration). It takes priority over the boundary
        // evaluation below: evidence gathered under the outgoing config must not
        // be judged under the incoming one.
        if (activation_fires) begin
            current_run_id_reg      <= config_run_id_reg;
            installed_membership_reg <= config_membership_reg[7:0] & MEMBER_MASK;
            current_sound_set_reg  <= config_membership_reg[7:0] & MEMBER_MASK;

            // Reset the pipeline: nothing from before this config may be
            // evaluated under it. Costs the usual two priming rounds.
            previous_stage_valid_reg <= 1'b0;
            current_stage_valid_reg  <= 1'b1;
            current_stage_round_id_reg   <= round_id_reg;
            current_stage_proposals_reg  <= (8'd1 << P_NODE_ID);
            for (shift_i = 0; shift_i < 8; shift_i = shift_i + 1)
                previous_stage_rows_reg[shift_i] <= 8'd0;

            o_tx_round_id  <= round_id_reg;
            o_tx_run_id    <= config_run_id_reg;
            // No round has been observed yet under this config, so the honest
            // row is "only myself". Peers discard it anyway: their PREVIOUS
            // stage is invalid on the activation round too.
            o_tx_row <= (8'd1 << P_NODE_ID);

            config_excludes_self_reg <= 1'b0;
            state_reg <= S_RUN;
        end
        else if (activation_due) begin
            // Named config excludes this node: swallow the request and go quiet
            // rather than activating into a certain halt. Flagged in STATUS so
            // this is distinguishable from "never activated".
            config_excludes_self_reg <= 1'b1;
            state_reg <= S_IDLE;
        end
        else begin
        case (state_reg)
            S_IDLE: begin
                if (activate_pending_reg) state_reg <= S_WAIT_ACTIVATE;
            end

            S_WAIT_ACTIVATE: ;   // waiting for round_id to reach the effective round

            S_RUN: begin
                // The eval_* wires above are reading the pre-shift PREVIOUS
                // registers right now; this shift retires that stage and
                // installs CURRENT in its place.
                previous_stage_valid_reg      <= current_stage_valid_reg;
                previous_stage_round_id_reg   <= current_stage_round_id_reg;
                previous_stage_proposals_reg  <= current_stage_proposals_reg;
                for (shift_i = 0; shift_i < 8; shift_i = shift_i + 1)
                    previous_stage_rows_reg[shift_i] <= 8'd0;

                if (eval_halts) begin
                    state_reg      <= S_HALT;
                    halt_count_reg <= halt_count_reg + 32'd1;

                    // Freeze the whole observation matrix. By the time software
                    // reads it the pipeline has shifted several times over, and
                    // the rows are the only record of who actually diverged.
                    for (shift_i = 0; shift_i < 8; shift_i = shift_i + 1)
                        halt_rows_reg[shift_i*8 +: 8] <= previous_stage_rows_reg[shift_i];

                    halt_reason_reg         <= eval_halt_reason;
                    halt_round_id_reg       <= previous_stage_round_id_reg;
                    halt_self_row_reg       <= eval_local_row;
                    halt_membership_reg     <= installed_membership_reg;
                    halt_sound_set_reg      <= eval_sound_set;
                    halt_previous_sound_set_reg <= current_sound_set_reg;
                end else begin
                    if (eval_commits) begin
                        current_sound_set_reg <= eval_sound_set;
                        commit_count_reg      <= commit_count_reg + 64'd1;

                        o_commit_valid    <= 1'b1;
                        o_commit_round_id <= previous_stage_round_id_reg;
                        o_commit_set      <= eval_agreed_row;
                    end

                    // The row we advertise, and file as our own entry in the
                    // stage that has just become PREVIOUS, is the observation
                    // accumulated during that stage's own round - NOT the sound
                    // set this boundary just derived.
                    //
                    // Broadcasting the derived sound set would make every node
                    // emit the same value even when their receptions differed,
                    // so asymmetric loss stays invisible to everyone but its
                    // victim, and the majority halts while the faulty node runs
                    // on alone. The raw observation puts the disagreement in the
                    // matrix where a quorum can see it and name who diverged.
                    previous_stage_rows_reg[P_NODE_ID] <= current_stage_row;

                    o_tx_round_id  <= round_id_reg;
                    o_tx_run_id    <= current_run_id_reg;
                    o_tx_row <= current_stage_row;

                    // Open a fresh CURRENT for the round we are entering.
                    // Seeding proposals with our own bit assumes the local
                    // proposal always exists, which is what node.py does. Real
                    // hardware can have an empty proposal slot; when the TX
                    // datapath grows a "proposal available" output, it belongs
                    // here - claiming a proposal we never sent would let peers
                    // commit a round whose payload does not exist.
                    current_stage_valid_reg      <= 1'b1;
                    current_stage_round_id_reg   <= round_id_reg;
                    current_stage_proposals_reg  <= (8'd1 << P_NODE_ID);
                end
            end

            S_HALT: ;   // stay put; only a reboot leaves this state
        endcase
        end
    end

    // ---- asynchronous transitions --------------------------------------
    // Checked outside the boundary case so they take effect immediately rather
    // than waiting up to a full round.
    if (timing_lost && (state_reg == S_RUN)) begin
        state_reg               <= S_HALT;
        halt_count_reg          <= halt_count_reg + 32'd1;
        halt_reason_reg         <= HALT_TIME_FAULT;
        halt_round_id_reg       <= round_id_reg;
        halt_self_row_reg       <= 8'd0;
        halt_membership_reg     <= installed_membership_reg;
        halt_sound_set_reg      <= current_sound_set_reg;
        halt_previous_sound_set_reg <= current_sound_set_reg;
    end

    // Reboot is the control plane's way of saying "forget everything"; it
    // already cleared activate_pending in the CSR block.
    if (protocol_stop) begin
        state_reg              <= S_IDLE;
        current_stage_valid_reg  <= 1'b0;
        previous_stage_valid_reg <= 1'b0;
        o_tx_row         <= 8'd0;
        o_commit_valid         <= 1'b0;
    end

    if (control_reboot_pulse) begin
        halt_reason_reg        <= HALT_NONE;
        config_excludes_self_reg <= 1'b0;
        current_run_id_reg     <= 32'd0;
        current_sound_set_reg  <= 8'd0;
        installed_membership_reg <= 8'd0;
    end

    if (rst) begin
        state_reg              <= S_IDLE;
        o_tx_round_id          <= 64'd0;
        o_tx_run_id            <= 32'd0;
        o_tx_row         <= 8'd0;
        o_commit_valid         <= 1'b0;
        o_commit_round_id      <= 64'd0;
        o_commit_set           <= 8'd0;
        current_run_id_reg     <= 32'd0;
        current_sound_set_reg  <= 8'd0;
        installed_membership_reg <= 8'd0;

        current_stage_valid_reg  <= 1'b0;
        previous_stage_valid_reg <= 1'b0;
        current_stage_proposals_reg  <= 8'd0;
        previous_stage_proposals_reg <= 8'd0;

        halt_reason_reg         <= HALT_NONE;
        halt_round_id_reg       <= 64'd0;
        halt_self_row_reg       <= 8'd0;
        halt_membership_reg     <= 8'd0;
        halt_sound_set_reg      <= 8'd0;
        halt_previous_sound_set_reg <= 8'd0;
        halt_rows_reg           <= 64'd0;
        commit_count_reg        <= 64'd0;
        halt_count_reg          <= 32'd0;
        config_excludes_self_reg <= 1'b0;
    end
end

assign o_rx_accepted   = rx_accept;
assign protocol_active = (state_reg == S_RUN);
assign o_halt          = (state_reg == S_HALT);

// ================================================================
//  SECTION 4:           Halt Logic
// ================================================================
// The halt record is captured at the moment of the decision, above - by the
// time software gets round to reading it, the pipeline that produced it has
// already shifted away. It is published read-only through the 0x200 block and
// cleared only by a reboot.
//
// The record carries the full observation matrix at 0x218/0x21C, one byte per
// member, so the control plane can work out WHICH peer diverged rather than only
// that someone did: compare each row against the halting node's own row at
// 0x20C. What it does not carry is the proposals bitmap or any payload - the
// halt tells you who disagreed about membership, not what they disagreed about.
// Add that only if the repair path turns out to need it.

endmodule

`resetall
