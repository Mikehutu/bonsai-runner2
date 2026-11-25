#!/usr/bin/env bash
# test-model.sh — Quick live verification for a running Ternary Bonsai 2.5 27B server
# Works against both llama-server (GGUF) and mlx_vlm.server (Apple Silicon MLX).
#
# Usage:
#   bash test-model.sh
#   PORT=18080 bash test-model.sh
#   bash test-model.sh --port 18080
#
# Compatible with Bash 3.2+ (macOS, Linux, WSL2, Git Bash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load PORT from .env if present and not already exported
if [[ -f "${SCRIPT_DIR}/.env" && -z "${PORT+x}" ]]; then
  ENV_PORT="$(sed -n 's/^[[:space:]]*PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${SCRIPT_DIR}/.env" | head -n 1 || true)"
  [[ -n "${ENV_PORT}" ]] && PORT="${ENV_PORT}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port|-p) PORT="$2"; shift 2 ;;
    --host) TEST_HOST="$2"; shift 2 ;;
    [0-9]*) PORT="$1"; shift ;;
    -h|--help)
      echo "Usage: bash test-model.sh [--port PORT] [--host HOST]"
      exit 0
      ;;
    *) shift ;;
  esac
done

HOST="${TEST_HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
BASE_URL="http://${HOST}:${PORT}"

echo "══════════════════════════════════════════════════════════"
echo "  Ternary Bonsai 2.5 27B — Live Model Test"
echo "  Endpoint: ${BASE_URL}"
echo "══════════════════════════════════════════════════════════"

# 1. Health check
HEALTH_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${BASE_URL}/health" 2>/dev/null || echo 000)"
if [[ "${HEALTH_CODE}" != "200" ]]; then
  echo "❌ Server not ready at ${BASE_URL}/health (HTTP ${HEALTH_CODE})."
  echo "   Start it first with: bash start.sh"
  exit 1
fi
echo "✔  Health check passed (HTTP 200)"

# 2. Model metadata & resolve active model ID (important for mlx_vlm.server)
MODELS_JSON="$(curl -s --max-time 10 "${BASE_URL}/v1/models")"
MODEL_ID="bonsai-2.5"
if command -v python3 >/dev/null 2>&1; then
  MODEL_ID="$(MODELS_JSON="${MODELS_JSON}" python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ["MODELS_JSON"])
items = data.get("data") or []
if items:
    m = items[0]
    mid = m.get("id") or "bonsai-2.5"
    meta = m.get("meta") or {}
    arch = m.get("architecture") or {}
    print(f"✔  Model:     {os.path.basename(mid.rstrip('/'))}", file=sys.stderr)
    if meta.get("ftype"):
        print(f"   Packing:   {meta['ftype']}", file=sys.stderr)
    if meta.get("n_ctx"):
        print(f"   Context:   {meta['n_ctx']} active / {meta.get('n_ctx_train', '?')} max", file=sys.stderr)
    if arch.get("input_modalities"):
        print(f"   Modalities:{', '.join(arch['input_modalities'])}", file=sys.stderr)
    print(mid)
else:
    print("bonsai-2.5")
PY
)"
else
  PARSED_ID="$(printf '%s\n' "${MODELS_JSON}" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  [[ -n "${PARSED_ID}" ]] && MODEL_ID="${PARSED_ID}"
  echo "✔  /v1/models responded (${MODEL_ID})"
fi

# Escape backslashes/quotes in MODEL_ID for JSON payload (e.g. Windows paths)
JSON_MODEL_ID="$(printf '%s' "${MODEL_ID}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

# 3. Chat completion + speed + MTP stats
echo ""
echo "── Test 1: Chat Completion & Throughput ──"
T_START="$(date +%s)"
CHAT_JSON="$(curl -s --max-time 180 "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${JSON_MODEL_ID}\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a helpful assistant\"},
      {\"role\": \"user\", \"content\": \"What is 17 + 25? Reply with just the number.\"}
    ],
    \"max_tokens\": 2048,
    \"temperature\": 0
  }")"
T_END="$(date +%s)"
ELAPSED_SEC=$((T_END - T_START))
[[ "${ELAPSED_SEC}" -lt 1 ]] && ELAPSED_SEC=1

if command -v python3 >/dev/null 2>&1; then
  CHAT_JSON="${CHAT_JSON}" ELAPSED_SEC="${ELAPSED_SEC}" python3 - <<'PY'
import json, os, sys
res = json.loads(os.environ["CHAT_JSON"])
if "error" in res:
    print("❌ Chat error:", res["error"])
    sys.exit(1)
msg = res["choices"][0]["message"]
content = (msg.get("content") or "").strip()
reasoning = (msg.get("reasoning_content") or msg.get("reasoning") or "").strip()
timings = res.get("timings") or {}
usage = res.get("usage") or {}
pp = timings.get("prompt_per_second", 0.0)
tg = timings.get("predicted_per_second", 0.0)
print(f"✔  Answer:    {content or '(still in reasoning trace — increase max_tokens)'}")
if reasoning:
    print(f"   Thinking:  {len(reasoning)} chars (thinking mode active)")
if tg > 0 or pp > 0:
    print(f"   Speed:     {pp:.1f} tok/s prefill · {tg:.1f} tok/s decode")
    draft_n = timings.get("draft_n") or 0
    draft_acc = timings.get("draft_n_accepted") or 0
    if draft_n > 0:
        pct = 100.0 * draft_acc / draft_n
        print(f"   MTP Draft: {draft_acc}/{draft_n} accepted ({pct:.1f}%)")
    else:
        print("   MTP Draft: inactive (normal on CPU or non-MTP builds)")
elif usage.get("completion_tokens"):
    comp = int(usage["completion_tokens"])
    elapsed = max(1, int(os.environ.get("ELAPSED_SEC", "1")))
    print(f"   Speed:     ~{comp / elapsed:.1f} tok/s end-to-end ({comp} completion tokens in {elapsed}s)")
PY
else
  if printf '%s\n' "${CHAT_JSON}" | grep -q '"error"'; then
    echo "❌ Chat error: ${CHAT_JSON}"
    exit 1
  fi
  echo "✔  Chat response received (${ELAPSED_SEC}s)"
fi

# 4. Native Agentic Tool Calling Test
echo ""
echo "── Test 2: Native Agentic Tool Calling ──"
TOOL_JSON="$(curl -s --max-time 180 "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${JSON_MODEL_ID}\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a helpful assistant. Use the provided tools when appropriate.\"},
      {\"role\": \"user\", \"content\": \"Check the current weather in Helsinki in Celsius.\"}
    ],
    \"tools\": [
      {
        \"type\": \"function\",
        \"function\": {
          \"name\": \"get_weather\",
          \"description\": \"Get the current weather for a city.\",
          \"parameters\": {
            \"type\": \"object\",
            \"properties\": {
              \"city\": {\"type\": \"string\"},
              \"unit\": {\"type\": \"string\", \"enum\": [\"celsius\", \"fahrenheit\"]}
            },
            \"required\": [\"city\"]
          }
        }
      }
    ],
    \"max_tokens\": 2048,
    \"temperature\": 0
  }")"

if command -v python3 >/dev/null 2>&1; then
  TOOL_JSON="${TOOL_JSON}" python3 - <<'PY'
import json, os, sys
res = json.loads(os.environ["TOOL_JSON"])
if "error" in res:
    print("❌ Tool call error:", res["error"])
    sys.exit(1)
msg = res["choices"][0]["message"]
tcs = msg.get("tool_calls") or []
if tcs:
    fn = tcs[0].get("function") or {}
    print(f"✔  Tool call: {fn.get('name')}({fn.get('arguments')})")
else:
    content = (msg.get("content") or "").strip()
    print(f"⚠  Model replied with text instead of tool_calls: {content[:120]}")
    sys.exit(1)
PY
else
  if printf '%s\n' "${TOOL_JSON}" | grep -q '"get_weather"'; then
    echo "✔  Tool call: get_weather(...) verified"
  else
    echo "❌ Expected get_weather tool call, got: ${TOOL_JSON}"
    exit 1
  fi
fi

echo ""
echo "🎉 All live model checks passed!"
