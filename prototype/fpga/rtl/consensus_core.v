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
    parameter P_LOG_ITEM_LEN = 32,   // in bytes
    parameter P_DATA_WIDTH = 512,
    parameter P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter P_MEMBERSHIP_EPOCH_WIDTH = 64, // will change
    parameter P_SYS_CLOCK_FREQ_HZ = 250_000_000,  // 250 MHz
    parameter P_SLOT_DURATION_NS = 4000,  // 4 microseconds
    parameter P_GUARD_NS = 50,          // 50 nanoseconds
    parameter PTP_TS_FMT_TOD = 1,
    parameter PTP_TS_WIDTH = PTP_TS_FMT_TOD ? 96 : 64
) (
    // clock and reset
    input wire                                  clk,
    input wire                                  rst_n,

    // scheduler signals
    input wire                                  i_global_enable,
    input wire [PTP_TS_WIDTH-1:0]               ptp_sync_ts,
    
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
    // input wire [P_LOG_ITEM_LEN*8-1:0]           i_ctrl_host_payload, // payload from host to be proposed


    // status outputs
    // output reg [P_NODE_COUNT-1:0]               o_alive_mask,
    output reg                                  o_system_halt,   // high when system halts

    // data output
    output wire [P_NODE_COUNT-1:0]              o_tx_knowledge_vec,
    // output wire [P_LOG_ITEM_LEN*8-1:0]          o_tx_propose,

    // application data output (committed logs)
    // output reg [P_LOG_ITEM_LEN*8*P_NODE_COUNT-1:0]  o_commit_log,
    // output reg [P_NODE_COUNT-1:0]                   o_commit_valid,

    // transmit trigger
    output reg                                  o_tx_allowed,         // allow transmission
    output reg                                  o_rx_enabled,          // enable receiving
    output wire [63:0]                          o_current_round_id,     // current slot id, same as round id
    output wire [63:0]                          o_current_run_id       // current run id
);

// current stage
reg [63:0]                          s_curr_round_id;
reg [P_NODE_COUNT-1:0]              s_curr_installed_membership;
reg [P_MEMBERSHIP_EPOCH_WIDTH-1:0]  s_curr_membership_epoch;
reg [P_NODE_COUNT-1:0]              s_curr_sound_bitmap;
// reg [P_LOG_ITEM_LEN*8-1:0]          s_curr_proposals [0:P_NODE_COUNT-1];

// evidence stage
reg [63:0]                          s_evidence_round_id;
reg [P_NODE_COUNT-1:0]              s_evidence_installed_membership;
reg [P_MEMBERSHIP_EPOCH_WIDTH-1:0]  s_evidence_membership_epoch;
reg [P_NODE_COUNT-1:0]              s_evidence_sound_bitmap;
// reg [P_LOG_ITEM_LEN*8-1:0]          s_evidence_proposals [0:P_NODE_COUNT-1];
reg [P_NODE_COUNT-1:0]              s_evidence_sound_matrix [0:P_NODE_COUNT-1];

// commit stage
reg [63:0]                          s_commit_round_id;
reg [P_NODE_COUNT-1:0]              s_commit_installed_membership;
reg [P_MEMBERSHIP_EPOCH_WIDTH-1:0]  s_commit_membership_epoch;
reg [P_NODE_COUNT-1:0]              s_commit_sound_bitmap;
// reg [P_LOG_ITEM_LEN*8-1:0]          s_commit_proposals [0:P_NODE_COUNT-1];
reg [P_NODE_COUNT-1:0]              s_commit_sound_matrix [0:P_NODE_COUNT-1];

// scheduler signals
reg [63:0]  current_round_id; // same as round_id
reg         new_slot_pulse;

reg [PTP_TS_WIDTH-1:0] i_ptp_start_time_ns;
reg last_enable;

wire enable_rising_edge = i_global_enable && !last_enable;

reg [PTP_TS_WIDTH-1:0] r_next_boundary;
reg [63:0] r_slot_id_counter;
reg [PTP_TS_WIDTH-1:0] slot_offset;

localparam P_TX_START       = P_GUARD_NS + (P_NODE_ID * 200);
localparam P_TX_DONE        = P_GUARD_NS + (P_NODE_ID + 1) * 200; // each node gets 200ns slot


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
reg [P_NODE_COUNT-1:0]          r_current_sound_set;                     // current sound set based on received packets

// config regs that come from the control plane at the start of each run
reg [63:0] config_run_id;
reg [P_NODE_COUNT-1:0] config_installed_membership; // bitmap of installed membership

// logs in this slot
// reg [P_LOG_ITEM_LEN*8-1:0]      r_propose_log [0:P_NODE_COUNT-1];       // proposed logs
reg [P_LOG_ITEM_LEN*8-1:0]      r_commit_log [0:P_NODE_COUNT-1];        // acknowledged logs
// reg [P_NODE_COUNT-1:0]         r_consensus_reached;                    // consensus reached for each node
// reg [7:0]                       r_rx_number;                            // number of received packets

// boundary evaluation wires
wire [2:0]              membership_count;
wire [2:0]              quorum;

wire [P_NODE_COUNT-1:0] row_valid;
wire [P_NODE_COUNT-1:0] row_matches; // which nodes' proposals match the commit set
wire [2:0]              witness_count;
wire                    agreed_row_valid;
wire [P_NODE_COUNT-1:0] derived_sound_set;
wire [P_NODE_COUNT-1:0] commit_set;

// forwarded values
wire [2:0]              f_membership_count;
wire [2:0]              f_quorum;

wire [P_NODE_COUNT-1:0] f_row_valid;
wire [P_NODE_COUNT-1:0] f_row_matches; // which nodes' proposals match the commit set
wire [2:0]              f_witness_count;
wire                    f_agreed_row_valid;
wire [P_NODE_COUNT-1:0] f_derived_sound_set;
wire [P_NODE_COUNT-1:0] f_commit_set;

wire round_boundary;
reg [1:0] eval_counter;
reg activation_pending;

wire halt;

// propose padding with NODE_ID
// assign o_tx_propose = i_ctrl_host_payload;

// global loop variables
integer i, j;

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

// scheduler logic
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_next_boundary     <= ~0;  // no boundary until enabled
        r_slot_id_counter   <= 0;
        current_round_id     <= 0;
        new_slot_pulse      <= 0;
        last_enable         <= 0;
        
        o_tx_allowed        <= 0;
        o_rx_enabled        <= 0;
        slot_offset         <= 0;
    end else begin
        last_enable    <= i_global_enable;
        new_slot_pulse <= 0;  // default: no pulse

        if (!i_global_enable) begin
            r_next_boundary     <= ~0;
            r_slot_id_counter   <= 0;
            current_round_id     <= 0;
            o_tx_allowed        <= 0;
            o_rx_enabled        <= 0;
        end else if (enable_rising_edge) begin
            r_next_boundary <= ptp_sync_ts + P_SLOT_DURATION_NS;  // next slot after now
            r_slot_id_counter  <= 0;
        end else if (ptp_sync_ts >= r_next_boundary) begin
            // Crossed a slot boundary
            new_slot_pulse      <= 1;
            current_round_id     <= r_slot_id_counter;
            r_slot_id_counter   <= r_slot_id_counter + 1;
            r_next_boundary     <= r_next_boundary + P_SLOT_DURATION_NS;
        end
        
        // TX/RX gating: based on offset within current slot
        // Compute offset as ptp_sync_ts - (r_next_boundary - P_SLOT_DURATION_NS)
        slot_offset <= ptp_sync_ts - (r_next_boundary - P_SLOT_DURATION_NS);
        
        o_tx_allowed <= (slot_offset >= P_TX_START && slot_offset < P_TX_DONE);
        o_rx_enabled <= (slot_offset >= P_GUARD_NS);
    end
end

assign o_current_round_id = current_round_id;
assign o_current_run_id = config_run_id;

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
assign round_boundary = new_slot_pulse;

always @(*) begin
    // default assignments
    next_state = state;

    case (state)
        S_IDLE:     if ((activation_pending || i_ctrl_activate) && round_boundary)        next_state = S_COLLECT;
        S_COLLECT: begin
            if (round_boundary && (eval_counter < 2 || !halt))        next_state = S_COLLECT;
            else if (round_boundary && halt)    next_state = S_HALT;
        end
        S_HALT: if (i_ctrl_reboot)              next_state = S_IDLE;
    endcase
end

// -------------------------
// Clocked registers for stages
// -------------------------

always @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
        s_curr_round_id <= 0;
        s_curr_installed_membership <= 0;
        s_curr_membership_epoch <= 0;
        s_curr_sound_bitmap <= 0;
        // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
        //     s_curr_proposals[i] <= 0;
        // end

        s_evidence_round_id <= 0;
        s_evidence_installed_membership <= 0;
        s_evidence_membership_epoch <= 0;
        s_evidence_sound_bitmap <= 0;
        // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
        //     s_evidence_proposals[i] <= 0;
        // end
        for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
            s_evidence_sound_matrix[i] <= 0;
        end
        
        s_commit_round_id <= 0;
        s_commit_installed_membership <= 0;
        s_commit_membership_epoch <= 0;
        s_commit_sound_bitmap <= 0;
        // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
        //     s_commit_proposals[i] <= 0;
        // end
        for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
            s_commit_sound_matrix[i] <= 0;
        end

        o_system_halt <= 1'b0;
        
        // o_commit_log <= 0;
        // o_commit_valid <= {P_NODE_COUNT{1'b0}};
        // o_alive_mask <= {P_NODE_COUNT{1'b1}};

        eval_counter <= 0;
        activation_pending <= 1'b0;
    end else begin
        case (state)
            S_IDLE: begin
                if (i_ctrl_activate) begin
                    eval_counter <= 0;
                    activation_pending <= 1'b1;
                    config_run_id                   <= i_ctrl_run_id;
                    config_installed_membership     <= i_ctrl_membership;
                    o_system_halt <= 1'b0;
                    r_current_sound_set             <= i_ctrl_membership; // initialize sound set to membership at start
                end
                if ((activation_pending || i_ctrl_activate) && round_boundary) begin
                    s_curr_round_id             <= current_round_id;
                    s_curr_installed_membership <= i_ctrl_membership;
                    s_curr_membership_epoch     <= i_ctrl_membership_epoch;
                    s_curr_sound_bitmap         <= 1 << P_NODE_ID;
                    // s_curr_proposals[P_NODE_ID] <= i_ctrl_host_payload;
                    
                    // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    //     if (i != P_NODE_ID) s_curr_proposals[i] <= 0;
                    // end
                    activation_pending <= 1'b0;
                end
            end

            S_COLLECT: begin
                if (halt && eval_counter >= 2) begin
                    s_curr_round_id <= 0;

                    s_curr_installed_membership <= 0;
                    s_curr_membership_epoch <= 0;
                    s_curr_sound_bitmap <= 0;
                    // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    //     s_curr_proposals[i] <= 0;
                    // end

                    s_evidence_round_id <= 0;
                    s_evidence_installed_membership <= 0;
                    s_evidence_membership_epoch <= 0;
                    s_evidence_sound_bitmap <= 0;
                    // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    //     s_evidence_proposals[i] <= 0;
                    // end
                    for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                        s_evidence_sound_matrix[i] <= 0;
                    end

                    s_commit_round_id <= 0;
                    s_commit_installed_membership <= 0;
                    s_commit_membership_epoch <= 0;
                    s_commit_sound_bitmap <= 0;
                    // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    //     s_commit_proposals[i] <= 0;
                    // end
                    for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                        s_commit_sound_matrix[i] <= 0;
                    end

                    o_system_halt <= 1'b1;
                end
                else if (i_rx_valid && !round_boundary) begin
                    if (i_rx_run_id == config_run_id && i_rx_round_id == s_curr_round_id && r_current_sound_set[i_rx_node_id]) begin
                        // s_curr_proposals[i_rx_node_id] <= i_rx_payload;
                        s_curr_sound_bitmap[i_rx_node_id] <= 1'b1;
                        s_evidence_sound_matrix[i_rx_node_id] <= i_rx_sound_bitmap;
                    end
                end
                
                else if (round_boundary) begin
                    eval_counter <= eval_counter >= 2 ? eval_counter : eval_counter + 1;
                    
                    s_commit_round_id <= s_evidence_round_id;
                    s_commit_installed_membership <= s_evidence_installed_membership;
                    s_commit_membership_epoch <= s_evidence_membership_epoch;
                    s_commit_sound_bitmap <= s_evidence_sound_bitmap;
                    // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    //     s_commit_proposals[i] <= s_evidence_proposals[i];
                    // end
                    for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                        s_commit_sound_matrix[i] <= s_evidence_sound_matrix[i];
                    end
                    
                    s_evidence_round_id <= s_curr_round_id;
                    s_evidence_installed_membership <= s_curr_installed_membership;
                    s_evidence_membership_epoch <= s_curr_membership_epoch;
                    s_evidence_sound_bitmap <= f_derived_sound_set;
                    // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    //     s_evidence_proposals[i] <= s_curr_proposals[i];
                    // end
                    for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                        if (i != P_NODE_ID) s_evidence_sound_matrix[i] <= 0;
                    end
                    s_evidence_sound_matrix[P_NODE_ID] <= (f_derived_sound_set == 0) ? r_current_sound_set : f_derived_sound_set; // if no agreement, use what I see as sound, otherwise use agreed sound set as evidence 

                    s_curr_round_id <= s_curr_round_id + 1; // move to next round
                    s_curr_installed_membership <= (f_derived_sound_set == 0) ? r_current_sound_set : f_derived_sound_set; // if no agreement, use what I see as sound, otherwise use agreed sound set as membership for next round
                    s_curr_sound_bitmap <= 1 << P_NODE_ID; // reset sound bitmap to only self for next round
                    // s_curr_proposals[P_NODE_ID] <= i_ctrl_host_payload; // reset proposals to host payload for next round
                    // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    //     if (i != P_NODE_ID)
                    //         s_curr_proposals[i] <= 0;
                    // end


                    if (agreed_row_valid && eval_counter >= 2) begin
                        r_current_sound_set <= derived_sound_set; // update current sound set for next round
                    
                        // for (j = 0; j < P_NODE_COUNT; j = j + 1) begin // removed for now, proposals and commits will be in queues
                        //     if (commit_set[j]) begin
                        //         o_commit_log[j*P_LOG_ITEM_LEN*8 +: P_LOG_ITEM_LEN*8] <= s_commit_proposals[j];
                        //         o_commit_valid[j] <= 1'b1;
                        //         o_alive_mask[j] <= 1'b1;
                        //     end else begin
                        //         o_commit_valid[j] <= 1'b0;
                        //         o_alive_mask[j] <= 1'b0;
                        //     end
                        // end
                    end // else begin
                    //     o_commit_valid <= {P_NODE_COUNT{1'b0}};    
                    // end
                end
            end

            S_HALT: begin
                o_system_halt <= 1'b1;

                s_curr_round_id <= 0;
                s_curr_installed_membership <= 0;
                s_curr_membership_epoch <= 0;
                s_curr_sound_bitmap <= 0;
                // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                //     s_curr_proposals[i] <= 0;
                // end

                s_evidence_round_id <= 0;
                s_evidence_installed_membership <= 0;
                s_evidence_membership_epoch <= 0;
                s_evidence_sound_bitmap <= 0;
                // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                //     s_evidence_proposals[i] <= 0;
                // end
                for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    s_evidence_sound_matrix[i] <= 0;
                end

                s_commit_round_id <= 0;
                s_commit_installed_membership <= 0;
                s_commit_membership_epoch <= 0;
                s_commit_sound_bitmap <= 0;
                // for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                //     s_commit_proposals[i] <= 0;
                // end
                for (i = 0; i < P_NODE_COUNT; i = i + 1) begin
                    s_commit_sound_matrix[i] <= 0;
                end

                // o_alive_mask <= {P_NODE_COUNT{1'b0}};
            end
        endcase
    end
end

// -------------------------
// Combinational logic for round boundary evaluation
// -------------------------
assign membership_count = count_ones(s_commit_installed_membership);
assign quorum = (membership_count >> 1) + 1;

genvar k;
generate
    for (k = 0; k < P_NODE_COUNT; k = k + 1) begin
        assign row_valid[k] = s_commit_installed_membership[k] && ((s_commit_sound_matrix[k] == 0) || (s_commit_sound_matrix[k][k]));
    end
endgenerate

genvar m;
generate
    for (m = 0; m < P_NODE_COUNT; m = m + 1) begin
        assign row_matches[m] = (s_commit_installed_membership[m] && (s_commit_sound_matrix[m] == s_commit_sound_matrix[P_NODE_ID]));
    end
endgenerate

assign witness_count = count_ones(row_matches);
assign agreed_row_valid = (count_ones(row_valid) == membership_count) && (s_commit_sound_matrix[P_NODE_ID] != 0) && (witness_count >= quorum);

assign derived_sound_set = agreed_row_valid ? row_matches : {P_NODE_COUNT{1'b0}};

assign commit_set = agreed_row_valid ? (s_commit_sound_matrix[P_NODE_ID]) : {P_NODE_COUNT{1'b0}};

assign halt = (!agreed_row_valid) || (!(|commit_set)) || (!derived_sound_set[P_NODE_ID]) || ((derived_sound_set & r_current_sound_set) != derived_sound_set);

assign o_tx_knowledge_vec = (agreed_row_valid && eval_counter >= 2) ? derived_sound_set : {P_NODE_COUNT{1'b0}};

// forwarded values
assign f_membership_count = count_ones(s_evidence_installed_membership);
assign f_quorum = (f_membership_count >> 1) + 1;

genvar n;
generate
    for (n = 0; n < P_NODE_COUNT; n = n + 1) begin
        assign f_row_valid[n] = s_evidence_installed_membership[n] && ((s_evidence_sound_matrix[n] == 0) || (s_evidence_sound_matrix[n][n]));
    end
endgenerate

genvar p;
generate
    for (p = 0; p < P_NODE_COUNT; p = p + 1) begin
        assign f_row_matches[p] = (s_evidence_installed_membership[p] && (s_evidence_sound_matrix[p] == s_evidence_sound_matrix[P_NODE_ID]));
    end
endgenerate

assign f_witness_count = count_ones(f_row_matches);
assign f_agreed_row_valid = (count_ones(f_row_valid) == f_membership_count) && (s_evidence_sound_matrix[P_NODE_ID] != 0) && (f_witness_count >= f_quorum);

assign f_derived_sound_set = f_agreed_row_valid ? f_row_matches : {P_NODE_COUNT{1'b0}};
assign f_commit_set = f_agreed_row_valid ? (s_evidence_sound_matrix[P_NODE_ID]) : {P_NODE_COUNT{1'b0}};

endmodule