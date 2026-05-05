# Online Cutover Protocol

Last updated: 2026-05-04

This note defines the current prepare/ack/commit protocol used by the SynCons
control plane to coordinate rejoin into a fresh run.

The same future-config workflow is used after either:

- background repair while the surviving dataplane remains live; or
- a dataplane interruption such as `NodeHalted`.

What changes is whether the surviving nodes keep serving on the old run while
repair is happening in the background.

## 1. Core Principle

```text
the control plane proposes and commits a future configuration,
but each node performs the actual cutover locally at a globally agreed round boundary
```

This is intentionally close to the intended FPGA/driver/control-plane
implementation split.

## 2. Objects

A coordinated rejoin operates on:

```text
FutureConfig = (
  membership_epoch',
  members_bitmap',
  run_id',
  effective_round
)
```

Each node may store:

```text
pending_config = (FutureConfig, status)
status in { PREPARED, COMMITTED }
```

## 3. Protocol Phases

### Phase 1: Prepare

The control plane chooses:

- the next membership;
- the next `membership_epoch`;
- the next `run_id`;
- a future `effective_round`.

It then distributes `FutureConfig` to all future participants.

Each node stores the configuration locally as:

```text
pending_config.status = PREPARED
```

and emits:

```text
PrepareAck
```

the first time it observes that prepared future configuration.

### Phase 2: Ack Collection

The control plane waits until all nodes in the future membership have
acknowledged the same prepared future configuration.

The APSys simulator line intentionally uses the conservative rule:

```text
all future members must acknowledge prepare
```

before the cutover may be committed.

### Phase 3: Commit

After collecting the required `PrepareAck`s, the control plane marks the future
configuration:

```text
pending_config.status = COMMITTED
```

If commit happens later than expected, the control plane may push
`effective_round` outward so that `COMMITTED` remains stably visible before
activation.

## 4. Local Activation Rule

At the beginning of each round, a node checks:

```text
if pending_config exists
and pending_config.status == COMMITTED
and current_round >= pending_config.effective_round:
    activate pending_config locally
```

Local activation atomically:

1. installs `membership_epoch'`;
2. installs `members_bitmap'`;
3. installs `run_id'`;
4. resets the dataplane pipeline;
5. clears `pending_config`.

## 5. Timing Interpretation

The protocol layering is:

```text
repair in background
-> prepare future config
-> collect PrepareAck
-> commit future config
-> wait until effective_round
-> node locally activates
```

This means:

- the control plane authorizes the future cutover;
- the node actually switches at its own round boundary.

## 6. Scope of This Note

This note describes the current APSys simulator line.

It does **not** define a second stop-the-world simulator mode. If the
dataplane has already produced a `NodeHalted` interruption, the current
simulator still resolves re-entry through the same conservative repair plus
prepare/ack/commit workflow.
