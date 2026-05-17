# SynCons

SynCons is a research prototype for split synchronous replication in modern
datacenters. The repository contains:

- a round-based protocol simulator with a synchronous dataplane and an
  asynchronous control plane;
- evaluation scripts and paper-facing figure generation helpers;
- an early FPGA-oriented prototype path for the dataplane.

## Repository Layout

- `sim/` — protocol simulator
  - `protocol/` node-local dataplane logic
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

Run randomized robustness sweeps:

```bash
python3 eval/scripts/run_random_sweeps.py
```

Run the paper-facing steady-state throughput evaluation end to end:

```bash
bash eval/run_steady_state_throughput.sh
```

Run the paper-facing recovery timeline evaluation end to end:

```bash
bash eval/run_recovery_timeline.sh
```

## Key Concepts

SynCons separates replication by timing requirement:

- the **dataplane** executes the tightly bounded normal-case fast path;
- the **control plane** handles interruption, repair, configuration commit, and
  future-round re-entry.

The dataplane derives both a **commit set** and a **sound set** from local
round-bounded evidence. It continues only when safe continuation is justified;
otherwise it fail-stops and defers liveness restoration to the control plane.

## Prototype Path

The `prototype/fpga/` subtree is an early hardware-oriented path for the
dataplane. It is not a complete deployment implementation, but it shows how
the synchronous fast path can map onto an FPGA- or SmartNIC-class substrate.

## Further Reading

Start with:

- [docs/protocol_spec.md](docs/protocol_spec.md)
- [docs/reconfiguration.md](docs/reconfiguration.md)
- [docs/simulator_architecture.md](docs/simulator_architecture.md)
