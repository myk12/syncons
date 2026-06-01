`timescale 1ns / 1ps

/*
 * Synchronous Consensus Core Module:
 *
 * Here we assume there is a synchronous distributed system with fixed time slots.
 * Each node sends and receives packets in its designated time slots.
 * Based on the assumptions, we implement a simple consensus core that processes
 * incoming packets and outputs data to the application layer.
 *
*/

module consensus_core #(
    parameter P_NODE_COUNT = 3,
    parameter P_NODE_ID = 0,
    parameter P_HEALTH_QUORUM = (P_NODE_COUNT / 2 + 1),
    parameter P_LOG_ITEM_LEN = 8,   // in bytes
    parameter P_DATA_WIDTH = 512,
    parameter P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter P_MEMBERSHIP_EPOCH_WIDTH = 64 // will change
) (
    // clock and reset
    input wire                                  clk,
    input wire                                  rst_n,

    // timing control interface (from scheduler )
    input wire [63:0]                           i_current_slot_id, // same as round_id
    input wire                                  i_new_slot_pulse,
    // input wire                                  i_commit_start_pulse,
    // input wire                                  i_slot_end_pulse,

    // data interface
    input wire                                  i_rx_valid,
    input wire [7:0]                            i_rx_node_id,
    input wire [7:0]                            i_rx_sound_bitmap, // bitmap of who the sender node sees as alive
    input wire [P_LOG_ITEM_LEN*8-1:0]           i_rx_payload,
    input wire [63:0]                           i_rx_run_id,
    input wire [63:0]                           i_rx_round_id,

    // control plane
    input wire [P_MEMBERSHIP_EPOCH_WIDTH-1:0]   i_ctrl_membership_epoch,
    input wire [63:0]                           i_ctrl_run_id,
    input wire [P_NODE_COUNT-1:0]               i_ctrl_membership, // bitmap of current membership
    input wire                                  i_ctrl_activate, // signal to activate the consensus core (e.g., after configuration)
    input wire                                  i_ctrl_reboot, // signal to reboot the node
    input wire [P_LOG_ITEM_LEN*8-1:0]           i_ctrl_host_payload, // payload from host to be proposed


    // status outputs
    output reg [P_NODE_COUNT-1:0]               o_alive_mask,
    output reg                                  o_system_halt,   // high when system halts

    // data output
    output reg [P_NODE_COUNT-1:0]               o_tx_knowledge_vec,
    output wire [P_LOG_ITEM_LEN*8-1:0]          o_tx_propose,

    // application data output (committed logs)
    output reg [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]      o_commit_log,
    output reg [P_NODE_COUNT-1:0]                       o_commit_valid
);

typedef struct packed {
    reg [63:0] round_id;
    reg [P_NODE_COUNT-1:0] installed_membership;
    reg [P_MEMBERSHIP_EPOCH_WIDTH-1:0] membership_epoch;
    reg [P_NODE_COUNT-1:0] sound_bitmap;
    reg [P_LOG_ITEM_LEN*8-1:0] proposals [0:P_NODE_COUNT-1];
} s_curr;

typedef struct packed {
    reg [63:0] round_id;
    reg [P_NODE_COUNT-1:0] installed_membership;
    reg [P_MEMBERSHIP_EPOCH_WIDTH-1:0] membership_epoch;
    reg [P_NODE_COUNT-1:0] sound_bitmap;
    reg [P_LOG_ITEM_LEN*8-1:0] proposals [0:P_NODE_COUNT-1];
    reg [P_NODE_COUNT-1:0] sound_matrix [0:P_NODE_COUNT-1];
} s_ev;

typedef struct packed {
    reg [63:0] round_id;
    reg [P_NODE_COUNT-1:0] installed_membership;
    reg [P_MEMBERSHIP_EPOCH_WIDTH-1:0] membership_epoch;
    reg [P_NODE_COUNT-1:0] sound_bitmap;
    reg [P_LOG_ITEM_LEN*8-1:0] proposals [0:P_NODE_COUNT-1];
    reg [P_NODE_COUNT-1:0] sound_matrix [0:P_NODE_COUNT-1];
} s_com;

s_curr  stage_curr;
s_ev    stage_evidence;
s_com   stage_commit;

//------------------------------------------------
//         State Machine for Consensus Processing
//------------------------------------------------
localparam S_IDLE           = 2'b00;
localparam S_COLLECT        = 2'b01;
localparam S_HALT           = 2'b10;

reg [1:0]   state, next_state;
//------------------------------------------------
//         Internal Storage (Buffer)
//------------------------------------------------
// global status of each node
reg [P_NODE_COUNT-1:0]          r_alive_mask;                           // alive mask
reg [P_NODE_COUNT-1:0]          r_sound_matrix [0:P_NODE_COUNT-1];  // sound matrix
reg [P_NODE_COUNT-1:0]          r_rx_mask;
reg [P_NODE_COUNT-1:0]          r_last_rx_mask;     // This is my own knowledge vector
reg [P_NODE_COUNT-1:0]          r_sound_bitmap;                           // derived sound bitmap based on received packets
reg [P_NODE_COUNT-1:0]          r_current_sound_set;                     // current sound set based on received packets

// config regs that come from the control plane at the start of each run
reg [63:0] config_run_id;
reg [P_NODE_COUNT-1:0] config_installed_membership; // bitmap of installed membership

// logs in this slot
reg [P_LOG_ITEM_LEN*8-1:0]      r_propose_log [0:P_NODE_COUNT-1];       // proposed logs
reg [P_LOG_ITEM_LEN*8-1:0]      r_commit_log [0:P_NODE_COUNT-1];        // acknowledged logs
// reg [P_NODE_COUNT-1:0]         r_consensus_reached;                    // consensus reached for each node
reg [7:0]                       r_rx_number;                            // number of received packets


// boundary evaluation wires
wire [P_NODE_COUNT-1:0]         derived_sound_set;
wire [P_NODE_COUNT-1:0]         commit_set;

wire [P_NODE_COUNT-1:0] row_matches; // which nodes' proposals match the commit set
wire [2:0] witness_count;
wire agreed_row_valid;

wire [P_NODE_COUNT-1:0] proprosal_present;
wire commit_set_valid;

wire [2:0]                      membership_count;
wire [2:0]                      quorum;

wire halt;

// propose padding with NODE_ID
assign o_tx_propose = {P_LOG_ITEM_LEN{P_NODE_ID[7:0]}};

// global loop variables
integer i, j, k;

// ------------------------------------------------
//              3. combinational logic
// ------------------------------------------------

function [7:0] count_ones;
    input [P_NODE_COUNT-1:0] vec;
    integer idx;
    begin
        count_ones = 0;
        for (idx = 0; idx < P_NODE_COUNT; idx = idx + 1) begin
            if (vec[idx]) begin
                count_ones = count_ones + 1;
            end
        end
    end
endfunction

// ------------------------------------------------
//  FSM PART 1: state register update (sequential)
// ------------------------------------------------

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
    end else begin
        state <= next_state;
    end
end

// ------------------------------------------------
//  FSM PART 2: next state logic and outputs (combinational)
// ------------------------------------------------
always @(*) begin
    // default assignments
    next_state = state;

    case (state)
        S_IDLE:     if (i_ctrl_activate)        next_state = S_COLLECT;
        S_COLLECT: begin
            if (round_boundary && !halt)        next_state = S_BOUNDARY;
            else if (round_boundary && halt)    next_state = S_FAIL_DETECT;
        end
        S_HALT: if (i_ctrl_reboot)              next_state = S_IDLE;
    endcase
end

// -------------------------
// Round start detector
// -------------------------
reg last_slot_pulse;
wire round_boundary;

always @(posedge clk, negedge rst_n) begin
    if (!rst_n) last_slot_pulse <= 1'b0;
    else last_slot_pulse <= i_new_slot_pulse;
end

assign round_boundary = last_slot_pulse == i_new_slot_pulse ? 1'b0 : 1'b1;

// -------------------------
// Clocked registers for stages
// -------------------------

always @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
        stage_curr <= '0;
        stage_evidence <= '0;
        stage_commit <= '0;
        o_system_halt <= 1'b0;
    end else begin
        case (state)
            S_IDLE: if (i_ctrl_activate) begin
                config_run_id                   <= i_ctrl_run_id;
                config_installed_membership     <= i_ctrl_membership;
                o_system_halt <= 1'b0;
                r_current_sound_set             <= i_ctrl_membership; // initialize sound set to membership at start

                stage_curr.round_id             <= i_current_slot_id;
                stage_curr.installed_membership <= i_ctrl_membership;
                stage_curr.membership_epoch     <= i_ctrl_membership_epoch;
                stage_curr.sound_bitmap         <= 1 << P_NODE_ID;
                stage_curr.proposals[P_NODE_ID] <= i_ctrl_host_payload;
                
                for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    if (i != P_NODE_ID)
                        stage_curr.proposals[i] <= 0;
                end
            end

            S_COLLECT: begin
                if (i_rx_valid && !round_boundary) begin
                    if (i_rx_run_id == config_run_id && i_rx_round_id == stage_curr.round_id && config_installed_membership[i_rx_node_id]) begin
                        stage_curr.proposals[i_rx_node_id] <= i_rx_payload;
                        stage_curr.sound_bitmap[i_rx_node_id] <= 1'b1;
                        stage_evidence.sound_matrix[i_rx_node_id] <= i_rx_sound_bitmap;
                    end
                end
                
                if (round_boundary) begin
                    stage_commit <= stage_evidence;

                    stage_evidence.round_id <= stage_curr.round_id;
                    stage_evidence.installed_membership <= stage_curr.installed_membership;
                    stage_evidence.membership_epoch <= stage_curr.membership_epoch;
                    stage_evidence.sound_bitmap <= derived_sound_set;
                    stage_evidence.proposals <= stage_curr.proposals;
                    stage_evidence.sound_matrix[P_NODE_ID] <= derived_sound_set;
                    
                    r_current_sound_set <= derived_sound_set; // update current sound set for next round

                    stage_curr.round_id <= stage_curr.round_id + 1; // move to next round
                    stage_curr.installed_membership <= derived_sound_set; 
                    stage_curr.sound_bitmap <= 1 << P_NODE_ID; // reset sound bitmap to only self for next round
                    stage_curr.proposals[P_NODE_ID] <= i_ctrl_host_payload; // reset proposals to host payload for next round
                    for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                        if (i != P_NODE_ID)
                            stage_curr.proposals[i] <= 0;
                    end


                    if (commit_set_valid) begin
                        for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                            if (commit_set[i]) begin
                                o_commit_log[i*P_LOG_ITEM_LEN*8 +: P_LOG_ITEM_LEN*8] <= stage_commit.proposals[i];
                                o_commit_valid[i] <= 1'b1;
                            end else begin
                                o_commit_valid[i] <= 1'b0;
                            end
                        end
                    end else begin
                        o_commit_valid <= {P_NODE_COUNT{1'b0}};    
                    end
                end

                if (halt) begin
                    stage_curr <= '0;
                    stage_evidence <= '0;
                    stage_commit <= '0;
                    o_system_halt <= 1'b1;
                end
            end

            S_HALT: begin
                o_system_halt <= 1'b1;
            end
        endcase
    end
end

// -------------------------
// Combinational logic for round boundary evaluation
// -------------------------
assign membership_count = count_ones(stage_commit.installed_membership);
assign quorum = (membership_count >> 1) + 1;

genvar k;
generate
    for (k = 0; k < P_NODE_COUNT; k = k + 1) begin : cons_check
        assign row_matches[k] = (stage_commit.installed_membership[k] && (stage_commit.sound_matrix[k] == stage_commit.sound_bitmap));
    end
endgenerate

assign witness_count = count_ones(row_matches);
assign agreed_row_valid = witness_count >= quorum;

assign derived_sound_set = agreed_row_valid ? row_matches : {P_NODE_COUNT{1'b0}};

genvar j;
generate
    for (j = 0; j < P_NODE_COUNT; j = j + 1) begin
        assign proprosal_present[j] = |stage_commit.proposals[j];
    end
endgenerate

assign commit_set_valid = agreed_row_valid && (stage_commit.sound_bitmap & proprosal_present) == stage_commit.sound_bitmap;
assign commit_set = commit_set_valid ? (stage_commit.sound_bitmap) : {P_NODE_COUNT{1'b0}};

assign halt = (!agreed_row_valid) || (!(|commit_set)) || (!derived_sound_set[P_NODE_ID]) || ((derived_sound_set & r_current_sound_set) != derived_sound_set);

endmodule