# Evaluation Presets

This directory contains repeatable evaluation helpers for the APSys version of
SynCons.

## Random Fault Sweeps

Generate CSV files for packet loss, packet delay, ACK corruption, duplicate
delivery, and node crash sweeps:

```bash
python3 eval/run_random_sweeps.py
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
- average committed epochs per node.

For quick smoke tests:

```bash
python3 eval/run_random_sweeps.py --trials 5 --values 0,0.02 --out /tmp/syncons_sweeps
```

For paper-quality runs, increase `--trials` after the simulator semantics are
frozen.
