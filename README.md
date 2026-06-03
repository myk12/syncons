<<<<<<< HEAD
# Protocol Simulator Prototype

This repository contains an experimental distributed-protocol simulator and an
early FPGA-oriented prototype path. The current tree includes:

- a round-based multi-node simulator;
- recovery and reconfiguration scaffolding;
- an early hardware-oriented prototype path.

## Repository Layout

- `sim/` — protocol simulator
  - `protocol/` node-local protocol logic
  - `runtime/` multi-node execution harness and CLI
  - `control/` recovery and reconfiguration logic
  - `scenarios/` built-in fault scenarios
- `eval/` — reproducible evaluation entrypoints, scripts, and results
- `tests/` — regression and invariant checks
- `prototype/fpga/` — RTL sketches and simple testbenches
- `docs/` — current protocol and architecture notes

## Quick Start

Install dependencies and run the test suite:

```bash
python3 -m pip install -r requirements-dev.txt
python3 -m pytest
```

Run the core built-in scenarios:

```bash
python3 sim/syncons.py perfect
python3 sim/run_scenario.py asymmetric_loss --check
python3 sim/run_scenario.py bridge_partition --check
python3 sim/run_scenario.py controlled_rejoin --check
```

## Prototype Path

The `prototype/fpga/` subtree is an early hardware-oriented path for selected
protocol logic. It is not a complete deployment implementation, but it captures
the current direction of the hardware-facing exploration.

## Further Reading

Start with:

- [docs/simulator_architecture.md](docs/simulator_architecture.md)
=======
# SSR

SSR is a research prototype for synchronous state machine replication with a
split protocol design in modern datacenters. The repository contains:

- a round-based protocol simulator with a synchronous fast path and an
  asynchronous host-side recovery path;
- an early FPGA-oriented prototype path for the data plane.

## Repository Layout

- `sim/` — protocol simulator
  - `protocol/` node-local fast-path logic
  - `runtime/` multi-node execution harness and CLI
  - `control/` recovery and reconfiguration logic
  - `scenarios/` built-in fault scenarios
- `tests/` — regression and invariant checks
- `prototype/fpga/` — RTL sketches and simple testbenches
- `docs/` — current protocol and architecture notes

## Quick Start

Install dependencies and run the test suite:

```bash
python3 -m pip install -r requirements-dev.txt
python3 -m pytest
```

Run the core built-in scenarios:

```bash
python3 sim/run_scenario.py perfect --check
python3 sim/run_scenario.py asymmetric_loss --check
python3 sim/run_scenario.py bridge_partition --check  # split-view partition
python3 sim/run_scenario.py controlled_rejoin --check
```

## Key Concepts

SSR separates replication by timing requirement:

- the **data plane** executes the tightly bounded normal-case fast path;
- the **control plane** handles interruption, state transfer, configuration
  commit, and future-round restart.

The fast path derives both a **commit set** and a **sound set** from per-round
local evidence. It continues only when safe continuation is justified;
otherwise it fail-stops and defers liveness restoration to the control plane.

## Prototype Path

The `prototype/fpga/` subtree is an early hardware-oriented path for the data
plane. It is not a complete deployment implementation, but it shows how
the synchronous fast path can map onto an FPGA- or SmartNIC-class substrate.

## Further Reading

Start with:

- [docs/protocol_spec.md](docs/protocol_spec.md)
- [docs/reconfiguration.md](docs/reconfiguration.md)
- [docs/simulator_architecture.md](docs/simulator_architecture.md)
>>>>>>> 45bffb18676507d8032deadab249c9b64ef2cb1a
