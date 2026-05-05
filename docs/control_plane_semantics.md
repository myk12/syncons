# Control-Plane Semantics: Interruption-Driven Online Rejoin

Last updated: 2026-05-04

This note defines the current control-plane semantics for the APSys simulator
line of SynCons.

The key design decision is:

```text
the simulator exposes one control-plane strategy:
interruption-driven online rejoin
```

The same control-plane runtime is used after either:

- `NodeCrashed`; or
- `NodeHalted`.

There is no second simulator runtime that models a separate stop-the-world
reinstall path.

## 1. Interruption Model

The control plane receives **interruptions** from nodes through the cluster
scheduler.

The current control-plane event types are:

- `NodeCrashed`
- `NodeHalted`
- `PrepareAck`

`NodeCrashed` and `NodeHalted` are recovery triggers.

`PrepareAck` is the acknowledgment used in the future-config two-phase commit.

The interaction path is:

```text
node emits control-plane event
-> cluster timestamps and forwards it
-> control plane observes it
-> control plane updates authoritative state
-> cluster writes per-node control-plane transactions
-> node consumes those transactions at round start
```

This keeps the node/control-plane semantics intact while ensuring that the
cluster owns all actual transport, timing, and mediation.

For the APSys simulator version, cluster-to-node delivery is modeled as a
single aggregated `ControlPlaneTransaction` per node per round, rather than as
a lower-level register-by-register or opcode-by-opcode hardware command
interface. This is a deliberate abstraction choice: it keeps the protocol
semantics clear while preserving the intended architectural split

```text
control plane decides
cluster mediates
node consumes a mailbox transaction
```

The current model is therefore intentionally more aggregated than a final
driver/FPGA interface, but it is sufficient for the APSys prototype.

## 2. Time Axes and Identifiers

The APSys version uses three distinct identifiers:

### 2.1 `membership_epoch`

`membership_epoch` is the control-plane configuration version.

### 2.2 `run_id`

`run_id` is the dataplane execution era. A fresh `run_id` is installed at each
coordinated rejoin cutover.

### 2.3 `round_id`

`round_id` is the globally meaningful synchronous round counter.

The dataplane identity is therefore:

```text
(run_id, round_id)
```

## 3. Current Control-Plane Workflow

After either `NodeCrashed` or `NodeHalted`, the current simulator follows:

```text
interruption observed
-> mark_recovering
-> select repair prefix
-> write repair log to interrupted node
-> prepare future config
-> collect PrepareAck from all future members
-> commit future config
-> local activation at effective_round
```

This workflow is intentionally conservative. It lets live nodes continue on the
old run when they still can, while also supporting the case where one node has
fail-stopped and must be repaired before rejoin.

## 4. Local Activation Rule

The control plane may prepare and commit a future configuration, but the actual
cutover still occurs locally at the node's round boundary:

```text
if pending_config exists
and pending_config.status == COMMITTED
and current_round >= pending_config.effective_round:
    activate pending_config locally
```

This preserves the intended implementation-facing separation:

```text
control plane authorizes
node locally switches
```

## 5. Recommended APSys Framing

For the current APSys version, the cleanest paper story is:

1. the dataplane may autonomously shrink;
2. the dataplane may not autonomously regrow;
3. crash or halt both produce interruption exports;
4. the control plane repairs interrupted nodes in the background;
5. re-entry occurs through a conservative prepare/ack/commit future-round
   cutover.

This is the control-plane line to treat as canonical in the current codebase.
