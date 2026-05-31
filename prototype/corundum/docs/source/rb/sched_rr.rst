.. _rb_sched_rr:

====================================
Round-robin scheduler register block
====================================

The round-robin scheduler register block has a header with type 0x0000C040, version 0x00000200, and indicates the location of the scheduler in the register space, as well as containing some control, status, and informational registers.

.. table::

    ============  =============  ======  ======  ======  ======  =============
    Address       Field          31..24  23..16  15..8   7..0    Reset value
    ============  =============  ======  ======  ======  ======  =============
    RBB+0x00      Type           Vendor ID       Type            RO 0x0000C040
    ------------  -------------  --------------  --------------  -------------
    RBB+0x04      Version        Major   Minor   Patch   Meta    RO 0x00000200
    ------------  -------------  ------  ------  ------  ------  -------------
    RBB+0x08      Next pointer   Pointer to next register block  RO -
    ------------  -------------  ------------------------------  -------------
    RBB+0x0C      Offset         Offset to scheduler             RO -
    ------------  -------------  ------------------------------  -------------
    RBB+0x10      Queue count    Queue count                     RO -
    ------------  -------------  ------------------------------  -------------
    RBB+0x14      Queue stride   Queue stride                    RO -
    ------------  -------------  ------------------------------  -------------
    RBB+0x18      Control        Scheduler Control               RW 0x00000000
    ------------  -------------  ------------------------------  -------------
    RBB+0x1C      Config                 FC scl  Ports   TCs     RO -
    ------------  -------------  ------  ------  ------  ------  -------------
    RBB+0x20+16n  CH N ctrl      Channel control                 RW 0x00000000
    ------------  -------------  ------------------------------  -------------
    RBB+0x24+16n  CH N FC 1      Packet budget   Dest            RW -
    ------------  -------------  --------------  --------------  -------------
    RBB+0x28+16n  CH N FC 2      Packet limit    Data budget     RW -
    ------------  -------------  --------------  --------------  -------------
    RBB+0x2C+16n  CH N FC 3      Data limit                      RW -
    ============  =============  ==============================  =============

See :ref:`rb_overview` for definitions of the standard register block header fields.

.. object:: Offset

    The offset field contains the offset to the start of the scheduler region, relative to the start of the current region.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x0C  Offset to scheduler             RO -
        ========  ==============================  =============

.. object:: Queue count

    The queue count field contains the number of queues.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x10  Queue count                     RO -
        ========  ==============================  =============

.. object:: Queue stride

    The queue stride field contains the size of the region for each queue.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x14  Queue stride                    RO 0x00000004
        ========  ==============================  =============

.. object:: Control/status

    The control field contains scheduler-related control bits.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x18  Control                         RW 0x00000000
        ========  ==============================  =============

    .. table::

        ===  ========
        Bit  Function
        ===  ========
        0    Enable
        16   Active
        ===  ========

.. object:: Config

    The config register contains the number of ports and traffic classes that the scheduler is configured for, as well as the flow control scale value.  The scheduler implements a hierarchical schedule, round-robin across X ports, strict priority across Y traffic classes on each port, and round-robin on all queues enabled on each TC.  Queues can be enabled on one TC on any number of ports.

    .. table::

        ========  ======  ======  ======  ======  =============
        Address   31..24  23..16  15..8   7..0    Reset value
        ========  ======  ======  ======  ======  =============
        RBB+0x1C          FC Scl  Ports   TCs     RO -
        ========  ======  ======  ======  ======  =============

.. object:: Channel control

    The control field contains scheduler-related control bits.

    .. table::

        ============  ======  ======  ======  ======  =============
        Address       31..24  23..16  15..8   7..0    Reset value
        ============  ======  ======  ======  ======  =============
        RBB+0x20+16n  Status          Control         RW 0x00000000
        ============  ==============  ==============  =============

    .. table::

        ===  ========
        Bit  Function
        ===  ========
        0    Enable
        16   Active
        17   Fetch active
        18   FC available
        19   Scheduler primed
        ===  ========

.. object:: Channel flow control registers

    The channel flow control registers contain aggregate limit settings for outstanding operations as well as budgets for starting new operations.  The data limits are specified in flow control credits, with the FC scale value determining the number of bytes per credit.  The packet budget and data budget control the number of packets and aggregate packet data that can be fetched for each scheduling decision on the scheduler channel.  The packet limit and data limit determine the maximum number of outstanding packets and aggregate packet data in transmission on the scheduler channel at any time.  The dest field is used to control the routing and traffic class for the scheduler channel.

    .. table::

        ============  ======  ======  ======  ======  =============
        Address       31..24  23..16  15..8   7..0    Reset value
        ============  ======  ======  ======  ======  =============
        RBB+0x2C+16n  Packet budget   dest            RW -
        ------------  --------------  --------------  -------------
        RBB+0x2C+16n  Packet limit    Data budget     RW -
        ------------  --------------  --------------  -------------
        RBB+0x2C+16n  Data limit                      RW -
        ============  ==============================  =============

Round-robin scheduler queue CSRs
================================

Each queue has several associated control registers, detailed in this table:

.. table::

    =========  ==============  ======  ======  ======  ======  =============
    Address    Field           31..24  23..16  15..8   7..0    Reset value
    =========  ==============  ======  ======  ======  ======  =============
    Base+0x00  Control         P n+3   P n+2   P n+1   P n     RW 0x00000000
    =========  ==============  ======  ======  ======  ======  =============

.. object:: Control

    The control field contains scheduler-related control bits.  Each port has a dedicated byte; the stride size will be set based on the number of ports.  Queue-level bits are located in the MSBs of each byte.  All fields are read-only; use commands to control the enable and pause bits as well as set the TCs on each of the ports.

    .. table::

        =========  ======  ======  ======  ======  =============
        Address    31..24  23..16  15..8   7..0    Reset value
        =========  ======  ======  ======  ======  =============
        Base+0x00  P n+3   P n+2   P n+1   P n     RW 0x00000000
        =========  ======  ======  ======  ======  =============

    .. table::

        =====  =============
        Bit    Function
        =====  =============
        2:0    Port n TC
        3      Port n enable
        4      Port n pause
        5      Port n scheduled
        6      Queue enable
        7      Queue pause
        10:8   Port n+1 TC
        11     Port n+1 enable
        12     Port n+1 pause
        13     Port n+1 scheduled
        14     Queue active
        18:16  Port n+2 TC
        19     Port n+2 enable
        20     Port n+2 pause
        21     Port n+2 scheduled
        26:24  Port n+3 TC
        27     Port n+3 enable
        28     Port n+3 pause
        29     Port n+3 scheduled
        =====  =============

Round-robin scheduler queue commands
====================================

.. table::

    ========================  ======  ======  ======  ======
    Command                   31..24  23..16  15..8   7..0
    ========================  ======  ======  ======  ======
    Set port TC               0x8001          Port    TC
    ------------------------  --------------  ------  ------
    Set port enable           0x8002          Port    Enable
    ------------------------  --------------  ------  ------
    Set port pause            0x8003          Port    Pause
    ------------------------  --------------  ------  ------
    Set queue enable          0x400001                Enable
    ------------------------  ----------------------  ------
    Set queue pause           0x400002                Pause
    ========================  ======================  ======

.. object:: Set port TC

    The set port TC command is used to set the traffic class for the specified port for the queue.  Allowed at any time, but the change only takes affect when the queue is rescheduled.

    .. table::

        ======  ======  ======  ======
        31..24  23..16  15..8   7..0
        ======  ======  ======  ======
        0x8001          Port    TC
        ==============  ======  ======

.. object:: Set port enable

    The set port enable command is used to set the traffic class for the specified port for the queue.  Allowed at any time.

    .. table::

        ======  ======  ======  ======
        31..24  23..16  15..8   7..0
        ======  ======  ======  ======
        0x8002          Port    Enable
        ==============  ======  ======

.. object:: Set port pause

    The set port pause command is used to set the traffic class for the specified port for the queue.  Allowed at any time.

    .. table::

        ======  ======  ======  ======
        31..24  23..16  15..8   7..0
        ======  ======  ======  ======
        0x8003          Port    Pause
        ==============  ======  ======

.. object:: Set queue enable

    The set queue enable command is used to enable or disable the queue.  Allowed at any time.

    .. table::

        ======  ======  ======  ======
        31..24  23..16  15..8   7..0
        ======  ======  ======  ======
        0x400001                Enable
        ======================  ======

.. object:: Set queue pause

    The set queue pause command is used to pause or un-pause the queue.  Allowed at any time.

    .. table::

        ======  ======  ======  ======
        31..24  23..16  15..8   7..0
        ======  ======  ======  ======
        0x400002                Pause
        ======================  ======
