# APSys Closeout Checklist

Last updated: 2026-05-04

This checklist tracks the work required to turn the current SynCons simulator
and documentation into a coherent APSys submission-quality artifact.

The ordering is intentional: items near the top matter more than items near the
bottom.

## P0. Semantic Closure

- [x] Unify the simulator around one control-plane implementation:
  `OnlineRejoinControlPlane`
- [x] Route all node/control-plane interaction through `ClusterRun`
- [x] Treat both `NodeCrashed` and `NodeHalted` as interruption sources
- [x] Support halt-triggered online rejoin in the simulator
- [x] Update the main protocol/control-plane docs to describe the current
  interruption-driven online rejoin semantics
- [ ] Archive or clearly relabel older notes that still present the old
  witness-core / stop-the-world line as if it were current

## P1. Evaluation Closure

- [ ] Export stable summary metrics for:
  - interruption-to-recovery latency
  - repair latency
  - prepare-to-ack latency
  - commit-to-activation latency
  - cutover warm-up gap
  - steady-state commit throughput
- [ ] Lock a paper-facing scenario suite:
  - perfect
  - crash-induced shrink
  - halt-triggered rejoin
  - online rejoin after crash
  - quorum-loss / out-of-model sanity check
- [ ] Make the eval scripts produce one-command CSVs and plots for the final
  paper figures

## P2. Code Readability and Spec Quality

- [ ] Deduplicate halt-record construction in `sim/protocol/node.py`
- [ ] Further factor `sim/control/control_plane.py` into:
  - interruption intake
  - repair planning
  - prepare/ack/commit state machine
  - activation logic
- [ ] Split trace rendering helpers out of `sim/runtime/cli.py` if that file
  grows much further

## P3. Docs and Paper Surface

- [ ] Make `docs/README.md` point only to the current agreed-row / sound-set /
  interruption-driven line as the canonical APSys story
- [ ] Relabel older notes as archival or historical where appropriate
- [ ] Keep one short simulator architecture note aligned with the codebase
- [ ] Keep one short protocol naming note aligned with the codebase

## P4. Nice-to-Have Polishing

- [ ] Add a compact control-plane action timeline summary to CLI output
- [ ] Add a derived “same log digest across active nodes” summary for traces
- [ ] Add a one-page implementation note mapping simulator objects to the
  intended FPGA/driver/control-plane deployment split

## Current Focus

The active closeout item is:

```text
P0 semantic closure: unify the docs/spec around interruption-driven online rejoin
```
