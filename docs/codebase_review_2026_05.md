# Codebase Review (2026-05)

This note records the outcome of a full post-refactor review of the current
APSys-oriented SynCons prototype.

The goal of the review was not to redesign the protocol, but to verify that:

1. the current code matches the canonical agreed-row / sound-set protocol line,
2. node / cluster / control-plane boundaries are clean,
3. interruption-driven online rejoin behaves as intended, and
4. the simulator is in a good state for APSys evaluation work.

## 1. Overall Assessment

The current repository is no longer just a runnable protocol sketch. It is now
a structured research prototype with:

- a clear dataplane core,
- a cluster-mediated node/control-plane interaction model,
- interruption-driven online rejoin,
- typed internal protocol objects,
- and sufficiently strong trace/debug support for paper-facing analysis.

The hardest architectural work is largely done. Remaining work is mostly
closure, observability, and continued simplification.

## 2. Strong Points

### 2.1 Protocol core is coherent

The main dataplane story is now consistently reflected in code and docs:

```text
self row
-> agreed row
-> commit set + sound set
```

This is encoded directly in:

- `sim/protocol/types.py`
- `sim/protocol/node.py`

### 2.2 Boundaries are much healthier

The current split is good:

- `sim/protocol`
  - node-local protocol behavior
- `sim/runtime`
  - round orchestration, mailboxes, packet delivery, trace
- `sim/control`
  - interruption handling, repair planning, prepare/ack/commit, cutover
- `sim/scenarios`
  - fault models and built-in scenario definitions

This is close to the intended mental model:

- node as dataplane / future FPGA-facing spec core,
- cluster as driver/scheduler surrogate,
- control plane as policy actor.

### 2.3 HALT and CRASH are unified as interruptions

Both `NodeHalted` and `NodeCrashed` now enter the same interruption-driven
recovery pipeline:

```text
interruption
-> repair
-> prepare
-> ack
-> commit
-> local activation
```

This gives the current APSys line a much cleaner story than a
halt-is-terminal model.

### 2.4 Timing model is substantially cleaner

Important timing fixes now hold:

- `sound_bitmap` is the boundary-derived `sound set` that is exchanged for the
  next round,
- control-plane visibility is round-start only,
- network faults are applied at delivery time rather than send time,
- a node that crashes at round start no longer consumes that round's mailbox,
- prepare-time coordination can abort on timeout instead of waiting forever.

### 2.5 Trace and debug support are now genuinely useful

The trace can now expose:

- control-plane writes,
- control-plane events,
- boundary decisions,
- pending configs,
- compact committed-log digests,
- collection windows,
- episode targets,
- episode membership,
- and pending future cutovers.

This is strong enough to support both debugging and paper-oriented explanation.

## 3. Current Boundaries and Simplifications

These are not necessarily flaws, but they should be understood explicitly.

### 3.1 Aggregated control-plane transactions

Nodes currently consume a single aggregated `ControlPlaneTransaction` mailbox
object rather than a lower-level hardware-style opcode/register interface.

This is a deliberate APSys-prototype simplification. It is appropriate for the
current simulator, but should not be confused with a final implementation
interface.

### 3.2 Repair prefix policy is intentionally simple

The current control plane still picks a repair source using a simple
longest-committed-prefix policy over live dataplane snapshots.

This is acceptable for the present prototype, but it is still a policy choice,
not a final or fully generalized repair theorem encoded in implementation.

### 3.3 Built-in scenarios are still 3-node-centric

The code is no longer hardcoded to a single recovering node, but the main
scenario suite and the paper-facing story still clearly target the 3-node
setting.

That is reasonable for APSys as long as we remain honest about the scope.

### 3.4 Multi-episode support now exists, but validation is still shallow

The control plane can now:

- batch interruptions inside a collection window,
- run an episode over a fixed membership,
- abort if prepare-phase coordination times out,
- and queue later interruptions for subsequent episodes.

However, the current built-in scenarios still mainly exercise single-episode
recoveries.

## 4. Improvements Completed During This Review

### 4.1 Node halt path cleanup

The repeated halt-handling logic in `sim/protocol/node.py` has been collapsed
into shared helpers:

- `_build_halt_record(...)`
- `_enter_halt_state(...)`

This makes the file read more like a protocol reference and less like repeated
control flow.

### 4.2 Control-plane episode flow made more explicit

The control-plane implementation now has clearer internal phases, with helpers
for:

- scheduling actions,
- recording applied actions,
- episode member derivation,
- episode scheduling,
- interruption intake,
- and `PrepareAck` intake.

This does not radically change behavior, but it improves local readability.

### 4.3 Trace/performance summary alignment

The runtime/CLI layer now reflects the current control-plane story rather than
legacy action names, and round traces expose the episode-level CP state needed
to read rejoin behavior.

### 4.4 Tests are less brittle about control-plane episode logs

Time-model tests no longer assume an exact four-action single-episode action
list. They now assert the required recovery subsequence and ordering, which is
more robust as the simulator evolves.

## 5. Remaining Useful Improvements

These are worth doing, but they are no longer blockers for APSys-facing work.

### 5.1 More invariant-oriented tests

Some scenario checks still depend heavily on exact committed-round snapshots.
Over time, more checks should move toward:

- required subsequences,
- ordering constraints,
- no conflicting commits,
- activation-after-commit,
- and no intra-round control-plane visibility.

### 5.2 More explicit evaluation metric export

The trace is strong, but APSys figure production will benefit from stable
machine-readable exports for:

- interruption-to-recovery latency,
- prepare latency,
- ack collection latency,
- commit-to-activation latency,
- and cutover warm-up gap.

### 5.3 Optional future hardware-facing mailbox decomposition

If the simulator later becomes a closer model of a concrete FPGA/driver path,
the aggregated control-plane transaction may eventually split into:

- opcodes,
- flags,
- repair payload writes,
- pending-config staging,
- and explicit completion signals.

That is not required for the APSys version.

## 6. Bottom Line

The current codebase is in a good state.

It now behaves much more like a coherent system prototype than a loosely
connected simulator:

- the protocol story is clearer,
- the timing model is cleaner,
- the recovery path is more realistic,
- and the architecture is easier to explain.

At this point, the repo is ready to support the next APSys tasks:

- evaluation metric extraction,
- figure generation,
- and paper-facing narrative cleanup.
