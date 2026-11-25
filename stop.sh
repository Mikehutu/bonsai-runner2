#!/usr/bin/env bash
# stop.sh — Stop the Ternary Bonsai 2.5 27B server started by start.sh
set -euo pipefail

BASE_DIR="${BONSAI25_DIR:-${HOME}/.bonsai25}"
PID_FILE="${BASE_DIR}/llama-server.pid"

if [[ -f "${PID_FILE}" ]]; then
  PID="$(cat "${PID_FILE}" | tr -d '[:space:]')"
  if [[ -n "${PID}" ]] && kill "${PID}" 2>/dev/null; then
    echo "✔  Stopped llama-server (PID ${PID})"
  else
    echo "   (Process ${PID:-unknown} not running — cleaning up PID file)"
  fi
  rm -f "${PID_FILE}"
else
  PIDS="$(pgrep -f "llama-server.*Ternary-Bonsai-2\.5" 2>/dev/null || true)"
  if [[ -n "${PIDS}" ]]; then
    echo "   Stopping llama-server (PID(s): ${PIDS})..."
    # shellcheck disable=SC2086
    kill ${PIDS} 2>/dev/null || true
    echo "✔  Stopped"
  else
    echo "   No running Bonsai 2.5 llama-server found."
  fi
fi
