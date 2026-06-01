# Simulator Architecture

The simulator is organized by responsibility under `sim/`:

- `sim/protocol/`
  - protocol datatypes;
  - single-node fast-path logic.
- `sim/runtime/`
  - multi-node execution harness;
  - packet delivery and scheduling;
  - CLI output and randomized campaigns.
- `sim/control/`
  - interruption handling;
  - repair planning;
  - prepare/commit/activation state machine.
- `sim/scenarios/`
  - built-in scenario definitions;
  - packet and node fault models.

Thin entrypoints remain at:

- `sim/syncons.py`
- `sim/run_scenario.py`
- `sim/random_campaign.py`

## Responsibility Boundaries

### `sim/protocol`

This layer defines node-local protocol behavior. It owns row processing,
commit-set derivation, sound-set derivation, and halt decisions. It does not
decide network scheduling or recovery policy.

### `sim/runtime`

This layer executes the protocol across multiple replicas. `ClusterRun` owns
round advancement, packet delivery, trace collection, and all mediation between
nodes and the control plane. Nodes emit logical control events; the runtime
timestamps and forwards them.

### `sim/control`

This layer owns recovery and reconfiguration policy. It chooses repair targets,
constructs renewed configurations, coordinates prepare/commit, and authorizes
future-round activation.

### `sim/scenarios`

This layer keeps scenario setup declarative: named workloads, injected node
faults, and packet fault behavior live here rather than in the runtime or node
logic.
