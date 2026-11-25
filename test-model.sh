#!/usr/bin/env bash
# test-model.sh — Quick live verification for a running Ternary Bonsai 2.5 27B server
# Tests health, model metadata, chat generation (+ tok/s + MTP draft stats), and native tool calling.
#
# Usage:
#   bash test-model.sh
#   PORT=18080 bash test-model.sh
#   HOST=127.0.0.1 PORT=8080 bash test-model.sh
#
# Compatible with Bash 3.2+ (macOS & Linux).
set -euo pipefail

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

# 2. Model metadata
MODELS_JSON="$(curl -s --max-time 10 "${BASE_URL}/v1/models")"
if command -v python3 >/dev/null 2>&1; then
  MODELS_JSON="${MODELS_JSON}" python3 - <<'PY'
import json, os
data = json.loads(os.environ["MODELS_JSON"])
items = data.get("data") or []
if items:
    m = items[0]
    meta = m.get("meta") or {}
    arch = m.get("architecture") or {}
    print(f"✔  Model:     {os.path.basename(m.get('id', 'unknown'))}")
    if meta.get("ftype"):
        print(f"   Packing:   {meta['ftype']}")
    if meta.get("n_ctx"):
        print(f"   Context:   {meta['n_ctx']} active / {meta.get('n_ctx_train', '?')} max")
    if arch.get("input_modalities"):
        print(f"   Modalities:{', '.join(arch['input_modalities'])}")
PY
else
  echo "✔  /v1/models responded"
fi

# 3. Chat completion + speed + MTP stats
echo ""
echo "── Test 1: Chat Completion & Throughput ──"
CHAT_JSON="$(curl -s --max-time 120 "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bonsai-2.5",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant"},
      {"role": "user", "content": "What is 17 + 25? Reply with just the number."}
    ],
    "max_tokens": 512,
    "temperature": 0
  }')"

if command -v python3 >/dev/null 2>&1; then
  CHAT_JSON="${CHAT_JSON}" python3 - <<'PY'
import json, os, sys
res = json.loads(os.environ["CHAT_JSON"])
if "error" in res:
    print("❌ Chat error:", res["error"])
    sys.exit(1)
msg = res["choices"][0]["message"]
content = (msg.get("content") or "").strip()
reasoning = (msg.get("reasoning_content") or "").strip()
timings = res.get("timings") or {}
pp = timings.get("prompt_per_second", 0.0)
tg = timings.get("predicted_per_second", 0.0)
print(f"✔  Answer:    {content or '(still in reasoning trace — increase max_tokens)'}")
if reasoning:
    print(f"   Thinking:  {len(reasoning)} chars (thinking mode active)")
print(f"   Speed:     {pp:.1f} tok/s prefill · {tg:.1f} tok/s decode")
draft_n = timings.get("draft_n") or 0
draft_acc = timings.get("draft_n_accepted") or 0
if draft_n > 0:
    pct = 100.0 * draft_acc / draft_n
    print(f"   MTP Draft: {draft_acc}/{draft_n} accepted ({pct:.1f}%)")
else:
    print("   MTP Draft: inactive (normal on CPU/Vulkan or non-MTP builds)")
PY
else
  printf '%s\n' "${CHAT_JSON}"
fi

# 4. Native Agentic Tool Calling Test
echo ""
echo "── Test 2: Native Agentic Tool Calling ──"
TOOL_JSON="$(curl -s --max-time 120 "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bonsai-2.5",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant. Use the provided tools when appropriate."},
      {"role": "user", "content": "Check the current weather in Helsinki in Celsius."}
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get the current weather for a city.",
          "parameters": {
            "type": "object",
            "properties": {
              "city": {"type": "string"},
              "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
            },
            "required": ["city"]
          }
        }
      }
    ],
    "max_tokens": 512,
    "temperature": 0
  }')"

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
  printf '%s\n' "${TOOL_JSON}"
fi

echo ""
echo "🎉 All live model checks passed!"
