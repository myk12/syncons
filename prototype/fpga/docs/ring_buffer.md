# Proposal Buffer Interface and Design Document

## 1. Overview

`proposal_buffer` is the central storage and flow-control module in the proposal transmit path.

It sits between:

```text
proposal_dma_reader  -->  proposal_buffer  -->  tx_engine
```

The high-level purpose of `proposal_buffer` is:

```text
1. Provide writable tail slots to proposal_dma_reader.
2. Store proposal payloads in an internal fixed-size slot RAM.
3. Accept a commit event after a DMA read finishes successfully.
4. Expose committed proposal payloads as a streaming read interface to tx_engine.
5. Automatically release a slot after tx_engine consumes the last beat.
```

The design uses a fixed-size ring buffer.

Each proposal occupies exactly one fixed-size slot.

---

# 2. Design Scope

This document defines the interface contract between three modules:

```text
proposal_dma_reader
proposal_buffer
tx_engine
```

The document is centered on `proposal_buffer`.

`proposal_dma_reader` and `tx_engine` are described only in terms of how they interact with `proposal_buffer`.

---

# 3. Main Assumptions

The current v1 design assumes:

```text
1. One proposal payload = one fixed-size slot.
2. All slots have the same size.
3. DMA read length equals PROPOSAL_SLOT_BYTES.
4. TX read length equals PROPOSAL_SLOT_BYTES.
5. proposal_dma_reader has only one outstanding DMA read.
6. proposal_buffer has one producer and one consumer.
7. tx_engine consumes data through a valid/ready streaming interface.
8. proposal_buffer internally uses an addressable RAM.
```

The single-outstanding-DMA assumption is important.

Because `proposal_buffer` does not provide a separate slot allocation handshake, the tail pointer only moves after `tail_commit_valid && tail_commit_ready`.

Therefore, while one DMA read is outstanding, the current tail slot remains unchanged.

This is correct for v1 because only one DMA read is outstanding.

---

# 4. Default Configuration

The current default configuration is:

```verilog
parameter DMA_LEN_WIDTH = 16;

parameter RAM_ADDR_WIDTH = 16;
parameter RAM_SEG_COUNT = 2;
parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT;
parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8;
parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH);
parameter RAM_PIPELINE = 2;

parameter PROPOSAL_SLOT_BYTES = 1024;
parameter PROPOSAL_SLOT_COUNT = 64;
```

With these parameters:

```text
RAM_SEG_COUNT       = 2
RAM_SEG_DATA_WIDTH  = 256 bits = 32 bytes
RAM_SEG_BE_WIDTH    = 32 bits
RAM beat size       = 2 * 32 bytes = 64 bytes

PROPOSAL_SLOT_BYTES = 1024 bytes
PROPOSAL_SLOT_COUNT = 64

One slot           = 1024 bytes
One RAM beat       = 64 bytes
Beats per slot     = 1024 / 64 = 16 beats
Total buffer size  = 1024 * 64 = 65536 bytes = 64 KiB
```

Conceptually:

```text
proposal_buffer RAM
└── 64 slots
    └── each slot = 1024 bytes
        └── each slot has 16 beats
            └── each beat = 64 bytes
                └── each beat has 2 segments
                    └── each segment = 32 bytes
```

---

# 5. Module Responsibilities

## 5.1 proposal_buffer

`proposal_buffer` owns:

```text
1. Internal proposal payload RAM.
2. Tail pointer.
3. Head pointer.
4. Committed slot count.
5. Tail slot metadata generation.
6. Commit handling.
7. TX-side RAM read engine.
8. Streaming output to tx_engine.
```

It does not know the host address.

It does not issue DMA descriptors.

It does not generate SSR/proposal packet headers.

It only stores and streams proposal payload data.

---

## 5.2 proposal_dma_reader

`proposal_dma_reader` owns:

```text
1. Reading CSR/batch configuration from host control logic.
2. Issuing DMA read descriptors.
3. Using tail_slot_addr and tail_slot_len from proposal_buffer.
4. Forwarding DMA write-back beats into proposal_buffer.
5. Waiting for DMA completion status.
6. Committing the slot only after DMA completion succeeds.
```

`proposal_dma_reader` does not own the buffer storage.

It does not advance the buffer tail pointer directly.

It only asks the DMA engine to write into the current tail slot and later sends a commit event.

---

## 5.3 tx_engine

`tx_engine` owns:

```text
1. Consuming committed proposal payload data from proposal_buffer.
2. Applying backpressure with buf_rd_ready.
3. Building the final TX packet format.
4. Generating or prepending protocol headers if needed.
5. Stopping consumption when it has enough data.
```

`tx_engine` does not know the RAM address.

It does not know the head pointer.

It only sees a streaming data interface.

---

# 6. proposal_buffer External Interface

## 6.1 Clock and Reset

```verilog
input wire clk;
input wire rst;
```

`rst` resets:

```text
head_ptr
tail_ptr
slot_count
TX read engine state
TX output registers
RAM read command registers
```

After reset:

```text
tail_slot_valid = 1
tail_slot_addr  = 0
tail_slot_len   = PROPOSAL_SLOT_BYTES
buffer is empty
TX output is invalid
```

---

# 7. Write Interface from proposal_dma_reader

```verilog
input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]        buf_wr_be;
input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      buf_wr_data;
input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]      buf_wr_addr;
input  wire [RAM_SEG_COUNT-1:0]                         buf_wr_valid;
output wire [RAM_SEG_COUNT-1:0]                         buf_wr_ready;
output wire [RAM_SEG_COUNT-1:0]                         buf_wr_done;
```

This is an addressed write-beat interface.

Each write beat may contain multiple segments.

For the default configuration:

```text
RAM_SEG_COUNT = 2

buf_wr_data contains:
    segment 0 data: 256 bits = 32 bytes
    segment 1 data: 256 bits = 32 bytes

Together:
    one full write beat = 64 bytes
```

The layout is:

```verilog
buf_wr_data[0 +: 256]   = segment 0 data
buf_wr_data[256 +: 256] = segment 1 data

buf_wr_be[0 +: 32]      = segment 0 byte enable
buf_wr_be[32 +: 32]     = segment 1 byte enable

buf_wr_addr[0 +: RAM_SEG_ADDR_WIDTH]
    = segment 0 RAM row address

buf_wr_addr[RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH]
    = segment 1 RAM row address
```

For a full 64-byte write beat:

```text
buf_wr_valid = 2'b11
segment 0 address = row address
segment 1 address = row address
segment 0 byte enable = all ones
segment 1 byte enable = all ones
```

This interface is driven by `proposal_dma_reader`, which forwards DMA write-back commands into `proposal_buffer`.

---

# 8. Tail Slot Interface to proposal_dma_reader

```verilog
output wire                      tail_slot_valid;
output wire [RAM_ADDR_WIDTH-1:0] tail_slot_addr;
output wire [DMA_LEN_WIDTH-1:0]  tail_slot_len;
```

This interface exposes the current writable tail slot.

`tail_slot_valid` means:

```text
The buffer is not full, so the current tail slot can be used.
```

`tail_slot_addr` is a byte address.

It is used by `proposal_dma_reader` as the target RAM address in the DMA read descriptor.

For the default configuration:

```text
tail_slot_addr = tail_ptr * 1024
tail_slot_len  = 1024
```

Examples:

```text
tail_ptr = 0 -> tail_slot_addr = 0
tail_ptr = 1 -> tail_slot_addr = 1024
tail_ptr = 2 -> tail_slot_addr = 2048
tail_ptr = 3 -> tail_slot_addr = 3072
```

Important:

```text
tail_slot_addr is a byte address.
buf_wr_addr and ram_rd_cmd_addr are RAM row addresses.
```

They are not the same unit.

---

# 9. Tail Commit Interface

```verilog
input  wire tail_commit_valid;
output wire tail_commit_ready;
```

`proposal_dma_reader` asserts `tail_commit_valid` after the DMA read completes successfully.

A commit happens when:

```verilog
tail_commit_valid && tail_commit_ready
```

This event is called:

```verilog
tail_commit_fire
```

When `tail_commit_fire` happens, `proposal_buffer` does:

```text
tail_ptr   = tail_ptr + 1
slot_count = slot_count + 1
```

This means the current tail slot becomes a committed slot and is now available for TX consumption.

If the DMA read fails, `proposal_dma_reader` must not assert `tail_commit_valid`.

In that case:

```text
tail_ptr does not move
slot_count does not increase
the partially written slot may be overwritten by a later retry
```

---

# 10. TX Streaming Interface to tx_engine

```verilog
output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] buf_rd_data;
output wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   buf_rd_be;
output wire                                        buf_rd_valid;
input  wire                                        buf_rd_ready;
output wire                                        buf_tx_last;
output wire [DMA_LEN_WIDTH-1:0]                    buf_tx_len;
```

This is the read-side streaming interface.

`proposal_buffer` automatically reads the current head slot and presents data to `tx_engine`.

`tx_engine` consumes one beat when:

```verilog
buf_rd_valid && buf_rd_ready
```

For the default configuration:

```text
one buf_rd_data beat = 64 bytes
one proposal slot    = 16 beats
```

`buf_tx_last` is asserted on the last beat of the current slot.

The current slot is released when:

```verilog
buf_rd_valid && buf_rd_ready && buf_tx_last
```

This event is called:

```verilog
head_pop_fire
```

When `head_pop_fire` happens, `proposal_buffer` does:

```text
head_ptr   = head_ptr + 1
slot_count = slot_count - 1
```

---

# 11. Ring Buffer State

`proposal_buffer` maintains three core state variables:

```verilog
head_ptr_reg;
tail_ptr_reg;
slot_count_reg;
```

Their meaning:

```text
head_ptr_reg:
    Points to the oldest committed slot.
    TX read engine reads from this slot.

tail_ptr_reg:
    Points to the current writable slot.
    proposal_dma_reader writes into this slot.

slot_count_reg:
    Number of committed slots that have not yet been fully consumed by tx_engine.
```

The buffer is empty when:

```verilog
slot_count_reg == 0
```

The buffer is full when:

```verilog
slot_count_reg == PROPOSAL_SLOT_COUNT
```

The tail slot is valid when:

```verilog
!buffer_full
```

The TX side can start reading when:

```verilog
!buffer_empty
```

---

# 12. Slot, Beat, Segment, and Address Mapping

## 12.1 Terminology

```text
slot:
    Logical queue entry.
    One proposal occupies one slot.

beat:
    One RAM access unit.
    In the default configuration, one beat is 64 bytes.

segment:
    One parallel RAM lane inside a beat.
    In the default configuration, one beat has 2 segments.

byte enable:
    Per-byte write mask inside each segment.
```

## 12.2 Default Mapping

```text
1 slot = 1024 bytes
1 beat = 64 bytes
1 slot = 16 beats
1 beat = 2 segments
1 segment = 32 bytes
```

## 12.3 Slot to Byte Address

```text
slot_base_byte_addr = slot_index * 1024
```

Examples:

```text
slot 0 -> byte 0
slot 1 -> byte 1024
slot 2 -> byte 2048
slot 3 -> byte 3072
```

## 12.4 Slot to RAM Row Address

A RAM row corresponds to one full beat.

```text
slot_base_row_addr = slot_index * 16
```

Examples:

```text
slot 0 -> row 0
slot 1 -> row 16
slot 2 -> row 32
slot 3 -> row 48
```

## 12.5 Beat Address Inside a Slot

```text
row_addr = slot_index * 16 + beat_index
```

Example:

```text
slot_index = 3
beat_index = 5

row_addr = 3 * 16 + 5 = 53
```

The byte range is:

```text
slot 3 base byte = 3 * 1024 = 3072
beat 5 offset    = 5 * 64 = 320

global byte range = 3072 + 320 to 3072 + 320 + 63
                  = 3392 to 3455
```

Segment mapping:

```text
segment 0 -> bytes 3392 to 3423
segment 1 -> bytes 3424 to 3455
```

---

# 13. Write Operation Example

Assume:

```text
tail_ptr = 3
```

Then:

```text
tail_slot_addr = 3 * 1024 = 3072
tail_slot_len  = 1024
```

`proposal_dma_reader` issues a DMA read descriptor with:

```text
RAM target byte address = 3072
DMA length              = 1024
```

The DMA engine writes 1024 bytes into the internal RAM.

Since one RAM beat is 64 bytes:

```text
1024 bytes = 16 write beats
```

The write sequence is:

```text
beat 0  -> row 48
beat 1  -> row 49
beat 2  -> row 50
...
beat 15 -> row 63
```

For beat 0:

```text
row 48:
    segment 0 receives payload bytes 0  to 31
    segment 1 receives payload bytes 32 to 63
```

For beat 15:

```text
row 63:
    segment 0 receives payload bytes 960 to 991
    segment 1 receives payload bytes 992 to 1023
```

After the DMA read status indicates success, `proposal_dma_reader` asserts:

```verilog
tail_commit_valid = 1'b1;
```

If `tail_commit_ready` is also high, the slot is committed.

Then:

```text
tail_ptr moves from 3 to 4
slot_count increases by 1
slot 3 becomes available to tx_engine
```

---

# 14. Read Operation Example

Assume:

```text
head_ptr = 3
slot_count > 0
```

This means slot 3 is the oldest committed proposal.

The TX read engine starts reading slot 3.

The slot base row is:

```text
head_ptr * 16 = 3 * 16 = 48
```

The read sequence is:

```text
TX beat 0  -> row 48
TX beat 1  -> row 49
TX beat 2  -> row 50
...
TX beat 15 -> row 63
```

For each row:

```text
proposal_buffer issues a RAM read command
waits for RAM response
stores the response into buf_rd_data_reg
asserts buf_rd_valid
waits for tx_engine to assert buf_rd_ready
```

A beat is transferred to `tx_engine` when:

```verilog
buf_rd_valid && buf_rd_ready
```

For beats 0 through 14:

```text
buf_tx_last = 0
```

For beat 15:

```text
buf_tx_last = 1
```

When beat 15 is accepted:

```verilog
buf_rd_valid && buf_rd_ready && buf_tx_last
```

then:

```text
head_ptr moves from 3 to 4
slot_count decreases by 1
slot 3 is released
```

---

# 15. TX Read Engine Behavior

The TX read engine inside `proposal_buffer` has four states:

```text
TX_STATE_IDLE
TX_STATE_READ_CMD
TX_STATE_READ_RESP
TX_STATE_OUTPUT
```

## 15.1 TX_STATE_IDLE

The engine waits for the buffer to become non-empty.

Condition:

```verilog
!buffer_empty
```

Action:

```text
Set tx_beat_index to 0.
Issue RAM read command for the first beat of the current head slot.
```

## 15.2 TX_STATE_READ_CMD

The engine waits for internal RAM to accept the read command.

Condition:

```verilog
ram_rd_cmd_fire
```

Action:

```text
Clear read command valid.
Move to TX_STATE_READ_RESP.
```

## 15.3 TX_STATE_READ_RESP

The engine waits for the RAM response.

Condition:

```verilog
ram_rd_resp_fire
```

Action:

```text
Capture RAM response into buf_rd_data.
Set buf_rd_be to all ones.
Set buf_rd_valid.
Set buf_tx_last if this is the last beat.
Move to TX_STATE_OUTPUT.
```

## 15.4 TX_STATE_OUTPUT

The engine holds the current beat stable until `tx_engine` accepts it.

Condition:

```verilog
buf_rd_valid && buf_rd_ready
```

If this is not the last beat:

```text
Increment tx_beat_index.
Issue read command for the next row.
Return to TX_STATE_READ_CMD.
```

If this is the last beat:

```text
Return to TX_STATE_IDLE.
head_pop_fire releases the current slot.
```

---

# 16. proposal_dma_reader Contract

`proposal_dma_reader` must follow this contract when interacting with `proposal_buffer`.

## 16.1 Before Issuing a DMA Descriptor

It must check:

```verilog
tail_slot_valid == 1'b1
```

Then it may use:

```verilog
tail_slot_addr
tail_slot_len
```

to issue a DMA read descriptor.

## 16.2 During DMA Write-Back

It forwards DMA write-back beats into:

```verilog
buf_wr_be
buf_wr_data
buf_wr_addr
buf_wr_valid
```

and observes:

```verilog
buf_wr_ready
buf_wr_done
```

The write address must target the current tail slot.

## 16.3 After DMA Completion

If DMA status indicates success:

```text
Assert tail_commit_valid.
Wait for tail_commit_valid && tail_commit_ready.
```

If DMA status indicates error:

```text
Do not assert tail_commit_valid.
Do not advance the slot.
The same tail slot may be reused later.
```

## 16.4 Important Rule

`proposal_dma_reader` must not start multiple outstanding DMA reads to different tail slots in v1.

Reason:

```text
proposal_buffer does not reserve tail slots on descriptor issue.
tail_ptr advances only on commit.
```

Multiple outstanding DMA reads would require a real allocation/reservation interface.

---

# 17. tx_engine Contract

`tx_engine` must follow this contract when interacting with `proposal_buffer`.

## 17.1 Data Consumption

`tx_engine` consumes one beat when:

```verilog
buf_rd_valid && buf_rd_ready
```

`tx_engine` must only sample:

```verilog
buf_rd_data
buf_rd_be
buf_tx_last
buf_tx_len
```

on cycles where the handshake succeeds.

## 17.2 Backpressure

If `tx_engine` cannot accept data, it deasserts:

```verilog
buf_rd_ready = 1'b0;
```

`proposal_buffer` will hold the current valid beat stable until it is accepted.

## 17.3 End of Slot

`buf_tx_last` marks the final beat of the current proposal slot.

When `tx_engine` accepts the beat with `buf_tx_last = 1`, the current slot is released inside `proposal_buffer`.

`tx_engine` does not need to send a separate release signal.

## 17.4 Reading Less Than One Slot

In the current v1 design, `proposal_buffer` assumes a full slot is consumed once streaming begins.

If `tx_engine` stops early by deasserting `buf_rd_ready`, `proposal_buffer` will simply hold or continue waiting at the current beat.

The slot is not released until the last beat is accepted.

Therefore:

```text
tx_engine may pause at any beat.
tx_engine should not abandon a slot permanently.
tx_engine must eventually consume through buf_tx_last to release the slot.
```

---

# 18. Full Data Flow

## 18.1 Write Side

```text
1. proposal_buffer exposes current tail slot.

2. proposal_dma_reader sees:
       tail_slot_valid = 1
       tail_slot_addr
       tail_slot_len

3. proposal_dma_reader issues DMA read descriptor.

4. DMA engine writes payload beats into proposal_buffer RAM
   through buf_wr_*.

5. DMA status reports success.

6. proposal_dma_reader asserts tail_commit_valid.

7. proposal_buffer accepts commit:
       tail_ptr++
       slot_count++

8. The slot is now visible to TX read side.
```

## 18.2 Read Side

```text
1. proposal_buffer sees slot_count > 0.

2. TX read engine starts reading current head slot.

3. Internal RAM returns one 64-byte beat at a time.

4. proposal_buffer presents each beat on:
       buf_rd_data
       buf_rd_be
       buf_rd_valid
       buf_tx_last

5. tx_engine accepts beats with:
       buf_rd_ready = 1

6. On the final beat:
       buf_tx_last = 1

7. When final beat is accepted:
       head_ptr++
       slot_count--
```

---

# 19. Buffer Full and Empty Behavior

## 19.1 Empty

The buffer is empty when:

```verilog
slot_count_reg == 0
```

Behavior:

```text
tail_slot_valid may still be 1 if not full.
buf_rd_valid will eventually be 0.
TX read engine waits in IDLE.
```

## 19.2 Full

The buffer is full when:

```verilog
slot_count_reg == PROPOSAL_SLOT_COUNT
```

Behavior:

```text
tail_slot_valid = 0
tail_commit_ready = 0
proposal_dma_reader must not issue a new DMA read
```

In v1, if the buffer is full and TX releases one slot in the same cycle, the design may not accept a commit in that same cycle because `tail_commit_ready` is based only on the current full state.

This is conservative and acceptable for v1.

---

# 20. Important Invariants

The following invariants should always hold:

```text
0 <= slot_count <= PROPOSAL_SLOT_COUNT

buffer_empty == (slot_count == 0)

buffer_full == (slot_count == PROPOSAL_SLOT_COUNT)

tail_slot_valid == !buffer_full

tail_commit_ready == !buffer_full

head_ptr advances only when the last TX beat is accepted

tail_ptr advances only when the current tail slot is committed

slot_count increases only on tail commit

slot_count decreases only on head pop

slot_count is unchanged if commit and pop happen in the same cycle
```

---

# 21. Recommended Debug Signals

For waveform debugging, the following internal signals are useful:

```text
head_ptr_reg
tail_ptr_reg
slot_count_reg

buffer_empty
buffer_full

tail_slot_valid
tail_slot_addr
tail_commit_valid
tail_commit_ready
tail_commit_fire

buf_rd_valid
buf_rd_ready
buf_tx_last
head_pop_fire

tx_state_reg
tx_beat_index_reg

ram_rd_cmd_addr_reg
ram_rd_cmd_valid_reg
ram_rd_cmd_ready

ram_rd_resp_data
ram_rd_resp_valid
ram_rd_resp_ready
```

For write-side debugging:

```text
buf_wr_valid
buf_wr_ready
buf_wr_done
buf_wr_addr
buf_wr_be
buf_wr_data
```

---

# 22. Future Extensions

The current v1 design intentionally keeps the interface simple.

Possible future extensions include:

```text
1. Variable-length proposal slots.
2. Multiple outstanding DMA reads.
3. Tail slot reservation interface.
4. Abort or rollback interface.
5. Read-side metadata output.
6. Integration with packet header generation.
7. Support for partial final beats.
8. Lookahead full/empty handling for simultaneous commit and pop.
```

For multiple outstanding DMA reads, the current interface is not sufficient.

A future design would need a real allocation interface, for example:

```text
alloc_valid
alloc_ready
alloc_slot_addr
alloc_slot_id
commit_slot_id
abort_slot_id
```

That would allow `proposal_dma_reader` to reserve multiple slots before DMA completion.

---

# 23. Summary

`proposal_buffer` is a fixed-size slot ring buffer.

Its write side is address-based because Corundum DMA writes into an addressable RAM.

Its read side is streaming because `tx_engine` only needs to consume ordered proposal payload data.

The final conceptual model is:

```text
proposal_dma_reader
    uses tail_slot_addr/tail_slot_len
    writes payload through buf_wr_*
    commits successful DMA reads

proposal_buffer
    stores payloads in fixed-size RAM slots
    manages head/tail/count
    streams committed slots to tx_engine

tx_engine
    consumes buf_rd_* stream
    applies backpressure with buf_rd_ready
    uses buf_tx_last to detect end of proposal slot
```

In the default configuration:

```text
proposal_buffer = 64 KiB
64 slots
1 KiB per slot
16 beats per slot
64 bytes per beat
2 segments per beat
32 bytes per segment
```

This gives a clean and deterministic interface between the DMA fetch side and the TX packet generation side.
