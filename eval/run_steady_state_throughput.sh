#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
  PYTHON_BIN="${REPO_ROOT}/.venv/bin/python"
else
  PYTHON_BIN="python3"
fi
TMP_BASE="${TMPDIR:-/private/tmp}"
export MPLCONFIGDIR="${MPLCONFIGDIR:-${TMP_BASE}/syncons-mpl}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${TMP_BASE}/syncons-xdg-cache}"
mkdir -p "${MPLCONFIGDIR}" "${XDG_CACHE_HOME}" "${XDG_CACHE_HOME}/fontconfig"

OUT_DIR="${1:-${REPO_ROOT}/eval/results/steady_state_throughput}"
CSV_PATH="${OUT_DIR}/steady_state_throughput.csv"
PDF_PATH="${OUT_DIR}/throughput_comparison.pdf"
STEADY_ROUNDS="${STEADY_ROUNDS:-5000}"
STEADY_VALUES="${STEADY_VALUES:-2us,4us,8us}"
STEADY_NODE_COUNTS="${STEADY_NODE_COUNTS:-3,5}"

mkdir -p "${OUT_DIR}"

echo "[steady-state-throughput] output directory: ${OUT_DIR}"
echo "[steady-state-throughput] steady rounds: ${STEADY_ROUNDS}"
echo "[steady-state-throughput] round lengths: ${STEADY_VALUES}"
echo "[steady-state-throughput] node counts: ${STEADY_NODE_COUNTS}"

"${PYTHON_BIN}" "${REPO_ROOT}/eval/scripts/run_protocol_sweeps.py" \
  --sweeps steady \
  --steady-rounds "${STEADY_ROUNDS}" \
  --steady-values "${STEADY_VALUES}" \
  --steady-node-counts "${STEADY_NODE_COUNTS}" \
  --out "${OUT_DIR}"

"${PYTHON_BIN}" "${REPO_ROOT}/eval/scripts/plot_steady_state_throughput.py" \
  --file-path "${CSV_PATH}" \
  --out "${PDF_PATH}"

echo "[steady-state-throughput] wrote ${CSV_PATH}"
echo "[steady-state-throughput] wrote ${PDF_PATH}"
