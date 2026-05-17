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

OUT_PATH="${1:-${REPO_ROOT}/eval/results/recovery_timeline/recovery_timeline.csv}"
OUT_DIR="$(dirname "${OUT_PATH}")"
PDF_PATH="${OUT_DIR}/recovery_timeline.pdf"
ROUNDS="${ROUNDS:-120}"
NODE_COUNT="${NODE_COUNT:-5}"
WINDOW="${WINDOW:-24us}"
STEP="${STEP:-4us}"
SCENARIOS="${SCENARIOS:-node_crash,asymmetric_loss,bridge_partition}"
FAULT_ROUND="${FAULT_ROUND:-}"

mkdir -p "$(dirname "${OUT_PATH}")"

echo "[recovery-timeline] output path: ${OUT_PATH}"
echo "[recovery-timeline] scenarios: ${SCENARIOS}"
echo "[recovery-timeline] rounds: ${ROUNDS}"
echo "[recovery-timeline] node_count: ${NODE_COUNT}"
echo "[recovery-timeline] window: ${WINDOW}"
echo "[recovery-timeline] step: ${STEP}"
if [[ -n "${FAULT_ROUND}" ]]; then
  echo "[recovery-timeline] fault_round: ${FAULT_ROUND}"
fi

cmd=(
  "${PYTHON_BIN}" "${REPO_ROOT}/eval/scripts/export_recovery_timeline.py"
  --scenarios "${SCENARIOS}"
  --rounds "${ROUNDS}"
  --node-count "${NODE_COUNT}"
  --window "${WINDOW}"
  --step "${STEP}"
  --out "${OUT_PATH}"
)

if [[ -n "${FAULT_ROUND}" ]]; then
  cmd+=(--fault-round "${FAULT_ROUND}")
fi

"${cmd[@]}"

"${PYTHON_BIN}" "${REPO_ROOT}/eval/scripts/plot_recovery_timeline.py" \
  --file-path "${OUT_PATH}" \
  --out "${PDF_PATH}" \
  --layout panels

echo "[recovery-timeline] wrote ${OUT_PATH}"
echo "[recovery-timeline] wrote ${PDF_PATH}"
