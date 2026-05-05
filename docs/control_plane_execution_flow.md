# Control-Plane Execution Flow

Last updated: 2026-05-05

This note explains the current SynCons control path as an execution flow rather
than as a file-by-file API reference. It is meant to align three views at once:

- the node-local protocol behavior in `sim/protocol/node.py`
- the cluster-mediated coordination path in `sim/runtime/cluster.py`
- the interruption-driven rejoin state machine in `sim/control/control_plane.py`

The current APSys simulator should be read as a two-speed system:

- the dataplane advances in short synchronous rounds
- the control plane reacts much more slowly, over many rounds

The key architectural boundary is:

> Nodes do not talk to the control plane directly. Nodes emit logical control
> events, and `ClusterRun` mediates all timing, transport, and mailbox writes.


## Phase 1: Steady-State Round Start

Each round begins at `round_start_ns = round_id * round_length_ns`.

At the beginning of a round:

1. `ClusterRun` advances the control plane to `round_start_ns`
2. the control plane applies any actions whose visibility time has arrived
3. the control plane produces its authoritative state for this round
4. `ClusterRun` writes per-node `ControlPlaneTransaction` mailbox snapshots
5. each node begins `advance_round(round_id)` and consumes mailbox work if an
   IRQ is pending

In steady state, the control plane is usually quiet:

- installed config remains unchanged
- no recovery targets exist
- no `pending_config` exists
- no repair logs are written

This is intentional. In the normal case, the control plane is a background
actor, not a per-round participant in the dataplane fast path.


## Phase 2: Node Interruption

An interruption can originate in two ways:

- `NodeCrashed`: a node fault model injects a crash at round start
- `NodeHalted`: the dataplane local boundary evaluation decides it must fail-stop

In both cases, the node:

1. updates its local status (`CRASHED` or `HALTED`)
2. records halt/crash metadata locally
3. emits a logical control-plane event into its local outbox

The node does not contact the control plane directly. It only emits one of:

- `NodeCrashed`
- `NodeHalted`
- `PrepareAck`


## Phase 3: Cluster-Mediated Event Delivery

After each node transition, `ClusterRun` drains the node's control-plane event
outbox.

For each emitted event, the cluster:

1. attaches the originating round
2. computes `available_at_ns`
3. applies reporting delay for interruptions
4. records the event in the trace
5. forwards it to the control plane runtime

This means the control plane observes timestamped events, not direct node
callbacks.

The important consequence is:

> Control-plane visibility is explicit and time-delayed, even though the
> simulator itself runs synchronously.


## Phase 4: Interruption Intake and Collection Window

When the control plane observes `NodeCrashed` or `NodeHalted`, it does not
immediately start rejoin.

Instead it:

1. marks the interrupted node as `FAILED` in authoritative control-plane state
2. places the node into either:
   - the currently open collection window, or
   - the queued interruption set
3. opens a collection window if the control plane is currently idle

The collection window lasts for `cp_collection_delay_ns`.

Its purpose is to batch nearby interruptions together, so that the control
plane does not start a separate rejoin transaction for every interrupted node.

At collection-window close:

1. the batched interruption targets are frozen as `episode_targets`
2. the episode membership is derived as:
   - current `ACTIVE` nodes
   - plus the frozen `episode_targets`
3. the control plane schedules:
   - `mark_recovering`
   - `prepare_online_rejoin`
   - `abort_online_rejoin`

This is the key fix that prevents the older deadlock pattern where a current
rejoin episode would wait on a node that had not actually been admitted into
that episode.


## Phase 5: Mark Recovering and Repair Log Installation

At `mark_recovering` time:

1. the control plane changes each episode target from `FAILED` to `RECOVERING`
2. the control plane refreshes `repair_logs` for nodes in
   `RECOVERING` or `REJOIN_PENDING`

Repair logs are selected from dataplane snapshots supplied by the cluster. The
current prototype uses a simple source-selection policy:

> choose the longest available committed prefix among live dataplane snapshots

This is a control-plane policy choice, not a dataplane safety rule.

Once the control plane state contains repair logs, the next round-start mailbox
write carries them down to nodes via `ControlPlaneTransaction`.

On the node side:

1. a halted/crashed node can reboot into `RUNNING` under control-plane
   management
2. a recovering node installs the repaired committed prefix if its current log
   does not already match
3. the node remains `RECOVERING`, and therefore still does not participate in
   active fast-path rounds


## Phase 6: Prepare Phase and `PrepareAck`

After `repair_delay_ns`, the control plane applies `prepare_online_rejoin`.

This creates a future `PendingConfig` with:

- a new `membership_epoch`
- the frozen `episode_members_bitmap`
- a new `run_id`
- a future `effective_round`
- `status = PREPARED`

At the same time, episode targets move from `RECOVERING` to
`REJOIN_PENDING`.

The cluster then writes this `PREPARED` future config into per-node
`ControlPlaneTransaction` mailboxes.

Each node emits `PrepareAck` exactly once when:

1. it consumes a mailbox transaction containing a `PREPARED` pending config
2. that config differs from the previously seen pending config

The acknowledgment carries the future config identity, including:

- `run_id`
- `effective_round`
- `members_bitmap`

This allows the control plane to reject stale or mismatched acknowledgments.


## Phase 7: Commit or Abort

The control plane tracks acknowledgments in `_prepare_acks`.

Commit happens only when:

> all nodes in the future episode membership have acknowledged the current
> `PREPARED` future config

When that happens, the control plane schedules `commit_online_rejoin` after
`cp_decision_delay_ns`.

`commit_online_rejoin`:

1. converts the future config from `PREPARED` to `COMMITTED`
2. ensures that `effective_round` is still safely in the future
3. leaves nodes waiting for local activation at that future round boundary

Abort happens if:

- the prepare phase is still unresolved when `abort_online_rejoin` fires
- meaning the pending future config is still `PREPARED`

Abort does **not** leave the system stuck in that state. Instead it:

1. clears the pending future config
2. returns episode targets to `FAILED`
3. requeues retry targets into the interruption intake path
4. starts a fresh collection window if the control plane is idle again

The intended guarantee is:

> A prepare episode may fail, but it must not deadlock forever.


## Phase 8: Local Activation and New Steady State

The actual cutover occurs at the node side, not by direct control-plane
mutation.

At the start of each round, a node first checks whether:

1. it has a `pending_config`
2. that config is `COMMITTED`
3. `round_id >= effective_round`

If so, the node:

1. installs the new membership epoch, membership bitmap, and run ID
2. clears the pending config
3. sets `membership_state = ACTIVE`
4. resets the dataplane pipeline

This reset is intentional. A rejoin cutover does not continue the old run's
pipeline; it starts a fresh pipeline in the new run.

In parallel, the control plane also activates its authoritative installed config
at the same `effective_round`.

After activation:

- all episode members are in the new run
- the dataplane pipeline warms up again
- first post-cutover commits appear after a short warm-up gap

This gives a clean split between:

- control-plane completion: future config becomes authoritative
- dataplane completion: the new run begins committing again


## Timing Interpretation

With realistic settings, control-plane latency can span hundreds of dataplane
rounds. This is expected.

For example, with:

- `round_length = 4us`
- `cp_collection_delay = 1ms`

the collection window alone spans roughly 250 dataplane rounds.

This is why the simulator keeps:

- round-accurate execution semantics

but now supports sparse trace presentation modes:

- `full`
- `event`
- `windowed`

The simulation should remain round-accurate even when the printed trace is no
longer full-round.


## Condensed End-to-End Flow

Putting the phases together:

```text
steady state
-> node interruption (HALT or CRASH)
-> cluster forwards timestamped interruption
-> control plane opens collection window
-> episode targets are frozen
-> mark_recovering
-> repair log installation
-> prepare future config
-> PrepareAck collection
-> commit future config
-> local activation at effective_round
-> warm-up gap
-> new steady state
```

This is the current canonical control execution flow for the APSys SynCons
simulator.
