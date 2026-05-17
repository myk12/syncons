# SynCons Protocol Specification

This document defines the current protocol model implemented by the simulator
and targeted by the prototype hardware path.

## 1. System Split

SynCons is a split replicated state machine:

- the **dataplane** executes the synchronous fast path;
- the **control plane** handles interruption processing, recovery,
  reconfiguration, and re-entry.

The dataplane is responsible only for normal-case progress under bounded-round
execution. Whenever local evidence no longer justifies safe continuation, it
halts conservatively and transfers control to the asynchronous recovery path.

## 2. Core Dataplane Objects

The current dataplane protocol revolves around one local row value that yields
two distinct decisions:

```text
agreed row value       -> commit set
identical-row senders  -> sound set
```

The key terms are:

- **agreed row**: a quorum-supported nonzero row equal to the node's local row;
- **commit set**: the replicas named by the 1-bits of the agreed row;
- **sound set**: the replicas that may safely continue into the next round;
- **sound bitmap**: the wire encoding of the local sound set;
- **sound matrix**: the local matrix formed from received sound bitmaps.

The central dataplane rule is:

```text
identify an agreed row
commit the nodes named by that row
continue only with the senders that support that row
```

Continuation is shrink-only: a node may continue only if its newly derived
sound set is a subset of its previous sound set.

## 3. Timing and Membership

The dataplane executes in globally numbered rounds. At any time the control
plane installs:

- an authoritative membership set;
- a membership version;
- a `run_id` identifying the current dataplane run.

Only nodes in the installed membership participate in the dataplane. A fresh
`run_id` is installed whenever recovery commits a renewed configuration.

For membership `M`, the quorum size is:

```text
Q = floor(|M| / 2) + 1
```

## 4. Dataplane Safety Model

The dataplane explicitly tolerates packet loss, crash, halt, stale replay, and
asymmetric visibility by reducing them to one question: can the node still
prove safe continuation from round-bounded local evidence?

If yes, it commits and continues.
If no, it fail-stops and emits an interruption.

This conservative behavior is fundamental: liveness may fall back to the
control plane, but safety remains enforced by the dataplane's own distributed
rules rather than by assuming recovery always succeeds cleanly.

## 5. Control-Plane Interaction

Both `NodeHalted` and `NodeCrashed` enter the same control-plane recovery path.
The control plane repairs interrupted nodes from committed state, installs a
renewed configuration with a fresh `run_id`, and authorizes re-entry only at a
future activation round. Messages from other runs are ignored, so premature or
partial reconfiguration cannot create unsafe commits.
