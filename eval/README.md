# Evaluation

This directory contains the paper-facing evaluation entrypoints for the
SSR simulator.

- Top-level `run_*.sh` scripts are the end-to-end entrypoints. Each one runs
  the simulator, exports data, and renders the corresponding figure.
- `scripts/` contains the Python helpers that implement sweeps, exports, and
  plotting.
- `results/` holds checked-in reference outputs.

## End-to-End Figure Entry Points

Generate the steady-state throughput CSV and PDF:

```bash
bash eval/run_steady_state_throughput.sh
```

Generate the recovery timeline CSV and PDF:

```bash
bash eval/run_recovery_timeline.sh
```

## Random Fault Sweeps

Generate CSV files for packet loss, packet delay, ACK corruption, duplicate
delivery, and node crash sweeps:

```bash
python3 eval/scripts/run_random_sweeps.py
```

By default, results are written to:

```text
eval/results/random_sweeps/
```

Each CSV row includes:

- the swept parameter and value;
- the campaign configuration;
- safety violation count;
- halt/crash/all-running counts;
- halt and all-running rates;
- average committed rounds per node.

For quick smoke tests:

```bash
python3 eval/scripts/run_random_sweeps.py --trials 5 --values 0,0.02 --out /tmp/ssr_sweeps
```

For paper-quality runs, increase `--trials` after the simulator semantics are
frozen.

## Protocol Timing Sweeps

Generate CSV files for:

- steady-state throughput versus round length (`perfect`)
- crash-triggered rejoin sensitivity versus repair delay (`online_rejoin`)
- halt-triggered rejoin sensitivity versus repair delay (`asymmetric_loss`)
- crash-triggered rejoin sensitivity versus install delay (`online_rejoin`)
- halt-triggered rejoin sensitivity versus install delay (`asymmetric_loss`)

```bash
python3 eval/scripts/run_protocol_sweeps.py
```

The default configuration is a paper-facing timing profile:

- `round_length = 4us`
- `halt_report_delay = 100us`
- `cp_collection_delay = 1ms`
- `cp_decision_delay = 500us`
- `repair_delay = 2ms`
- `install_delay = 1ms`
- `reentry_delay = 250us`
- `app_delivery_delay = 5us`

The default round budgets are chosen for those slower control-plane timings:

- `steady_rounds = 2000`
- `recovery_rounds = 1500`

The sweep runner uses the simulator's lightweight evaluation mode. It keeps the
execution round-accurate while avoiding debug-oriented artifacts that would
otherwise dominate memory use during long recovery studies.

Each CSV row includes:

- the scenario and sweep name;
- the full timing configuration;
- simulated wall-clock time;
- cluster and per-node commit rates;
- control-plane event count;
- recovery timing metrics when applicable.

For quick smoke tests:

```bash
python3 eval/scripts/run_protocol_sweeps.py \
  --steady-rounds 50 \
  --recovery-rounds 60 \
  --steady-values 4us,8us \
  --recovery-values 500us,2ms \
  --out /tmp/syncons_protocol_sweeps
```

Regenerate the steady-state throughput figure directly from an existing CSV:

```bash
python3 eval/scripts/plot_steady_state_throughput.py \
  --file-path eval/results/steady_state_throughput/steady_state_throughput.csv \
  --out eval/results/steady_state_throughput/throughput_comparison.pdf
```
