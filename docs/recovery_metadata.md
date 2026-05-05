# Recovery Metadata

Last updated: 2026-05-05

This note describes the recovery metadata preserved when a SynCons node emits
an interruption such as `NodeHalted` or `NodeCrashed`.

In the current simulator this metadata is carried primarily by `HaltRecord` and
is used for:

- debugging fail-stop decisions
- comparing interrupted nodes' committed prefixes
- selecting and validating repair inputs
- explaining why a recovering node is being repaired to a particular prefix


## 1. Design Goal

When a node interrupts, the system should preserve enough information to answer
three questions:

1. how far did this node get?
2. under which sound-set lineage was that prefix committed?
3. why did the node stop?

The metadata should therefore support:

- prefix comparison across interrupted nodes
- identification of the commit-authoritative lineage
- safe repair and rejoin planning


## 2. Current Core Fields

The current simulator-level recovery record includes the following core fields.

### `committed_frontier`

The highest protocol-committed round known to the node when it interrupted.

Purpose:

- provides the primary ordering key across candidate repair sources
- tells the control plane how far the node's committed history extends

### `sound_set_lineage`

The sound set associated with the node's latest committed lineage.

Purpose:

- ties the committed prefix to the dataplane continuation lineage that produced it
- helps explain shrinkage across interrupted and surviving nodes

### `installed_membership_epoch`

The authoritative configuration version active when the node interrupted.

Purpose:

- separates prefixes that were produced under different control-plane
  configurations
- prevents cross-epoch confusion during repair

### `run_id`

The dataplane execution era active when the node interrupted.

Purpose:

- prevents stale state from older runs being confused with the current run
- anchors recovery metadata to the correct cutover lineage

### `halt_reason`

The reason the node entered the interruption path.

Examples include:

- no agreed row
- local node excluded from sound set
- sound-set regrowth
- explicit crash

Purpose:

- distinguishes ambiguity-driven fail-stop from other causes
- supports debugging, auditing, and scenario analysis


## 3. Evidence and Integrity Fields

These fields are not just for debugging. They help confirm that a chosen repair
source is internally consistent with the local interruption.

### `observation_rows`

The local round-boundary row view used when the node made its halt decision.

Purpose:

- captures the local evidence shape that led to interruption
- helps explain why a node halted instead of continuing

### `self_row`

The node's own row at the point of interruption.

Purpose:

- identifies the local row value from which agreement failed or succeeded
- makes local-vs-global disagreement easier to inspect

### `log_digest`

A compact digest of the node's committed history.

Purpose:

- provides a cheap equality check across recovering nodes
- keeps traces and recovery comparisons compact


## 4. Current Recovery Interpretation

In the current APSys simulator line, recovery planning is intentionally simple:

1. the control plane observes interruptions through the cluster
2. recovering nodes are given repair logs derived from live dataplane snapshots
3. the repair source is chosen by a conservative policy
4. nodes reinstall the repaired committed prefix before rejoin coordination

The current repair-source policy is:

> choose the longest available committed prefix among live dataplane snapshots

This is a control-plane policy choice, not a dataplane safety theorem.


## 5. Relationship to the Current Code

The current implementation exposes this metadata through:

- `HaltRecord` in [sim/protocol/types.py](/Users/mayuke/Project/syncons/sim/protocol/types.py)
- node-side halt transitions in [sim/protocol/node.py](/Users/mayuke/Project/syncons/sim/protocol/node.py)
- control-plane recovery planning in [sim/control/control_plane.py](/Users/mayuke/Project/syncons/sim/control/control_plane.py)

This is enough for the current APSys prototype because the control plane is not
trying to reconstruct arbitrary partial histories. It is using interrupted-node
metadata plus live committed snapshots to drive conservative repair and
future-round rejoin.
