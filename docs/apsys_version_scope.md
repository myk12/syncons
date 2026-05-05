# APSys Version Scope

This note fixes the intended scope of the APSys submission. The goal is not to
present the final and fully optimized SynCons system, but to present a coherent
and executable systems design with a clear motivation, a conservative protocol
core, and a convincing correctness backbone.

## 1. Motivation

The starting observation is that modern datacenter networks are no longer the
dominant source of end-to-end timing variance. In particular, the
network-adjacent path between FPGA NICs and programmable switches can be highly
stable and close to lossless. By contrast, the host-side path still shows large
variance due to server software, PCIe, scheduling, and other non-network
effects.

This matters because a synchronous replicated state machine is only attractive
when the timing bound is small. If the protocol is placed on the host path, the
bound must absorb host- and PCIe-induced variance, which either forces a large
bound or requires explicit barrier-like synchronization. Both outcomes erase the
performance benefit of synchrony.

The key design opportunity is therefore not "make the whole system
synchronous," but rather:

- place the network-sensitive fast path inside the low-variance
  network-adjacent dataplane;
- keep the network-insensitive and ambiguity-resolution path in the control
  plane / software layer.

## 2. Problem Statement

Current datacenter replication protocols are predominantly asynchronous because
end-to-end execution remains highly variable. However, modern hardware exposes a
low-variance execution domain near the network. The challenge is to exploit
that domain without requiring the entire replicated state machine to operate
under the same tight timing assumptions.

This leads to the following problem:

> Can we build a synchronous replicated state machine whose fast path runs in a
> low-variance dataplane, while correctness is preserved by immediately
> fail-stopping on ambiguous states and deferring recovery and reconfiguration
> to a control plane?

## 3. Design Thesis

The APSys paper should argue the following thesis:

> Synchronous replication is viable in modern datacenters, but only when the
> synchronous fast path is placed inside the low-variance network-adjacent
> dataplane. Ambiguous states should not be resolved optimistically in the
> dataplane; instead, the dataplane should continue only on canonical clean
> evidence and otherwise fail-stop into control-plane recovery.

This thesis is the conceptual center of the submission.

## 4. Protocol Core for the APSys Version

The paper should focus on the minimal final protocol core:

- `local observation matrix` as the primary evidence object;
- `C1-C4` as the protocol-generation constraints;
- canonical clean-quorum continuation in the dataplane;
- a simplified two-state dataplane:
  - `FAST_PATH`
  - `HALTED`
- immediate fail-stop on any ambiguous local observation;
- control-plane recovery and control-plane-only re-entry.

The APSys version should not introduce intermediate dataplane states such as
`PROVISIONAL` or `DISCLOSURE`.

## 5. Must-Have Contents

The APSys paper should contain the following elements.

### 5.1 Clear motivation and measurement-backed premise

The paper must explain:

- why synchronous replication was traditionally unattractive in datacenters;
- why the network-adjacent path is now stable enough to support a small bound;
- why host/PCIe variance still prevents a whole-host synchronous design.

The earlier SOSP measurement results are useful here because they motivate the
placement decision rather than merely serve as a performance graph.

### 5.2 Protocol design

The paper must present:

- the split between dataplane and control plane;
- the local observation matrix;
- canonical clean-quorum continuation;
- immediate halt on ambiguity;
- recovery metadata and control-plane takeover.

### 5.3 Correctness backbone

The paper must contain a clear correctness argument, even if not fully formal.
At minimum it should cover:

- canonical group uniqueness;
- no mixed quorum from a canonical group;
- halt-on-ambiguity;
- monotone shrinkage of the live dataplane group;
- commit invariants and prefix comparability of halted states;
- maximal admissible prefix selection by the control plane.

The 3-node case should be used as the smallest non-trivial motivating example,
but the paper must make clear that the proof backbone is not specific to three
nodes.

### 5.4 Executable validation

The APSys version should include at least:

- a simulator aligned with the minimal protocol core;
- scenario-based validation for:
  - normal clean continuation,
  - asymmetric visibility / bridge ambiguity,
  - crash-induced shrinkage,
  - fail-stop and recovery-triggering cases.

## 6. Nice-to-Have Contents

These would strengthen the submission but should not delay the core story:

- a partially executable control-plane recovery path in the simulator;
- limited prototype evidence on FPGA / NIC / switch integration;
- a concise performance argument showing why a tight bound matters in practice.

## 7. Explicitly Out of Scope for the APSys Version

To keep the submission focused, the APSys version does not need:

- a complete FPGA and switch prototype of the full system;
- a fully formal general-`n` proof;
- aggressive dataplane ambiguity resolution mechanisms;
- complex intermediate dataplane states beyond `FAST_PATH` and `HALTED`;
- all possible optimizations for recovery metadata or recovery ordering.

## 8. Implementation Guidance

The implementation work after this scope freeze should be judged against one
question:

> Does this change strengthen the minimal fast-path / fail-stop / recovery story
> that the APSys paper is built around?

If not, it is probably not required for the APSys version.

## 9. Immediate Next Step

With this scope fixed, the next engineering priority is:

- align the simulator with the minimal final protocol core;
- then selectively implement enough of control-plane recovery to support the
  paper's evaluation and design claims.
