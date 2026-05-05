# Docs Index

Last updated: 2026-05-05

This directory was pruned in May 2026 to keep only the active APSys-facing
documents. Older witness-core notes, paper drafts, and superseded simulator
refactor notes were removed once their useful content had been folded into the
current canonical line.

If you are reloading context on the current codebase, read the documents below
in roughly this order.

## 1. Protocol and Control Flow

- [protocol_spec.md](/Users/mayuke/Project/syncons/docs/protocol_spec.md)  
  The authoritative end-to-end protocol specification.

- [protocol_naming.md](/Users/mayuke/Project/syncons/docs/protocol_naming.md)  
  The naming baseline shared by the simulator, paper, and implementation notes.

- [control_plane_semantics.md](/Users/mayuke/Project/syncons/docs/control_plane_semantics.md)  
  The current interruption-driven online rejoin semantics and identifier model.

- [control_plane_execution_flow.md](/Users/mayuke/Project/syncons/docs/control_plane_execution_flow.md)  
  The execution-flow view of interruption intake, batching, repair,
  prepare/ack/commit, and future-round activation.

- [online_cutover_protocol.md](/Users/mayuke/Project/syncons/docs/online_cutover_protocol.md)  
  The conservative prepare/ack/commit future-round cutover workflow.

## 2. Supporting Semantics

- [commit_semantics.md](/Users/mayuke/Project/syncons/docs/commit_semantics.md)  
  The current definition of protocol commit and externalized commit.

- [recovery_metadata.md](/Users/mayuke/Project/syncons/docs/recovery_metadata.md)  
  The halt/interruption metadata preserved for recovery ordering and repair.

## 3. Simulator and Engineering

- [simulator_architecture.md](/Users/mayuke/Project/syncons/docs/simulator_architecture.md)  
  Package layout and responsibility boundaries across `sim/protocol`,
  `sim/runtime`, `sim/control`, and `sim/scenarios`.

- [codebase_review_2026_05.md](/Users/mayuke/Project/syncons/docs/codebase_review_2026_05.md)  
  The current engineering assessment of the simulator after the APSys refactor.

## 4. APSys Planning

- [apsys_version_scope.md](/Users/mayuke/Project/syncons/docs/apsys_version_scope.md)  
  The intended APSys scope and design thesis.

- [apsys_evaluation_plan.md](/Users/mayuke/Project/syncons/docs/apsys_evaluation_plan.md)  
  The fixed evaluation scope for the APSys version.

- [apsys_closeout_checklist.md](/Users/mayuke/Project/syncons/docs/apsys_closeout_checklist.md)  
  The prioritized closeout checklist for the APSys artifact.
