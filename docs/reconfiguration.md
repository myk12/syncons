# Reconfiguration and Recovery

This note describes the current control-plane recovery workflow implemented by
the simulator.

## 1. Recovery Triggers

The control plane becomes active in two cases:

- a live dataplane halts and explicitly raises an interruption;
- a dataplane crashes and is detected through control-plane polling of
  dataplane-visible state.

Control planes exchange heartbeats in the normal case and use the same
asynchronous RPC path for recovery coordination after interruption.

## 2. Coordinator Election

Recovery proceeds in two stages. First, one replica requests to act as
coordinator for the recovery attempt. If multiple replicas initiate recovery
concurrently, a conventional crash-fault-tolerant election rule resolves the
conflict and establishes one coordinator for the new recovery instance.

## 3. Renewed Configuration Commit

The coordinator gathers cluster state and constructs a renewed configuration
containing:

- the fresh `run_id`;
- the renewed membership;
- the activation round.

This configuration is installed via a standard two-phase commit workflow:

1. the coordinator sends `Prepare`;
2. each control plane installs the configuration into its local dataplane as a
   **pending entry** and responds with `PrepareOK` only after installation
   succeeds;
3. after collecting acknowledgements from the renewed membership, the
   coordinator sends `Commit`.

The activation round is chosen sufficiently far in the future so that the
prepare/commit workflow either completes or aborts before the configuration
could take effect.

## 4. Activation and Failure Cases

After `Commit`, the pending entry becomes committed but not yet active. Each
dataplane switches to the renewed configuration only when its local round
reaches the activation round.

If the two-phase commit fails, the pending entry is discarded and never takes
effect.

If some replica fails to install the renewed configuration or misses the
activation point, it is treated as faulty and excluded from the fast path. Even
if a dataplane switches to a fresh `run_id` early, it still cannot commit
without a matching quorum because messages from other runs are ignored.

The worst case is repeated re-entry into control-plane coordination and
recovery; this can reduce throughput and delay progress, but it does not
violate correctness.
