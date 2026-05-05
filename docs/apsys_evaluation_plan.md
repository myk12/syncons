# APSys Evaluation Plan

Last updated: 2026-05-04

This note fixes the evaluation scope for the APSys version of SynCons.

The goal is not to measure every interesting behavior. The goal is to show a
small set of results that together answer the core APSys questions:

1. does the fast path perform well when the system is healthy?
2. does the dataplane shrink or halt safely under ambiguity?
3. can interrupted nodes rejoin cleanly?
4. what does that recovery cost?

## 1. Final Evaluation Set

The APSys evaluation should focus on exactly five result groups.

### E1. Steady-State Performance

**Question**

```text
How well does SynCons run when no failure occurs?
```

**Primary scenario**

- `perfect`

**Metrics**

- commit throughput / commits per unit time
- delivered application throughput
- round length sensitivity

**Expected artifact**

- one main performance figure:
  `throughput vs round_length`

---

### E2. Dataplane Failure Handling

**Question**

```text
Does the dataplane continue only when continuation is safe, and halt when it is ambiguous?
```

**Primary scenarios**

- `asymmetric_loss`
- `bridge_partition` or `quorum_loss`

**Metrics / observations**

- whether nodes shrink to a smaller sound set
- whether ambiguous nodes halt
- whether conflicting commits are avoided

**Expected artifact**

- one compact summary table of scenario outcomes
- one or two short trace excerpts for illustration

This result group is about behavior, not throughput.

---

### E3. Crash-Triggered Online Rejoin

**Question**

```text
After a node crashes, can the system keep serving and later re-admit that node cleanly?
```

**Primary scenario**

- `online_rejoin`

**Metrics / observations**

- surviving nodes continue committing on a shrunk sound set
- recovering node receives a repair log
- prepare / ack / commit occurs
- cutover occurs at a future round boundary
- all nodes converge to the new run

**Expected artifact**

- one recovery timeline figure or compact timeline table
- one short explanatory trace excerpt

---

### E4. Halt-Triggered Online Rejoin

**Question**

```text
If a node fail-stops due to ambiguity, can the control plane still bring it back safely?
```

**Primary scenario**

- `asymmetric_loss` under the current halt-triggered rejoin semantics

**Metrics / observations**

- node emits `NodeHalted`
- control plane observes interruption
- recovering node is repaired and prepared
- rejoin completes through the same prepare/ack/commit workflow

**Expected artifact**

- one recovery timeline figure or compact timeline table
- one short trace excerpt emphasizing `NodeHalted -> recovering -> rejoin`

This result group is central to the paper's fail-stop story.

---

### E5. Recovery Cost Breakdown

**Question**

```text
What are the dominant costs of interruption recovery and coordinated rejoin?
```

**Primary scenarios**

- `online_rejoin`
- halt-triggered `asymmetric_loss`

**Metrics**

- interruption report delay
- repair latency
- prepare-to-ack latency
- ack-to-commit latency
- commit-to-activation latency
- post-cutover warm-up gap

**Expected artifact**

- one stacked or segmented recovery-latency breakdown figure
- optionally a small numeric table with representative values

## 2. What We Will Not Emphasize

For the APSys version, the evaluation should *not* center on:

- many out-of-model packet corruption scenarios
- large scenario catalogs
- many different control-plane policy variants
- aggressive scaling studies beyond what the simulator can support credibly
- prototype implementation tuning unrelated to the core story

These may still appear as sanity checks or appendix material, but they are not
part of the main evaluation narrative.

## 3. Figure and Table Budget

The intended paper-facing artifact set is:

### Main figures

1. `steady_state_performance`
2. `recovery_cost_breakdown`

### Supporting figures or compact timelines

3. `crash_triggered_online_rejoin`
4. `halt_triggered_online_rejoin`

### Tables

5. `scenario_behavior_summary`

### Trace excerpts

6. one crash-triggered trace excerpt
7. one halt-triggered trace excerpt

## 4. Scenario-to-Result Mapping

| Result group | Scenario(s) | Output form |
| --- | --- | --- |
| E1 steady-state performance | `perfect` | main figure |
| E2 dataplane failure handling | `asymmetric_loss`, `bridge_partition` / `quorum_loss` | summary table + trace |
| E3 crash-triggered rejoin | `online_rejoin` | timeline figure + trace |
| E4 halt-triggered rejoin | `asymmetric_loss` | timeline figure + trace |
| E5 recovery cost breakdown | `online_rejoin`, `asymmetric_loss` | breakdown figure + optional numeric table |

## 5. Immediate Next Engineering Step

With this evaluation scope fixed, the next task is:

```text
export stable simulator metrics for E1 and E5
```

Those metrics are the foundation for the paper-facing figures.

## 6. Baseline Timing Profile

Unless explicitly stated otherwise, the APSys evaluation should use a realistic
baseline timing profile in which the control plane is much slower than the
dataplane:

- `round_length = 4us`
- `halt_report_delay = 100us`
- `cp_collection_delay = 1ms`
- `cp_decision_delay = 500us`
- `repair_delay = 2ms`
- `install_delay = 1ms`
- `reentry_delay = 250us`
- `app_delivery_delay = 5us`

This profile intentionally stretches recovery over hundreds of dataplane rounds.
That is a feature of the evaluation model, not a simulator bug.

Under this profile, default recovery runs should allow at least roughly:

- `1500` rounds for recovery-focused scenarios
- `2000` rounds for steady-state sweeps and long-run throughput measurements

Trace inspection under this profile should normally use:

- `--trace-mode event`
or
- `--trace-mode windowed`

rather than full per-round dumps.
