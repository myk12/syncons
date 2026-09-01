# SPDX-License-Identifier: BSD-2-Clause-Views
#
# consensus_core timing constraints
#
# Scoped the same way Corundum scopes its own module constraints: find every
# instance of the module by reference name, then constrain relative to it, so
# the file survives hierarchy changes and multiple instantiations.

foreach inst [get_cells -hier -filter {(ORIG_REF_NAME == consensus_core || REF_NAME == consensus_core)}] {
    puts "Inserting timing constraints for consensus_core instance $inst"

    # ---------------------------------------------------------------------
    # Second-base multiplier  (DISABLED - see the precondition below)
    # ---------------------------------------------------------------------
    #
    # core.v computes
    #
    #     second_base = i_ptp_tod_sec * ROUNDS_PER_SECOND
    #
    # ROUNDS_PER_SECOND is a compile-time constant (250000 for a 4 us round),
    # so this is not a DSP multiply but a compressor tree over seven shifted
    # copies of the 48-bit seconds field, ending in one 64-bit carry-propagate
    # add. Call it 2-3 ns on this part, against a ~3.6 ns budget at 250 MHz.
    # Tight, but it has never been measured - synthesis has not been run.
    #
    # The seconds field changes once per second: 250,000,000 cycles of slack
    # that the timing engine cannot see. So a multicycle path is the natural
    # fix IF the path ever fails:
    #
    #     set_multicycle_path -setup 4 -to [get_cells "$inst/current_second_base_reg_reg[*]"]
    #     set_multicycle_path -hold  3 -to [get_cells "$inst/current_second_base_reg_reg[*]"]
    #     set_multicycle_path -setup 4 -to [get_cells "$inst/next_second_base_reg_reg[*]"]
    #     set_multicycle_path -hold  3 -to [get_cells "$inst/next_second_base_reg_reg[*]"]
    #
    # ##################################################################
    # #  DO NOT UNCOMMENT WITHOUT ALSO CHANGING core.v.  HERE IS WHY.  #
    # ##################################################################
    #
    # A multicycle constraint does not stop the destination register from
    # clocking every cycle. It only tells the tool that the value is not
    # required to be correct until N edges after launch. So with -setup 4,
    # current_second_base_reg holds an UNSETTLED value for the three cycles
    # following any change of i_ptp_tod_sec.
    #
    # core.v's arm branch consumes that register under the guard
    #
    #     else if (!timing_armed_reg && !second_changed)
    #
    # which only waits ONE cycle. Enabling the constraint as written would let
    # the arm path latch garbage during a 3-cycle window after each second
    # rollover. Arming is asynchronous to the rollover, so the exposure is
    # roughly 3 in 250,000,000 per arm attempt - rare enough to survive every
    # test you will ever run, and to corrupt round_id by an arbitrary amount in
    # the field. That is the worst possible failure mode.
    #
    # To enable this safely, do BOTH of the following together:
    #
    #   1. In core.v, add a saturating counter of consecutive cycles for which
    #      i_ptp_tod_sec has been unchanged, and replace the arm guard's
    #      !second_changed with "counter >= N", N matching the -setup value
    #      here. Arming is a once-per-activation event, so the extra latency
    #      is free.
    #   2. Uncomment the four lines above, keeping -hold one less than -setup.
    #      (-setup alone shifts the hold check too and produces bogus hold
    #      violations; this is the standard multicycle footgun.)
    #
    # next_second_base_reg does not need the counter - it is consumed on the
    # rollover cycle itself, and the value it holds there was derived from a
    # seconds field that had been stable for the whole preceding second. It is
    # listed above only because both registers sit behind the same tree, so
    # relaxing one endpoint alone would not relax the tree.
    #
    # Sanity check before enabling: confirm the register names still exist.
    # Vivado appends its own "_reg" to the RTL signal name, hence the doubled
    # suffix on current_second_base_reg_reg.
    #
    #     llength [get_cells "$inst/current_second_base_reg_reg[*]"]   ;# expect 64

    # ---------------------------------------------------------------------
    # Clock domain
    # ---------------------------------------------------------------------
    # No CDC constraints here, deliberately. consensus_core takes PTP time via
    # ptp_sync_ts_tod, which mqnic_ptp_clock's ptp_td_leaf instance generates in
    # the core clk domain - the wide timestamp never crosses a domain, only the
    # single-bit ptp_td_sd stream does, and ptp_td_leaf.tcl already constrains
    # that. consensus_core must therefore always be clocked by the same clk that
    # is passed to mqnic_ptp. If that ever changes, a 96-bit value starts
    # crossing domains unsynchronised and this file needs a real CDC section.
}
