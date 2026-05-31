.. _rb_tdma_sch:

=============================
TDMA scheduler register block
=============================

The TDMA scheduler register block has a header with type 0x0000C060, version 0x00000200, and carries several control registers for the TDMA scheduler module.

.. table::

    ========  ==============  ======  ======  ======  ======  =============
    Address   Field           31..24  23..16  15..8   7..0    Reset value
    ========  ==============  ======  ======  ======  ======  =============
    RBB+0x00  Type            Vendor ID       Type            RO 0x0000C060
    --------  --------------  --------------  --------------  -------------
    RBB+0x04  Version         Major   Minor   Patch   Meta    RO 0x00000200
    --------  --------------  ------  ------  ------  ------  -------------
    RBB+0x08  Next pointer    Pointer to next register block  RO -
    --------  --------------  ------------------------------  -------------
    RBB+0x0C  Control/status  Timeslot count  Control         RW -
    --------  --------------  --------------  --------------  -------------
    RBB+0x10  Sch start       Sch start time (fractional ns)  RW -
    --------  --------------  ------------------------------  -------------
    RBB+0x14  Sch start       Sch start time (ns)             RW -
    --------  --------------  ------------------------------  -------------
    RBB+0x18  Sch start       Sch start time (sec, lower 32)  RW -
    --------  --------------  ------------------------------  -------------
    RBB+0x1C  Sch start       Sch start time (sec, upper 32)  RW -
    --------  --------------  ------------------------------  -------------
    RBB+0x20  Sch period      Sch period (fractional ns)      RW -
    --------  --------------  ------------------------------  -------------
    RBB+0x24  Sch period      Sch period (ns)                 RW -
    --------  --------------  ------------------------------  -------------
    RBB+0x28  TS period       TS period (ns)                  RW -
    --------  --------------  ------------------------------  -------------
    RBB+0x2C  Active period   Active period (ns)              RW -
    ========  ==============  ==============================  =============

See :ref:`rb_overview` for definitions of the standard register block header fields.

.. object:: Control/status

    The control and status register contains several control bits relating to the operation of the TDMA scheduler module.  The timeslot count field contains the number of timeslots supported, and the control/status field contains several bits to control and monitor the operation of the scheduler.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x0C  Timeslot count  Control/status  RO -
        ========  ==============  ==============  =============

    The control and status bits are defined as follows

    .. table::

        ===  ========
        Bit  Function
        ===  ========
        0    Enable
        8    Locked
        9    Error
        ===  ========

.. object:: Schedule start time

    The schedule start time registers determine the absolute start time for the schedule, with all values latched coincident with writing the upper 32 bits of the seconds field.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x10  Sch start time (fractional ns)  RW -
        --------  ------------------------------  -------------
        RBB+0x14  Sch start time (ns)             RW -
        --------  ------------------------------  -------------
        RBB+0x18  Sch start time (sec, lower 32)  RW -
        --------  ------------------------------  -------------
        RBB+0x1C  Sch start time (sec, upper 32)  RW -
        ========  ==============================  =============

.. object:: Schedule period

    The schedule period registers control the period of the schedule, with all values latched coincident with writing the ns field.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x20  Sch period (fractional ns)      RW -
        --------  ------------------------------  -------------
        RBB+0x24  Sch period (ns)                 RW -
        ========  ==============================  =============

.. object:: Timeslot period

    The timeslot period register controls the period of each time slot.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x28  TS period (ns)                  RW -
        ========  ==============================  =============

.. object:: Active period

    The active period register controls the active period of each time slot.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x2C  Active period (ns)              RW -
        ========  ==============================  =============

TDMA timing parameters
======================

The TDMA schedule is defined by several parameters - the schedule start time, schedule period, timeslot period, and timeslot active period.  This figure depicts the relationship between these parameters::

      schedule
       start
         |
         V
         |<-------- schedule period -------->|
    -----+--------+--------+--------+--------+--------+---
         | SLOT 0 | SLOT 1 | SLOT 2 | SLOT 3 | SLOT 0 | 
    -----+--------+--------+--------+--------+--------+---
         |<------>|
          timeslot
           period


         |<-------- timeslot period -------->|
    -----+-----------------------------------+------------
         | SLOT 0                            | SLOT 1   
    -----+-----------------------------------+------------
         |<---- active period ----->|

The schedule start time is the absolute start time.  Each subsequent schedule will start on a multiple of the schedule period after the start time.  Each schedule starts on timeslot 0, and advances to the next timeslot each timeslot period.  The timeslot active period is the active period for each timeslot, forming a guard period at the end of the timeslot.  It is recommended that the timeslot period divide evenly into the schedule period, but rounding errors will not accumulate as the schedule period takes precedence over the timeslot period.  Similarly, the timeslot period takes precedence over the timeslot active period.  It is recommended to always round the period values up to avoid a gap between the end of the last timeslot and the start of the next schedule, as this can result in the generation of a short extraneous timeslot at the end of the schedule.
