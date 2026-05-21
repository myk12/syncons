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
