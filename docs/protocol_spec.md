# SynCons Protocol Specification

Status: design v5 (agreed-row / sound-set dataplane with interruption-driven online rejoin)

This document is the current authoritative protocol specification for SynCons.
It defines the present protocol objects, state machines, and transition rules.

## 1. Overview

SynCons is a split replicated state machine design.

The dataplane runs a synchronous fast path in a low-variance execution domain.
The control plane handles interruption processing, repair, reconfiguration, and
re-entry.

The current dataplane uses one locally agreed row value to derive two
different protocol objects:

```text
agreed row value       -> old-epoch commit set
identical-row senders  -> next-round sound set
```

The central dataplane rule is:

```text
identify a quorum-agreed local row
commit the nodes named by that row
continue only on the senders that hold that row
```

The sound set is shrink-only across rounds.

Operationally, the time layering is:

```text
previous-round sound matrix
-> current-round agreed row
-> current-round commit set + current-round sound set
-> current-round transmitted sound bitmap
-> next-round sound matrix
```

Thus, the current round's commit set is derived from the previous round's
exchanged sound-set information, while the current round's sound set is sent
forward for use at the next round boundary.

## 2. System Model

### 2.1 Nodes and Membership

The system consists of a finite set of nodes.

At any time, the control plane installs a membership configuration `M`.

Each installed membership has:

- a `membership_epoch`;
- a membership bitmap `chi(M)`;
- a global `run_id`.

The `run_id` is the wire-level incarnation marker. Every coordinated rejoin
cutover installs a fresh global `run_id`.

Only nodes in the installed membership may participate in the dataplane.

### 2.2 Quorum

For membership `M`, the quorum size is:

```text
Q = floor(|M| / 2) + 1
```

### 2.3 Dataplane Fault Model

The dataplane explicitly handles:

- crash and halt;
- asymmetric visibility;
- packet loss;
- stale replay;
- old-run replay;
- corrupted dataplane row evidence.

For dataplane liveness, the protocol treats these as equivalent:

```text
node crashes
node remains alive but is completely absent from the witnessable current-round
communication universe
```

The dataplane therefore reasons about the current synchronous universe, not
about physical liveness in the asynchronous control-plane sense.

Both `NodeCrashed` and `NodeHalted` are exported to the control plane as
interruptions. In the current APSys simulator line, both interruption kinds
enter the same background repair and online rejoin workflow.

## 3. Protocol Objects

### 3.1 Bitmap

A node set `S` is represented by:

```text
chi(S)
```

Bit `i` is one iff node `i` belongs to `S`.

### 3.2 Sound Bitmap and Sound Matrix

A **sound bitmap** is the on-wire bitmap emitted by a sender for use at the
next round boundary.

At node `i`, the received sound bitmaps form a local **sound matrix**
`sound_matrix_i^r`.

The `j`-th row of the sound matrix is denoted:

```text
row_i^r[j]
```

A nonzero row must satisfy self-inclusion:

```text
row_j != 0 => row_j contains j
```

### 3.3 Agreed Row

For node `i` in round `r`, a nonzero bitmap `R_i^r` is an **agreed row** if
at least `Q` sender rows in `sound_matrix_i^r` are identical to `R_i^r`:

```text
| { j in M | row_i^r[j] = R_i^r } | >= Q
```

The local node only acts on an agreed row supported by a quorum that includes
its own sender row. Equivalently, the agreed row must equal the local
self-row `row_i^r[i]`.

### 3.4 Sound Set

Once node `i` identifies an agreed row `R_i^r`, it derives the
**sound set**

```text
SoundSet_i^r = { j in M | row_i^r[j] = R_i^r }
```

This is the local fast-path membership that may continue in the next round.

### 3.5 Commit Set

The same agreed row yields the **commit set**

```text
CommitSet_i^r = { k in M | R_i^r[k] = 1 }
```

This is the set of log owners whose old-epoch entries are safe to commit.

### 3.6 Inheritance Rule

Continuation is shrink-only:

```text
SoundSet_i^r subseteq SoundSet_i^(r-1)
```

The dataplane may shrink the fast-path membership by itself, but it may not
re-grow it. Any re-growth or re-entry remains a control-plane action.

### 3.7 HaltRecord

When a node enters `HALTED`, it preserves:

```text
HaltRecord =
(
  installed_membership_epoch,
  run_id,
  committed_frontier,
  commit_authoritative_group,
  log_digest,
  halt_reason
)
```

This metadata is exported to the control plane as part of a `NodeHalted`
interruption.

## 4. Node State

Each node stores:

- `node_id`;
- dataplane state: `FAST_PATH`, `HALTED`, or injected `CRASHED` in the
  simulator;
- `installed_membership_epoch`;
- installed membership bitmap `chi(M)`;
- current local sound set bitmap;
- current `run_id`;
- stage-local row evidence;
- committed frontier and log;
- optional halt record.

The current simulator uses a three-stage pipeline:

- `current_stage`
- `evidence_stage`
- `commit_stage`

and also tracks the current sound set as a local bitmap.

## 5. Messages

### 5.1 Dataplane Packet

A dataplane packet contains:

```text
DataplanePacket =
(
  round_id,
  src_id,
  run_id,
  sound_bitmap,
  payload
)
```

`run_id` is the wire-level protection against old-run replay.

### 5.2 Interruption Export

When a node halts, it exports its `HaltRecord` to the control plane.

When a node crashes, it exports a `NodeCrashed` interruption.

### 5.3 Recovery Messages

Recovery messages remain control-plane messages. They may install membership,
repair prefixes, authorize join rounds, and install fresh `run_id`s.

These messages do not count as dataplane evidence.

## 6. Dataplane Transition Rule

At a validation point, node `i` evaluates its local sound matrix and applies:

```text
1. identify an agreed row R_i^r
2. derive SoundSet_i^r  = { j | row_i^r[j] = R_i^r }
3. derive CommitSet_i^r = { k | R_i^r[k] = 1 }
```

The decision rule is:

```text
if no agreed row R_i^r exists:
    HALT

elif i notin SoundSet_i^r:
    HALT

elif SoundSet_i^r is not a subset of SoundSet_i^(r-1):
    HALT

else:
    COMMIT old round-state on CommitSet_i^r
    CONTINUE on SoundSet_i^r
```

If the node continues, then in the next round it communicates only with nodes
in `SoundSet_i^r`.

## 7. Control Plane

The control plane is responsible for:

- receiving node interruptions from the cluster scheduler;
- selecting a maximal admissible committed prefix;
- repairing interrupted nodes to that prefix;
- preparing a future rejoin configuration;
- collecting `PrepareAck`s from the future membership;
- committing that future configuration;
- assigning a fresh global `run_id`;
- authorizing re-entry at a future round boundary.

The dataplane does not reintroduce interrupted nodes by itself.

The current APSys simulator uses one control-plane strategy:

```text
interruption
-> mark_recovering
-> repair_log installation
-> prepare future config
-> collect PrepareAck
-> commit future config
-> locally activate at effective_round
```

Actual interaction remains cluster-mediated:

```text
node emits interruption
-> cluster timestamps and forwards it
-> control plane updates authoritative state
-> cluster writes per-node control-plane transactions
-> node consumes the transaction at round start
```

## 8. 3-Node Interpretation

For `M = {0,1,2}` and `Q = 2`, the current clean runnable shapes are:

```text
111,111,111
011,011,000
101,000,101
000,110,110
```

These shapes are now continuation-only shapes. They no longer carry the full
old-commit burden.

This means the dataplane may now:

- safely commit old epochs even if later sender survival is incomplete; and
- still halt conservatively on ambiguous continuation.

## 9. Boundary of This Version

This version does not yet claim:

- a completed general-`n` theorem;
- or a finished hardware implementation.

It records the current protocol core that now matches the simulator:

- agreed-row / sound-set dataplane evaluation;
- strict continuation;
- monotone shrinkage;
- interruption export on crash or halt;
- and interruption-driven online rejoin through prepare/ack/commit cutover.
