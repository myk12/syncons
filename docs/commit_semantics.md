# Commit Semantics for SynCons

Last updated: 2026-05-05

This note defines the intended meaning of "commit" in the current APSys
simulator line of SynCons.

It is narrower and more implementation-facing than older proof notes. The goal
here is simply to make the current simulator and paper use the same commit
language when we talk about:

- what the dataplane can treat as protocol-final
- what may be surfaced outside the dataplane
- what a recovering node may safely reinstall as committed history

## 1. Why Commit Needs Its Own Definition

In the current protocol design, a node may:

- observe local round-boundary evidence,
- continue on an agreed row and sound set,
- later halt or crash,
- and eventually expose its committed state to the control plane for repair.

To reason correctly about these transitions, we must distinguish at least three different notions:

1. local evidence that *could* support future progress;
2. a protocol-level committed prefix;
3. an externally visible committed prefix.

These are not the same.

## 2. Three Commit Layers

### Layer A: Local Boundary Evidence

A node has **local boundary evidence** for prefix `P` if its current
round-boundary state suggests that `P` may be extendable under the current
agreed-row / sound-set decision.

This is the weakest notion. It means only:

- the node has enough local evidence to continue in the dataplane fast path
- not that `P` is already final
- not that `P` is already safe to expose outside the dataplane

Local boundary evidence is therefore not commit.

### Layer B: Protocol Commit

A prefix `P` is **protocol-committed** if:

1. `P` was produced while the node was in `FAST_PATH` on some canonical clean quorum group `S`;
2. the extension that produced `P` was justified by an agreed row whose
   corresponding `commit_set` was locally valid;
3. the node has crossed the protocol-defined round boundary at which that
   `commit_set` becomes final.

Interpretation:
- `P` is a committed prefix according to the internal rules of the dataplane;
- it is not merely tentative local motion;
- but it may still need additional conditions before being exposed to clients or upper layers.

This is the notion stored in `CommittedRoundEntry` and used by control-plane
repair.

### Layer C: Externalized Commit

A prefix `P` is **externalized** if:

1. it is already protocol-committed; and
2. the protocol permits the node to expose `P` outside the dataplane as final.

Examples of exposure include:
- replying to clients;
- handing the prefix to an upper replication layer as final;
- or treating the prefix as irrevocably visible system state.

The protocol may impose stricter rules on externalization than on internal protocol commit.

## 3. Current Design Choice

The current SynCons direction is intentionally conservative:

```text
ambiguous states halt immediately;
only agreed-row / sound-set execution remains in FAST_PATH
```

Under this design, protocol commit is always scoped to the currently active
sound-set lineage of the dataplane.

This means:
- no protocol commit may be derived from mixed evidence;
- no protocol commit may be derived from nodes outside the current canonical group;
- and once the node can no longer justify commit under that group, it halts instead of continuing under reinterpretation.

## 4. Commit-Authoritative Quorum

### Definition

For a protocol-committed prefix `P`, a quorum group `S` is **commit-authoritative** if:

1. `S` is the canonical clean quorum group active at the time `P` is committed;
2. only members of `S` contribute commit-relevant evidence for `P`;
3. all later commit extension of `P` while remaining in `FAST_PATH` is also scoped to the current canonical group derived from the monotone shrinkage chain.

This ties every protocol-committed prefix to a specific canonical group in the shrinkage chain.

## 5. Commit Scope Invariant

### Invariant CS-1

Every protocol-committed prefix is committed under exactly one commit-authoritative canonical group at the moment of commit.

### Reason

The local continuation rule permits only one canonical clean quorum at a time, and ambiguous states halt instead of allowing multiple interpretations.

Therefore protocol commit is not quorum-agnostic. It is always attached to the currently active canonical group.

## 6. Halt Does Not Revoke Protocol Commit

### Invariant CS-2

If a node halts after protocol-committing prefix `P`, then the halt does not revoke `P`.

Interpretation:
- halting prevents new fast-path commit;
- it does not invalidate already protocol-committed prefix.

This matters for recovery. Otherwise there would be no stable object for the control plane to recover.

## 7. Shrinkage and Commit Extension

### Invariant CS-3

If a later canonical group `T` extends execution after shrinkage from an earlier canonical group `S`, then any later protocol-committed prefix must extend, not replace, the earlier committed prefix.

This is the commit-semantic version of the monotone-shrinkage principle.

It implies:
- group shrinkage may reduce participants;
- but it does not create a new conflicting committed history.

## 8. Prefix-Comparability Consequence

Using CS-1, CS-2, and CS-3, the earlier prefix-comparability theorem can now be stated more precisely:

### Consequence

For any two halted nodes carrying protocol-committed prefixes `P_i` and `P_j`, those prefixes are prefix-comparable.

Reason:
- each prefix was committed under some canonical group;
- group changes occur only through shrinkage, not branch reinterpretation;
- and later canonical groups extend earlier committed history.

Therefore halted committed states form a prefix chain rather than a set of incompatible branches.

## 9. Externalization Rule

The final protocol still needs to choose how conservative externalization should be.

The safest current choice is:

### Rule Candidate

A node may externalize prefix `P` only if:

1. `P` is protocol-committed; and
2. the node remains inside the currently active canonical clean quorum for the corresponding commit point.

Under the simplified state machine, any ambiguity triggers immediate halt. So externalized commit should arise only from clean canonical execution, never from ambiguous or mixed local evidence.

This matches the overall design philosophy.

## 10. Relationship to Recovery

Recovery does not need every halted node to carry the same committed prefix.

It needs something weaker:
- every halted node carries some protocol-committed prefix;
- those prefixes are prefix-comparable;
- and the control plane can choose the maximal one.

Thus the role of commit semantics in recovery is:
- to define the stable object that halt preserves; and
- to ensure that these objects form an ordered family rather than conflicting alternatives.

## 11. Immediate Next Step

The next useful design task is:

```text
define the exact recovery metadata stored at halt time
for selecting the maximal protocol-committed prefix
```

At minimum, this metadata must identify:
- the committed frontier;
- the commit-authoritative group;
- and enough evidence to justify recovery ordering.
