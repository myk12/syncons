# Simulator Architecture

Last updated: 2026-05-04

This note describes the intended simulator architecture after the `sim/core`
split was removed.

## 1. Package Layout

The simulator is organized by responsibility under `sim/`:

- `sim/protocol/`
  - protocol datatypes
  - single-node dataplane logic
- `sim/runtime/`
  - multi-node execution harness
  - CLI rendering
  - randomized campaign driver
- `sim/control/`
  - the single online-rejoin control-plane runtime
  - repair and cutover workflows
- `sim/scenarios/`
  - built-in scenarios
  - fault models

Thin entrypoints remain at:

- `sim/syncons.py`
- `sim/run_scenario.py`
- `sim/random_campaign.py`

## 2. Responsibility Boundaries

### 2.1 `sim/protocol`

This layer defines protocol objects and node-local behavior.

- `types.py`
  - `Packet`
  - `Delivery`
  - `PendingConfig`
  - `ControlPlaneState`
  - `ScenarioExpectation`
- `node.py`
  - `agreed_row`
  - `commit_set`
  - `sound_set`
  - `advance_round()`
  - `receive()`

This layer should not decide:

- network scheduling policy
- cluster-wide packet ordering
- control-plane repair strategy

### 2.2 `sim/runtime`

This layer is the execution framework.

- `cluster.py`
  - drives rounds
  - owns the control-plane actor
  - mediates all node/control-plane interaction
  - timestamps control-plane events
  - enqueues outbound packets
  - applies network-fault behavior at delivery time
- `cli.py`
  - summary rendering
  - detailed round trace formatting
- `random_campaign.py`
  - randomized robustness sweeps

This layer should not define protocol semantics. It executes them.

In particular, `ClusterRun` delivers control-plane intent to each node as a
per-round aggregated `ControlPlaneTransaction`. This is intentionally more
coarse-grained than a final hardware mailbox or register interface, but it is
the right abstraction level for the APSys prototype: cluster remains the sole
mediator between node and control plane, while the node still semantically
interacts with control-plane state.

`ClusterRun` also supports two recording profiles:

- `debug`
  - preserves full `event_log`, `round_trace`, membership history, and
    per-node local traces
- `eval`
  - suppresses heavyweight debug artifacts and keeps only the lightweight
    result state needed for long-running sweeps and performance plots

This split lets the simulator stay round-accurate while avoiding excessive
memory growth during APSys-scale evaluation runs with millisecond-class
control-plane delays.

### 2.3 `sim/control`

This layer owns recovery and reconfiguration policy.

- interruption-driven online rejoin
- prepare/ack/commit timing
- repair-prefix planning

It should own recovery planning, including:

- when repair is needed
- what prefix to repair to
- when a pending configuration becomes prepared or committed

### 2.4 `sim/scenarios`

This layer owns:

- named built-in scenarios
- packet fault models
- node fault schedules

It should stay declarative.

## 3. Current Architecture Strengths

- dataplane logic is concentrated in `sim/protocol/node.py`
- cluster scheduling is concentrated in `sim/runtime/cluster.py`
- control-plane state machines are explicit rather than implicit
- trace output is now rich enough to explain protocol behavior directly

## 4. Current Architectural Risks

### 4.1 Some historical aliases remain in public APIs

Examples:

- `RoundStage`
- `ScenarioSpec.rounds`
- `ClusterRun.rounds`
- CLI `--rounds`

The simulator now reasons primarily in rounds, so the main remaining cleanup is
to keep `--epochs` / `--epoch-length` only as compatibility aliases.

### 4.2 Many proof and draft notes still describe older terminology

The simulator has already moved toward:

- `agreed_row`
- `sound_set`
- `sound_bitmap`
- `round`

but several design and proof notes still speak in older
`certified-row / witness-core / epoch` language.

## 5. Recommended Next Refactors

1. Keep `--epochs` / `--epoch-length` only as compatibility aliases while the rest of the public interface speaks in `rounds`
2. Archive or relabel old proof/draft notes so the docs index points to only one
   main protocol line
3. If trace complexity keeps growing, split rendering helpers out of
   `sim/runtime/cli.py`
