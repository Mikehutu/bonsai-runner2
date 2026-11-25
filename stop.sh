#!/usr/bin/env bash
# stop.sh — Stop the Ternary Bonsai 2.5 27B server started by start.sh (llama-server or mlx_vlm.server)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Delegate to stop.ps1 if invoked from Git Bash / MSYS2 / Cygwin on Windows
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if [[ "${BONSAI_NO_PWSH_DELEGATE:-0}" != "1" ]]; then
      PWSH_EXE="$(command -v powershell.exe 2>/dev/null || true)"
      [[ -z "${PWSH_EXE}" && -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]] && PWSH_EXE="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
      if [[ -n "${PWSH_EXE}" ]]; then
        WIN_PS1="${SCRIPT_DIR}/stop.ps1"
        command -v cygpath >/dev/null 2>&1 && WIN_PS1="$(cygpath -w "${WIN_PS1}")"
        exec "${PWSH_EXE}" -NoProfile -ExecutionPolicy Bypass -File "${WIN_PS1}"
      fi
    fi
    ;;
esac

BASE_DIR="${BONSAI25_DIR:-${HOME}/.bonsai25}"
PID_FILE="${BASE_DIR}/llama-server.pid"

stop_pid() {
  local pid="$1"
  if kill "${pid}" 2>/dev/null; then
    local i=0
    while [[ $i -lt 10 ]]; do
      kill -0 "${pid}" 2>/dev/null || return 0
      sleep 0.5
      i=$((i + 1))
    done
    kill -9 "${pid}" 2>/dev/null || true
    return 0
  fi
  return 1
}

if [[ -f "${PID_FILE}" ]]; then
  PID="$(tr -d '[:space:]' < "${PID_FILE}")"
  if [[ -n "${PID}" ]] && stop_pid "${PID}"; then
    echo "✔  Stopped Bonsai 2.5 server (PID ${PID})"
  else
    echo "   (Process ${PID:-unknown} not running — cleaning up PID file)"
  fi
  rm -f "${PID_FILE}"
else
  PIDS="$(pgrep -f "llama-server.*Ternary-Bonsai-2\.5|mlx_vlm\.server.*bonsai25|mlx_vlm\.server.*Ternary-Bonsai-2\.5" 2>/dev/null || true)"
  if [[ -n "${PIDS}" ]]; then
    echo "   Stopping Bonsai 2.5 server (PID(s): ${PIDS})..."
    for p in ${PIDS}; do
      stop_pid "${p}" || true
    done
    echo "✔  Stopped"
  else
    echo "   No running Bonsai 2.5 server found."
  fi
fi
