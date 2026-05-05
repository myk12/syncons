# SynCons Protocol Naming

Status: naming baseline for the current protocol revision

This note defines the preferred protocol vocabulary for SynCons. Its purpose is
to align the paper, simulator, and eventual FPGA-oriented implementation around
one set of names before larger text and code migrations.

The central naming decision is:

```text
sound set
```

This is the primary dataplane object for next-round continuation.

## 1. Design Principle

SynCons separates two different questions:

1. what old state is safe to commit; and
2. who may safely continue into the next round.

The protocol therefore exposes two different sets:

- the **commit set**
- the **sound set**

The name **sound set** is preferred because it is:

- short;
- easy to use in prose and code;
- explicit about correctness and safety;
- not tied to one particular proof mechanism such as quorum, witness, or
  certification terminology.

## 2. Core Terms

### 2.1 Self Row

The **self row** of node `i` in round `r` is the local row contributed by node
`i` itself:

```text
self_row_i^r = row_i^r[i]
```

This is the local row on which node `i` bases certification.

### 2.2 Agreed Row

An **agreed row** is a nonzero row value supported by a quorum of identical
sender rows and equal to the local self row.

This object determines both old-state commit authority and next-round
continuation authority.

### 2.3 Commit Set

The **commit set** is the set of log owners named by the 1-bits of the
agreed row:

```text
CommitSet_i^r = { k in M | AgreedRow_i^r[k] = 1 }
```

It answers:

```text
what old-round entries are safe to commit?
```

### 2.4 Sound Set

The **sound set** is the set of nodes with which a node may safely continue
into the next round.

Operationally, for node `i` in round `r`, it is the set of senders whose local
rows equal the agreed row:

```text
SoundSet_i^r = { j in M | row_i^r[j] = AgreedRow_i^r }
```

It answers:

```text
who may safely continue together in the next round?
```

### 2.5 Sound Bitmap

The **sound bitmap** is the wire encoding of a node's sound set.

At round `r`, node `i` computes its local sound set at the round boundary and
then emits its sound bitmap for use in round `r+1`.

### 2.6 Sound Matrix

The **sound matrix** is the local matrix formed by the sound bitmaps received
from the installed membership.

For node `i` in round `r`, the `j`-th row of the sound matrix is:

```text
sound_matrix_i^r[j]
```

It is either the sound bitmap sent by node `j`, or zero if no row from `j` is
available locally.

Crucially, the sound matrix used at round `r` is composed of sound bitmaps
emitted in the previous round. Thus:

```text
previous-round sound matrix
-> agreed row
-> commit set + current sound set
-> current sound bitmap
-> next-round sound matrix
```

## 3. Recommended Name Table

The following table gives the preferred names for the current protocol.

| Concept | Preferred Name | Notes |
| --- | --- | --- |
| local row of the node itself | `self row` / `self_row` | local certification anchor |
| quorum-supported row value equal to the self row | `agreed row` / `agreed_row` | local consensus row object |
| old-state commit object | `commit set` / `commit_set` | derived from 1-bits of agreed row |
| next-round continuation object | `sound set` / `sound_set` | core dataplane continuation object |
| wire encoding of the sound set | `sound bitmap` / `sound_bitmap` | packet-carried continuation object |
| local matrix of received sound bitmaps | `sound matrix` / `sound_matrix` | local row evidence object |
| CP-installed configuration | `installed membership` / `installed_membership` | authoritative configuration boundary |
| configuration version | `membership epoch` / `membership_epoch` | CP version number |
| dataplane execution generation | `run id` / `run_id` | fresh on reinstall or coordinated cutover |
| global synchronous dataplane round counter | `round id` / `round_id` | shared virtual time / slot counter |

## 4. Recommended Prose

The following sentences are the preferred short forms for the protocol story.

### 4.1 Core split

```text
The protocol separates commit authority from continuation authority:
the commit set determines what old state is safe to commit,
while the sound set determines who may safely continue.
```

### 4.2 Row derivation

```text
Each node derives an agreed row from its self row.
The agreed row determines both the commit set and the sound set.
```

### 4.3 Packet-level story

```text
Each node exchanges its sound bitmap, the bitmap encoding of its local sound set.
```

```text
Each node locally collects a sound matrix, whose rows are the sound bitmaps
received from other members.
```

```text
The current round's commit set is derived from the previous round's sound matrix,
while the current round's sound set is transmitted forward as the next round's
sound bitmap.
```

### 4.4 Shrink-only continuation

```text
The sound set evolves by shrinkage only.
A node may continue only if its newly derived sound set is a subset of its
previous sound set.
```

## 5. Migration Guidance

The current codebase and notes still contain older terms, especially:

- `witness core`
- `current_witness_core`
- `previous_witness_core`
- `ack bitmap`
- `ack matrix`
- `certified row`
- `epoch id`

These should be interpreted as legacy names pending migration toward:

- `sound set`
- `current_sound_set`
- `previous_sound_set`
- `sound bitmap`
- `sound matrix`
- `agreed row`
- `round id`

The migration should proceed in two phases:

1. update paper/spec language first;
2. rename simulator objects after the protocol semantics are fully settled.

## 6. Scope of This Naming Decision

This note defines both vocabulary and the intended packet-level meaning of the
dataplane bitmap:

- the packet carries the locally derived continuation object itself; and
- this object is named the `sound bitmap`.

That sound bitmap is emitted in one round and consumed as row evidence in the
next round's sound matrix.
