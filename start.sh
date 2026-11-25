#!/usr/bin/env bash
# start.sh — Ternary Bonsai 2.5 27B one-click runner (Linux, macOS, WSL2, Git Bash)
#
# Usage:
#   bash start.sh                  # auto-detect hardware & pick best variant
#   bash start.sh ptq1-mtp         # 6.2 GB PTQ1_0 + MTP head (best for NVIDIA CUDA / ROCm)
#   bash start.sh pq2-mtp          # 7.5 GB PQ2_0 + MTP head (best for Apple Metal / CPU / Vulkan)
#   bash start.sh q2-mtp           # 7.9 GB Q2_0 + MTP head (stock llama.cpp b11556+ compatible)
#   bash start.sh ptq1             # 6.0 GB PTQ1_0 (no MTP head)
#   bash start.sh pq2              # 7.3 GB PQ2_0 (no MTP head)
#   bash start.sh q2               # 7.7 GB Q2_0 (no MTP head)
#   bash start.sh mlx              # Apple Silicon MLX 2-bit OpenAI/Anthropic server (macOS arm64)
#
# Compatible with Bash 3.2+ (stock macOS /bin/bash) and Bash 4/5 (Linux).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Optional .env loader (never overwrites already-set env vars) ─────
load_dotenv() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    case "${line}" in
      ''|'#'*) continue ;;
    esac
    case "${line}" in
      *=*)
        key="${line%%=*}"
        val="${line#*=}"
        key="$(printf '%s' "${key}" | tr -d '[:space:]')"
        case "${key}" in
          ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;;
        esac
        case "${val}" in
          \"*\") val="${val#\"}"; val="${val%\"}" ;;
          \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        if [[ -z "${!key+x}" ]]; then
          export "${key}=${val}"
        fi
        ;;
    esac
  done < "${env_file}"
}

load_dotenv "${SCRIPT_DIR}/.env"

# Track whether user explicitly set memory/offload overrides before defaults
USER_SET_MMPROJ_CPU=0
USER_SET_KV4=0
USER_SET_NGL=0
[[ -n "${MMPROJ_CPU+x}" ]] && USER_SET_MMPROJ_CPU=1
[[ -n "${KV4+x}" ]] && USER_SET_KV4=1
[[ -n "${NGL+x}" ]] && USER_SET_NGL=1

# ─── CLI Argument Parsing (Bash 3.2 safe) ─────────────────────────────
CHOOSE_MODE=0
DETACHED="${DETACHED:-0}"
DRY_RUN="${BONSAI_DRY_RUN:-0}"
MLX_ONCE="${MLX_ONCE:-0}"
MLX_PROMPT="${MLX_PROMPT:-}"
RAW_VARIANT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --choose|-i|--interactive) CHOOSE_MODE=1; shift ;;
    --no-browser) NO_BROWSER=1; shift ;;
    --detached|-d) DETACHED=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --kv4) KV4=1; USER_SET_KV4=1; shift ;;
    --no-vision) NO_VISION=1; shift ;;
    --mmproj-cpu) MMPROJ_CPU=1; USER_SET_MMPROJ_CPU=1; shift ;;
    --once) MLX_ONCE=1; shift ;;
    -p|--prompt)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      MLX_PROMPT="$2"; MLX_ONCE=1; shift 2 ;;
    --port)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      PORT="$2"; shift 2 ;;
    --host)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      HOST="$2"; shift 2 ;;
    --backend)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      BACKEND="$2"; shift 2 ;;
    --mode)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      MODE="$2"; shift 2 ;;
    --reasoning-effort)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      REASONING_EFFORT="$2"; shift 2 ;;
    --mtp)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      MTP="$2"; shift 2 ;;
    -c|--context-size)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      CONTEXT_SIZE="$2"; shift 2 ;;
    --ngl)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      NGL="$2"; USER_SET_NGL=1; shift 2 ;;
    --parallel)
      if [[ $# -lt 2 ]]; then echo "❌ Missing value for $1" >&2; exit 1; fi
      PARALLEL="$2"; shift 2 ;;
    -h|--help|help) RAW_VARIANT="--help"; shift ;;
    -*)
      echo "❌ Unknown option '$1' (run 'bash start.sh --help')" >&2
      exit 1
      ;;
    *)
      if [[ -z "${RAW_VARIANT}" ]]; then
        RAW_VARIANT="$1"
      elif [[ "${RAW_VARIANT}" == "mlx" && -z "${MLX_PROMPT}" ]]; then
        MLX_PROMPT="$1"
        MLX_ONCE=1
      fi
      shift
      ;;
  esac
done

MODEL_VARIANT="${RAW_VARIANT:-${MODEL_VARIANT:-auto}}"

# ─── Configuration Defaults ───────────────────────────────────────────
HF_REPO_GGUF="prism-ml/Ternary-Bonsai-2.5-27B-GGUF"
HF_REPO_MLX="prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit"
LLAMA_CPP_REPO="https://github.com/PrismML-Eng/llama.cpp"
DEFAULT_PRISM_RELEASE="prism-b12178-03ec600"
PRISM_RELEASE="${PRISM_RELEASE:-${DEFAULT_PRISM_RELEASE}}"

BASE_DIR="${BONSAI25_DIR:-${HOME}/.bonsai25}"
BIN_ROOT="${BASE_DIR}/bin"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-${BASE_DIR}/llama.cpp}"
MODELS_DIR="${MODELS_DIR:-${BASE_DIR}/models}"
PID_FILE="${BASE_DIR}/llama-server.pid"

PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
NGL="${NGL:-99}"
PARALLEL="${PARALLEL:-1}"             # 1 = safe VRAM default (model card recommends -np 1 on <=10GB GPUs)
CONTEXT_SIZE="${CONTEXT_SIZE:-0}"     # 0 = safe RAM/VRAM-tiered default (max 262144)
MODE="${MODE:-thinking}"              # thinking | instruct
REASONING_EFFORT="${REASONING_EFFORT:-default}"  # default | xhigh | medium (thinking mode)
MTP="${MTP:-auto}"                    # auto | on | off
MTP_NMAX="${MTP_NMAX:-}"
MTP_PMIN="${MTP_PMIN:-}"
NO_VISION="${NO_VISION:-0}"           # 1 = skip vision mmproj
MMPROJ_QUANT="${MMPROJ_QUANT:-Q8_0}"  # Q8_0 (0.63 GB) | BF16 (0.93 GB)
MMPROJ_CPU="${MMPROJ_CPU:-0}"         # 1 = keep vision projector in RAM (--no-mmproj-offload)
IMAGE_MAX_TOKENS="${IMAGE_MAX_TOKENS:-1024}"  # 0 = uncapped
KV4="${KV4:-0}"                       # 1 = 4-bit KV cache (--cache-type-k q4_0 --cache-type-v q4_0)
NO_BROWSER="${NO_BROWSER:-0}"         # 1 = do not auto-open Chat UI in browser
BACKEND_OVERRIDE="${BACKEND:-${BONSAI_BACKEND:-}}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

# ─── Help ─────────────────────────────────────────────────────────────
show_help() {
  cat <<'EOF'
Usage: bash start.sh [VARIANT] [OPTIONS]

Run Ternary Bonsai 2.5 27B locally with one command (Linux, macOS, WSL2, Git Bash).
Downloads prebuilt PrismML llama.cpp binaries (with automatic source-build
fallback) + GGUF weights from HuggingFace and starts an OpenAI-compatible
server with built-in Web UI (or native mlx-vlm server for 'mlx' on Apple Silicon).

Variants:
  auto       (default) Auto-pick best packing for your hardware:
               - NVIDIA CUDA / AMD ROCm → ptq1-mtp (6.2 GB, fastest decode)
               - Apple Metal / Vulkan / CPU → pq2-mtp (7.5 GB, or ptq1-mtp if tight on RAM)
  ptq1-mtp   PTQ1_0 + built-in MTP head (6.23 GB, 1.76 bpw) — fastest on NVIDIA GPUs
  pq2-mtp    PQ2_0  + built-in MTP head (7.49 GB, 2-bit slots) — benchmarked on Apple Metal
  q2-mtp     Q2_0   + built-in MTP head (7.91 GB) — also runs on stock llama.cpp b11556+
  ptq1       PTQ1_0 base without MTP    (5.99 GB) — smallest footprint
  pq2        PQ2_0  base without MTP    (7.25 GB)
  q2         Q2_0   base without MTP    (7.67 GB)
  mlx        Apple Silicon MLX 2-bit server (~8.6 GB, macOS arm64; auto-sets up Python 3.11 + mlx-vlm)

CLI Options:
  --choose, -i            Interactive variant & context menu
  --port <N>              Server port (default: 8080, auto-tries PORT+1, PORT+2)
  --host <ADDR>           Bind address (default: 0.0.0.0)
  --backend <NAME>        Force backend: cuda | rocm | vulkan | metal | cpu
  --mode <MODE>           thinking (default) | instruct (non-thinking)
  --reasoning-effort <L>  default (xhigh) | xhigh | medium (faster, shorter thinking)
  --mtp <auto|on|off>     Built-in MTP speculative decoding
  -c, --context-size <N>  Context tokens (0 = safe auto default; max 262144)
  --ngl <N|auto>          GPU layers to offload (default: 99, auto on <=6GB VRAM, 0 on CPU)
  --parallel <N>          Concurrent slots (default: 1; 0 = llama-server auto)
  --kv4                   Enable 4-bit KV cache (q4_0 / 4-bit MLX KV)
  --no-vision             Skip multimodal vision projector (mmproj)
  --mmproj-cpu            Keep vision projector in system RAM (--no-mmproj-offload)
  --no-browser            Skip auto-opening Web UI in desktop browser
  --detached, -d          Run server in background (logs to ~/.bonsai25/llama-server.log)
  -p, --prompt <TEXT>     (mlx only) Run a one-shot prompt and exit instead of starting server
  --dry-run               Print resolved hardware/model plan and exit without downloading

Environment variables (or set in .env):
  PORT, HOST, NGL, CONTEXT_SIZE, PARALLEL, MODE, REASONING_EFFORT, MTP,
  MTP_NMAX, MTP_PMIN, NO_VISION, MMPROJ_QUANT, MMPROJ_CPU, IMAGE_MAX_TOKENS,
  KV4, BACKEND, BUILD_FROM_SOURCE, PRISM_RELEASE, HF_TOKEN, HF_HUB_OFFLINE,
  NO_BROWSER, DETACHED, BONSAI25_DIR

Examples:
  bash start.sh                         # auto-detect hardware & start immediately
  bash start.sh --choose                # interactive menu
  bash start.sh ptq1-mtp                # explicit variant
  bash start.sh mlx                     # Apple Silicon MLX OpenAI/Anthropic server
  bash start.sh mlx -p "What is 2+2?"   # Apple Silicon MLX one-shot prompt
  CONTEXT_SIZE=131072 KV4=1 bash start.sh pq2-mtp
  MODE=instruct PORT=9090 bash start.sh ptq1-mtp
  bash test-model.sh                    # verify chat + tool calling + measure tok/s
  bash stop.sh                          # stop the running server
EOF
}

case "${MODEL_VARIANT}" in
  -h|--help|help)
    show_help
    exit 0
    ;;
esac

# ─── Windows Git Bash / MSYS2 / Cygwin auto-delegation ────────────────
OS_NAME="${BONSAI_TEST_OS:-$(uname -s)}"
case "${OS_NAME}" in
  MINGW*|MSYS*|CYGWIN*)
    if [[ "${BONSAI_NO_PWSH_DELEGATE:-0}" != "1" ]]; then
      PWSH_EXE=""
      if command -v powershell.exe >/dev/null 2>&1; then
        PWSH_EXE="$(command -v powershell.exe)"
      elif [[ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
        PWSH_EXE="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
      fi
      if [[ -n "${PWSH_EXE}" ]]; then
        WIN_PS1="${SCRIPT_DIR}/start.ps1"
        if command -v cygpath >/dev/null 2>&1; then
          WIN_PS1="$(cygpath -w "${WIN_PS1}")"
        fi
        echo "ℹ  Detected Windows shell (${OS_NAME}) — delegating to native start.ps1..."
        export MODEL_VARIANT PORT HOST NGL PARALLEL CONTEXT_SIZE MODE REASONING_EFFORT MTP
        export NO_VISION MMPROJ_QUANT MMPROJ_CPU IMAGE_MAX_TOKENS KV4 NO_BROWSER
        [[ -n "${BACKEND_OVERRIDE}" ]] && export BACKEND="${BACKEND_OVERRIDE}"
        [[ "${DRY_RUN}" == "1" ]] && export BONSAI_DRY_RUN=1
        PWSH_FLAGS=("-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "${WIN_PS1}")
        [[ "${CHOOSE_MODE}" == "1" ]] && PWSH_FLAGS+=("-Choose")
        [[ "${DETACHED}" == "1" ]] && PWSH_FLAGS+=("-Detached")
        [[ "${DRY_RUN}" == "1" ]] && PWSH_FLAGS+=("-DryRun")
        exec "${PWSH_EXE}" "${PWSH_FLAGS[@]}"
      fi
    fi
    echo "ℹ  Detected Windows shell (${OS_NAME}). For native Windows, run:" >&2
    echo "   powershell -ExecutionPolicy Bypass -File start.ps1" >&2
    exit 1
    ;;
esac

# ─── Portable helpers (Bash 3.2 + Linux/macOS safe) ───────────────────
to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

get_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc 2>/dev/null || echo 4
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    echo 4
  fi
}

get_ram_mb() {
  if [[ -n "${BONSAI_TEST_RAM_MB:-}" ]]; then
    echo "${BONSAI_TEST_RAM_MB}"
    return
  fi
  if [[ "${OS_NAME}" == "Linux" && -r /proc/meminfo ]]; then
    awk '/^MemTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0
  elif [[ "${OS_NAME}" == "Darwin" ]]; then
    sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1048576)}' 2>/dev/null || echo 0
  else
    echo 0
  fi
}

get_file_size_bytes() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo 0
    return
  fi
  if stat -c%s "$f" >/dev/null 2>&1; then
    stat -c%s "$f"
  else
    stat -f%z "$f" 2>/dev/null || echo 0
  fi
}

is_port_free() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"; then
      return 1
    fi
    return 0
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"${p}" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
      return 1
    fi
    return 0
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import socket,sys; s=socket.socket(); rc=s.connect_ex(('127.0.0.1', int(sys.argv[1]))); s.close(); sys.exit(1 if rc==0 else 0)" "${p}" 2>/dev/null
    return $?
  fi
  return 0
}

select_free_port() {
  local base_port="$1"
  local try_port
  for try_port in "${base_port}" $((base_port + 1)) $((base_port + 2)); do
    if is_port_free "${try_port}"; then
      echo "${try_port}"
      return 0
    fi
  done
  return 1
}

# ─── Download helper (zero-dependency curl/wget, atomic .part + 416 recovery) ──
download_url() {
  local url="$1" dest="$2"
  local tmp="${dest}.part"
  mkdir -p "$(dirname "${dest}")"

  local auth_header=""
  if [[ -n "${HF_TOKEN:-}" && "${url}" == *"huggingface.co"* ]]; then
    auth_header="Authorization: Bearer ${HF_TOKEN}"
  fi

  if command -v curl >/dev/null 2>&1; then
    local rc=0
    if [[ -n "${auth_header}" ]]; then
      curl -L --fail --retry 3 --retry-delay 2 -C - --progress-bar -H "${auth_header}" -o "${tmp}" "${url}" || rc=$?
    else
      curl -L --fail --retry 3 --retry-delay 2 -C - --progress-bar -o "${tmp}" "${url}" || rc=$?
    fi
    # Recover cleanly if a previous completed/corrupt .part file triggers HTTP 416 / range error
    if [[ "${rc}" -ne 0 && -f "${tmp}" ]]; then
      echo "   ↻ Resume failed (stale partial file) — retrying clean download..."
      rm -f "${tmp}"
      rc=0
      if [[ -n "${auth_header}" ]]; then
        curl -L --fail --retry 3 --retry-delay 2 --progress-bar -H "${auth_header}" -o "${tmp}" "${url}" || rc=$?
      else
        curl -L --fail --retry 3 --retry-delay 2 --progress-bar -o "${tmp}" "${url}" || rc=$?
      fi
    fi
    if [[ "${rc}" -ne 0 ]]; then
      return "${rc}"
    fi
  elif command -v wget >/dev/null 2>&1; then
    local rc=0
    if [[ -n "${auth_header}" ]]; then
      wget --tries=3 -c --show-progress --header="${auth_header}" -O "${tmp}" "${url}" || rc=$?
    else
      wget --tries=3 -c --show-progress -O "${tmp}" "${url}" || rc=$?
    fi
    if [[ "${rc}" -ne 0 && -f "${tmp}" ]]; then
      rm -f "${tmp}"
      rc=0
      if [[ -n "${auth_header}" ]]; then
        wget --tries=3 --show-progress --header="${auth_header}" -O "${tmp}" "${url}" || rc=$?
      else
        wget --tries=3 --show-progress -O "${tmp}" "${url}" || rc=$?
      fi
    fi
    if [[ "${rc}" -ne 0 ]]; then
      return "${rc}"
    fi
  else
    echo "❌ Neither curl nor wget found. Install curl and re-run." >&2
    return 1
  fi
  mv -f "${tmp}" "${dest}"
}

# ─── Variant metadata resolver (no declare -A for Bash 3.2) ───────────
# Sets: VARIANT_KEY, MODEL_FILE, MODEL_SIZE_HINT, HAS_MTP, IS_MLX
resolve_variant() {
  local v
  v="$(to_lower "$1")"
  IS_MLX=0
  HAS_MTP=0
  case "${v}" in
    auto|default|bonsai25|bonsai2.5)
      VARIANT_KEY="auto"
      MODEL_FILE=""
      MODEL_SIZE_HINT="~6.2–7.5 GB"
      HAS_MTP=1
      ;;
    ptq1-mtp|ptq1_0-mtp)
      VARIANT_KEY="ptq1-mtp"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf"
      MODEL_SIZE_HINT="6.23 GB"
      HAS_MTP=1
      ;;
    pq2-mtp|pq2_0-mtp)
      VARIANT_KEY="pq2-mtp"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf"
      MODEL_SIZE_HINT="7.49 GB"
      HAS_MTP=1
      ;;
    q2-mtp|q2_0-mtp)
      VARIANT_KEY="q2-mtp"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf"
      MODEL_SIZE_HINT="7.91 GB"
      HAS_MTP=1
      ;;
    ptq1|ptq1_0)
      VARIANT_KEY="ptq1"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PTQ1_0.gguf"
      MODEL_SIZE_HINT="5.99 GB"
      HAS_MTP=0
      ;;
    pq2|pq2_0)
      VARIANT_KEY="pq2"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PQ2_0.gguf"
      MODEL_SIZE_HINT="7.25 GB"
      HAS_MTP=0
      ;;
    q2|q2_0)
      VARIANT_KEY="q2"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-Q2_0.gguf"
      MODEL_SIZE_HINT="7.67 GB"
      HAS_MTP=0
      ;;
    mlx)
      VARIANT_KEY="mlx"
      MODEL_FILE="model.safetensors"
      MODEL_SIZE_HINT="~8.6 GB"
      HAS_MTP=1
      IS_MLX=1
      ;;
    *)
      echo "❌ Unknown variant '${1}'" >&2
      echo "   Valid: auto, ptq1-mtp, pq2-mtp, q2-mtp, ptq1, pq2, q2, mlx" >&2
      exit 1
      ;;
  esac
}

# Validate initial variant & options early
resolve_variant "${MODEL_VARIANT}"

MODE="$(to_lower "${MODE}")"
case "${MODE}" in
  thinking|instruct) ;;
  *)
    echo "❌ Unknown MODE '${MODE}' (valid: thinking, instruct)" >&2
    exit 1
    ;;
esac

REASONING_EFFORT="$(to_lower "${REASONING_EFFORT}")"
case "${REASONING_EFFORT}" in
  default|xhigh|medium) ;;
  *)
    echo "❌ Unknown REASONING_EFFORT '${REASONING_EFFORT}' (valid: default, xhigh, medium)" >&2
    exit 1
    ;;
esac

MTP="$(to_lower "${MTP}")"
case "${MTP}" in
  auto|on|off|1|0)
    [[ "${MTP}" == "1" ]] && MTP="on"
    [[ "${MTP}" == "0" ]] && MTP="off"
    ;;
  *)
    echo "❌ Unknown MTP '${MTP}' (valid: auto, on, off)" >&2
    exit 1
    ;;
esac

MMPROJ_QUANT="$(printf '%s' "${MMPROJ_QUANT}" | tr '[:lower:]' '[:upper:]')"
case "${MMPROJ_QUANT}" in
  Q8_0) MMPROJ_FILE="Ternary-Bonsai-2.5-27B-mmproj-Q8_0.gguf"; MMPROJ_SIZE_HINT="0.63 GB" ;;
  BF16) MMPROJ_FILE="Ternary-Bonsai-2.5-27B-mmproj-BF16.gguf"; MMPROJ_SIZE_HINT="0.93 GB" ;;
  *)
    echo "❌ Unknown MMPROJ_QUANT '${MMPROJ_QUANT}' (valid: Q8_0, BF16)" >&2
    exit 1
    ;;
esac
if [[ "${NO_VISION}" == "1" ]]; then
  MMPROJ_FILE=""
fi

# ─── Step 1: OS, Arch & Backend Detection ────────────────────────────
ARCH_RAW="${BONSAI_TEST_ARCH:-$(uname -m)}"
case "${ARCH_RAW}" in
  x86_64|amd64) ARCH_TAG="x64" ;;
  arm64|aarch64|armv8*) ARCH_TAG="arm64" ;;
  *)
    echo "❌ Unsupported CPU architecture: ${ARCH_RAW} (supported: x86_64, arm64/aarch64)" >&2
    exit 1
    ;;
esac

case "${OS_NAME}" in
  Linux|Darwin) ;;
  *)
    echo "❌ Unsupported OS: ${OS_NAME}" >&2
    exit 1
    ;;
esac

IS_WSL=0
if [[ "${OS_NAME}" == "Linux" && -z "${BONSAI_TEST_OS:-}" ]]; then
  if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi "microsoft" /proc/version 2>/dev/null; then
    IS_WSL=1
  fi
fi

find_nvidia_smi() {
  local cand
  if command -v nvidia-smi >/dev/null 2>&1; then
    command -v nvidia-smi
    return 0
  fi
  for cand in /usr/lib/wsl/lib/nvidia-smi /usr/bin/nvidia-smi /usr/local/nvidia/bin/nvidia-smi; do
    if [[ -x "${cand}" ]]; then
      echo "${cand}"
      return 0
    fi
  done
  return 1
}

has_linux_vulkan_gpu() {
  if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary 2>/dev/null | grep -E "deviceType" | grep -qv "CPU"; then
      return 0
    fi
    return 1
  fi
  # Fallback when vulkan-tools is not installed (common on Ubuntu/Fedora desktops):
  # check for a DRM render node + libvulkan.so.1 + non-software Vulkan ICD JSON.
  if [[ "${IS_WSL}" == "0" && -e /dev/dri/renderD128 ]]; then
    local has_lib=0
    if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q "libvulkan\.so\.1"; then
      has_lib=1
    else
      local libp
      for libp in /usr/lib/x86_64-linux-gnu/libvulkan.so.1 /usr/lib/aarch64-linux-gnu/libvulkan.so.1 /usr/lib64/libvulkan.so.1 /usr/lib/libvulkan.so.1; do
        if [[ -e "${libp}" ]]; then has_lib=1; break; fi
      done
    fi
    if [[ "${has_lib}" == "1" ]]; then
      local icd
      for icd in /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json; do
        [[ -f "${icd}" ]] || continue
        case "$(basename "${icd}")" in
          *lvp*|*lavapipe*|*swiftshader*) continue ;;
          *) return 0 ;;
        esac
      done
    fi
  fi
  return 1
}

BACKEND=""
BACKEND_AUTO=0
CUDA_VER=""
CUDA_TAG=""
TOTAL_VRAM_MB=0
TOTAL_RAM_MB="$(get_ram_mb)"
NVSMI_BIN="$(find_nvidia_smi || true)"

detect_cuda_version() {
  if [[ -n "${BONSAI_TEST_CUDA_VER:-}" ]]; then
    CUDA_VER="${BONSAI_TEST_CUDA_VER}"
  elif [[ -n "${NVSMI_BIN}" ]]; then
    CUDA_VER="$("${NVSMI_BIN}" 2>/dev/null | sed -n 's/.*CUDA[ A-Z]*Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
  fi
  if [[ -z "${CUDA_VER}" ]]; then
    if command -v nvcc >/dev/null 2>&1; then
      CUDA_VER="$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
    elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
      CUDA_VER="$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
    fi
  fi
  if [[ -n "${CUDA_VER}" ]]; then
    local major minor
    major="${CUDA_VER%%.*}"
    minor="${CUDA_VER#*.}"
    if [[ "${major}" -gt 13 ]] || { [[ "${major}" -eq 13 ]] && [[ "${minor}" -ge 3 ]]; }; then
      CUDA_TAG="13.3"
    elif [[ "${major}" -eq 13 ]] || { [[ "${major}" -eq 12 ]] && [[ "${minor}" -ge 8 ]]; }; then
      CUDA_TAG="12.8"
    else
      CUDA_TAG="12.4"
    fi
  else
    CUDA_TAG="12.4"
  fi
}

if [[ -n "${BONSAI_TEST_BACKEND:-}" ]]; then
  BACKEND="$(to_lower "${BONSAI_TEST_BACKEND}")"
  if [[ "${BACKEND}" == "cuda" ]]; then
    detect_cuda_version
    TOTAL_VRAM_MB="${BONSAI_TEST_VRAM_MB:-0}"
  fi
elif [[ -n "${BACKEND_OVERRIDE}" ]]; then
  BACKEND="$(to_lower "${BACKEND_OVERRIDE}")"
  case "${BACKEND}" in
    cuda|rocm|vulkan|metal|cpu) ;;
    mlx)
      MODEL_VARIANT="mlx"
      resolve_variant "mlx"
      BACKEND="metal"
      ;;
    *)
      echo "❌ Unknown BACKEND '${BACKEND_OVERRIDE}' (valid: cuda, rocm, vulkan, metal, cpu)" >&2
      exit 1
      ;;
  esac
  if [[ "${BACKEND}" == "cuda" ]]; then
    detect_cuda_version
    if [[ -n "${NVSMI_BIN}" ]]; then
      local_vram="$("${NVSMI_BIN}" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' ' || echo 0)"
      [[ "${local_vram}" =~ ^[0-9]+$ ]] && TOTAL_VRAM_MB="${local_vram}"
    fi
  fi
elif [[ "${OS_NAME}" == "Darwin" ]]; then
  BACKEND_AUTO=1
  if [[ "${ARCH_TAG}" == "arm64" ]]; then
    BACKEND="metal"
  else
    BACKEND="cpu"
  fi
else
  BACKEND_AUTO=1
  # Linux hardware detection
  if [[ -n "${NVSMI_BIN}" ]] && "${NVSMI_BIN}" --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 | grep -q . 2>/dev/null; then
    BACKEND="cuda"
    detect_cuda_version
    local_vram="$("${NVSMI_BIN}" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' ' || echo 0)"
    if [[ "${local_vram}" =~ ^[0-9]+$ ]]; then
      TOTAL_VRAM_MB="${local_vram}"
    fi
  elif [[ "${ARCH_TAG}" == "x64" ]]; then
    ROCM_SMI_BIN="$(command -v rocm-smi 2>/dev/null || true)"
    [[ -z "${ROCM_SMI_BIN}" && -x /opt/rocm/bin/rocm-smi ]] && ROCM_SMI_BIN="/opt/rocm/bin/rocm-smi"
    ROCMINFO_BIN="$(command -v rocminfo 2>/dev/null || true)"
    [[ -z "${ROCMINFO_BIN}" && -x /opt/rocm/bin/rocminfo ]] && ROCMINFO_BIN="/opt/rocm/bin/rocminfo"
    if [[ -n "${ROCM_SMI_BIN}" ]] && "${ROCM_SMI_BIN}" --showproductname 2>/dev/null | grep -qiE "AMD|Radeon|Instinct|GPU"; then
      BACKEND="rocm"
    elif [[ -n "${ROCMINFO_BIN}" ]] && "${ROCMINFO_BIN}" 2>/dev/null | grep -q "Device Type:.*GPU"; then
      BACKEND="rocm"
    fi
  fi
  if [[ -z "${BACKEND}" ]] && has_linux_vulkan_gpu; then
    BACKEND="vulkan"
  fi
  if [[ -z "${BACKEND}" ]]; then
    BACKEND="cpu"
  fi
fi

# Apple M5 on macOS 26.2–26.4 workaround: OS MetalPerformancePrimitives header bug breaks
# runtime tensor-API shader compilation (PrismML Bonsai-demo #93 / ollama #15594).
METAL_TENSOR_WORKAROUND=0
if [[ "${OS_NAME}" == "Darwin" && "${ARCH_TAG}" == "arm64" && "${BACKEND}" == "metal" ]]; then
  if [[ -z "${GGML_METAL_TENSOR_DISABLE+x}" ]]; then
    MAC_CPU_BRAND="${BONSAI_TEST_CPU_BRAND:-$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)}"
    MAC_OS_VER="${BONSAI_TEST_MACOS_VER:-$(sw_vers -productVersion 2>/dev/null || true)}"
    case "${MAC_CPU_BRAND}" in
      *"Apple M5"*|*"M5"*)
        case "${MAC_OS_VER}" in
          26.2|26.2.*|26.3|26.3.*|26.4|26.4.*)
            export GGML_METAL_TENSOR_DISABLE=1
            METAL_TENSOR_WORKAROUND=1
            ;;
        esac
        ;;
    esac
  fi
fi

# Determine recommended variant and hardware-aware tuning reason
RECOMMENDED_VARIANT=""
AUTO_REASON=""
if [[ "${BACKEND}" == "cuda" ]]; then
  RECOMMENDED_VARIANT="ptq1-mtp"
  if [[ "${TOTAL_VRAM_MB}" -gt 0 && "${TOTAL_VRAM_MB}" -le 6800 ]]; then
    AUTO_REASON="CUDA <=6GB VRAM (${TOTAL_VRAM_MB} MB): PTQ1_0-mtp + auto layer fit + 16K ctx + KV4 + CPU mmproj"
  elif [[ "${TOTAL_VRAM_MB}" -gt 0 && "${TOTAL_VRAM_MB}" -le 9500 ]]; then
    AUTO_REASON="CUDA <=9GB VRAM (${TOTAL_VRAM_MB} MB): smallest PTQ1_0-mtp + 16K ctx + KV4 + CPU mmproj"
  elif [[ "${TOTAL_VRAM_MB}" -gt 0 ]]; then
    AUTO_REASON="CUDA (${TOTAL_VRAM_MB} MB VRAM): PTQ1_0-mtp is fastest decode on NVIDIA + built-in MTP"
  else
    AUTO_REASON="CUDA (unified memory): PTQ1_0-mtp is fastest decode on NVIDIA + built-in MTP"
  fi
elif [[ "${BACKEND}" == "rocm" ]]; then
  RECOMMENDED_VARIANT="ptq1-mtp"
  AUTO_REASON="AMD ROCm: PTQ1_0-mtp + built-in MTP"
elif [[ "${BACKEND}" == "metal" ]]; then
  if [[ "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 14000 ]]; then
    RECOMMENDED_VARIANT="ptq1-mtp"
    AUTO_REASON="Apple Silicon tight RAM (${TOTAL_RAM_MB} MB): smallest PTQ1_0-mtp + 8K ctx + KV4 + CPU mmproj"
  elif [[ "${TOTAL_RAM_MB}" -ge 14000 && "${TOTAL_RAM_MB}" -lt 22000 ]]; then
    RECOMMENDED_VARIANT="pq2-mtp"
    AUTO_REASON="Apple Silicon Metal (${TOTAL_RAM_MB} MB RAM): PQ2_0-mtp + safe 16K context"
  else
    RECOMMENDED_VARIANT="pq2-mtp"
    AUTO_REASON="Apple Silicon Metal (${TOTAL_RAM_MB} MB RAM): PQ2_0-mtp is PrismML's benchmarked Metal packing"
  fi
else
  if [[ "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 12000 ]]; then
    RECOMMENDED_VARIANT="ptq1-mtp"
    AUTO_REASON="${BACKEND} tight RAM (${TOTAL_RAM_MB} MB): smallest PTQ1_0-mtp + 8K ctx + KV4"
  elif [[ "${TOTAL_RAM_MB}" -ge 12000 && "${TOTAL_RAM_MB}" -lt 20000 ]]; then
    RECOMMENDED_VARIANT="pq2-mtp"
    AUTO_REASON="${BACKEND} (${TOTAL_RAM_MB} MB RAM): PQ2_0-mtp + safe 16K context"
  else
    RECOMMENDED_VARIANT="pq2-mtp"
    AUTO_REASON="${BACKEND} (${TOTAL_RAM_MB} MB RAM): PQ2_0-mtp for smooth unpacking and strong prefill"
  fi
fi

# Interactive menu only when --choose is explicitly requested
if [[ "${CHOOSE_MODE}" == "1" && -t 0 && "${NON_INTERACTIVE}" != "1" && "${DRY_RUN}" != "1" ]]; then
  echo "══════════════════════════════════════════════════════════"
  echo "  Ternary Bonsai 2.5 27B Runner — Interactive Setup"
  echo "══════════════════════════════════════════════════════════"
  echo "   OS / Arch:   ${OS_NAME} (${ARCH_TAG})"
  echo "   Backend:     ${BACKEND}${CUDA_TAG:+ (CUDA ${CUDA_TAG})}"
  [[ "${TOTAL_RAM_MB}" -gt 0 ]] && echo "   System RAM:  ${TOTAL_RAM_MB} MB"
  [[ "${BACKEND}" == "cuda" && "${TOTAL_VRAM_MB}" -gt 0 ]] && echo "   GPU VRAM:    ${TOTAL_VRAM_MB} MB"
  echo ""
  echo "   ptq1-mtp  6.23 GB — PTQ1_0 + MTP head (fastest on NVIDIA CUDA, smallest MTP)"
  echo "   pq2-mtp   7.49 GB — PQ2_0  + MTP head (benchmarked on Apple Metal, great for CPU/Vulkan)"
  echo "   q2-mtp    7.91 GB — Q2_0   + MTP head (stock llama.cpp b11556+ compatible)"
  echo "   ptq1      5.99 GB — PTQ1_0 base (no MTP head)"
  echo "   pq2       7.25 GB — PQ2_0  base (no MTP head)"
  echo "   q2        7.67 GB — Q2_0   base (no MTP head)"
  if [[ "${OS_NAME}" == "Darwin" && "${ARCH_TAG}" == "arm64" ]]; then
    echo "   mlx       ~8.6 GB — Apple Silicon MLX 2-bit OpenAI/Anthropic server"
  fi
  echo ""
  echo "   Auto-recommended: ${RECOMMENDED_VARIANT} (${AUTO_REASON})"
  echo ""
  if [[ "${OS_NAME}" == "Darwin" && "${ARCH_TAG}" == "arm64" ]]; then
    read -r -p "Choose variant [ptq1-mtp/pq2-mtp/q2-mtp/ptq1/pq2/q2/mlx] (default: ${RECOMMENDED_VARIANT}): " CHOSEN
  else
    read -r -p "Choose variant [ptq1-mtp/pq2-mtp/q2-mtp/ptq1/pq2/q2] (default: ${RECOMMENDED_VARIANT}): " CHOSEN
  fi
  if [[ -n "${CHOSEN}" ]]; then
    MODEL_VARIANT="${CHOSEN}"
  else
    MODEL_VARIANT="${RECOMMENDED_VARIANT}"
  fi
  resolve_variant "${MODEL_VARIANT}"

  if [[ "${IS_MLX}" == "0" && "${CONTEXT_SIZE}" == "0" ]]; then
    read -r -p "Context size [0=auto / 16384 / 32768 / 65536 / 131072 / 262144] (default: 0): " CTX_CHOSEN
    if [[ -n "${CTX_CHOSEN}" ]]; then
      CONTEXT_SIZE="${CTX_CHOSEN}"
    fi
  fi
fi

# Resolve 'auto' (default zero-prompt path)
if [[ "${VARIANT_KEY}" == "auto" ]]; then
  MODEL_VARIANT="${RECOMMENDED_VARIANT}"
  resolve_variant "${MODEL_VARIANT}"
fi

# ─── MLX path (Apple Silicon macOS native mlx-vlm server & CLI) ───────
find_python311_plus() {
  local cand
  for cand in \
    python3.13 python3.12 python3.11 \
    /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3 \
    /usr/local/bin/python3.13 /usr/local/bin/python3.12 /usr/local/bin/python3.11 /usr/local/bin/python3 \
    python3
  do
    if command -v "${cand}" >/dev/null 2>&1; then
      if "${cand}" -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)" >/dev/null 2>&1; then
        command -v "${cand}"
        return 0
      fi
    fi
  done
  return 1
}

find_uv_bin() {
  local cand
  if command -v uv >/dev/null 2>&1; then
    command -v uv
    return 0
  fi
  for cand in "${BASE_DIR}/uv-bin/uv" "${HOME}/.local/bin/uv" "${HOME}/.cargo/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
    if [[ -x "${cand}" ]]; then
      echo "${cand}"
      return 0
    fi
  done
  return 1
}

mlx_venv_ready() {
  local vpy="$1"
  [[ -x "${vpy}" ]] || return 1
  "${vpy}" - <<'PY' >/dev/null 2>&1
import sys
from importlib.metadata import version

if sys.version_info < (3, 11):
    raise SystemExit(1)
expected = {
    "mlx": "0.32.3",
    "mlx-vlm": "0.7.8",
    "mlx-lm": "0.32.0",
    "transformers": "5.19.0",
}
for pkg, ver in expected.items():
    if version(pkg) != ver:
        raise SystemExit(1)
from mlx_vlm.models.prism_hadamard_qwen35 import Model  # noqa: F401
PY
}

if [[ "${IS_MLX}" == "1" ]]; then
  if [[ "${OS_NAME}" != "Darwin" || "${ARCH_TAG}" != "arm64" ]]; then
    echo "❌ The 'mlx' variant requires an Apple Silicon Mac (macOS arm64)." >&2
    echo "   On ${OS_NAME} (${ARCH_TAG}), use: bash start.sh ${RECOMMENDED_VARIANT}" >&2
    exit 1
  fi

  MLX_CTX="${CONTEXT_SIZE}"
  MLX_KV4="${KV4}"
  if [[ "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 14000 ]]; then
    [[ "${MLX_CTX}" == "0" ]] && MLX_CTX=8192
    [[ "${USER_SET_KV4}" == "0" ]] && MLX_KV4=1
  elif [[ "${TOTAL_RAM_MB}" -ge 14000 && "${TOTAL_RAM_MB}" -lt 22000 ]]; then
    [[ "${MLX_CTX}" == "0" ]] && MLX_CTX=16384
  fi
  [[ "${MLX_CTX}" == "0" ]] && MLX_CTX=32768

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY_RUN_PLAN:"
    echo "  OS=${OS_NAME}"
    echo "  ARCH=${ARCH_TAG}"
    echo "  BACKEND=mlx"
    echo "  RAM_MB=${TOTAL_RAM_MB}"
    echo "  VARIANT=mlx"
    echo "  HF_REPO=${HF_REPO_MLX}"
    echo "  MODE=${MODE}"
    echo "  CTX_VALUE=${MLX_CTX}"
    echo "  PARALLEL=${PARALLEL}"
    echo "  KV4=${MLX_KV4}"
    echo "  MLX_ONCE=${MLX_ONCE}"
    exit 0
  fi

  echo "══════════════════════════════════════════════════════════"
  echo "  Ternary Bonsai 2.5 27B — Apple Silicon MLX"
  echo "  HF repo:    ${HF_REPO_MLX} (~8.6 GB)"
  echo "  Mode:       ${MODE}$( [[ "${MLX_ONCE}" == "1" ]] && echo " (one-shot CLI)" || echo " (OpenAI/Anthropic server)" )"
  echo "  Tip:        'bash start.sh pq2-mtp' runs Metal llama-server (faster decode + built-in Web UI)"
  echo "══════════════════════════════════════════════════════════"

  MLX_DIR="${MODELS_DIR}/mlx"
  MLX_VENV="${BASE_DIR}/venv-mlx"
  MLX_PY="${MLX_VENV}/bin/python"
  mkdir -p "${BASE_DIR}" "${MODELS_DIR}"

  # Step 1: Ensure Python >= 3.11 venv with native Hadamard mlx-vlm==0.7.8
  # Note: stock macOS /usr/bin/python3 is Python 3.9.6, which cannot install mlx-lm>=0.32!
  echo ""
  echo "── Step 1: Setting up Apple Silicon MLX runtime ──"
  if mlx_venv_ready "${MLX_PY}"; then
    echo "✔  MLX Python environment ready (${MLX_VENV})"
  else
    if [[ "${HF_HUB_OFFLINE:-0}" == "1" ]]; then
      echo "❌ HF_HUB_OFFLINE=1 and MLX Python environment at ${MLX_VENV} is missing or outdated." >&2
      exit 1
    fi
    # Remove any older Python <3.11 venv created by /usr/bin/python3
    if [[ -x "${MLX_PY}" ]] && ! "${MLX_PY}" -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)" >/dev/null 2>&1; then
      echo "   Replacing older Python (<3.11) venv at ${MLX_VENV} ..."
      rm -rf "${MLX_VENV}"
    fi

    UV_BIN="$(find_uv_bin || true)"
    PY311_BIN="$(find_python311_plus || true)"

    if [[ -z "${UV_BIN}" && -z "${PY311_BIN}" ]]; then
      echo "   macOS system Python is <3.11 — bootstrapping standalone uv + Python 3.11 in ${BASE_DIR}/uv-bin ..."
      mkdir -p "${BASE_DIR}/uv-bin"
      UV_TMP="${BASE_DIR}/uv-install.sh"
      download_url "https://astral.sh/uv/install.sh" "${UV_TMP}"
      UV_INSTALL_DIR="${BASE_DIR}/uv-bin" UV_NO_MODIFY_PATH=1 sh "${UV_TMP}" </dev/null >/dev/null
      rm -f "${UV_TMP}"
      UV_BIN="$(find_uv_bin || true)"
    fi

    MLX_REQS=(
      "mlx==0.32.3"
      "mlx-vlm==0.7.8"
      "mlx-lm==0.32.0"
      "transformers==5.19.0"
      "huggingface_hub>=0.26.0"
      "certifi>=2026.10.23"
    )

    if [[ -n "${UV_BIN}" ]]; then
      if [[ ! -x "${MLX_PY}" ]]; then
        echo "   Creating Python 3.11 venv with uv at ${MLX_VENV} ..."
        "${UV_BIN}" venv "${MLX_VENV}" --python "${PY311_BIN:-3.11}"
      fi
      echo "   Installing tested MLX native runtime (mlx 0.32.3, mlx-vlm 0.7.8)..."
      "${UV_BIN}" pip install --python "${MLX_PY}" "${MLX_REQS[@]}"
    elif [[ -n "${PY311_BIN}" ]]; then
      if [[ ! -x "${MLX_PY}" ]]; then
        echo "   Creating venv with ${PY311_BIN} at ${MLX_VENV} ..."
        "${PY311_BIN}" -m venv "${MLX_VENV}"
      fi
      echo "   Installing tested MLX native runtime (mlx 0.32.3, mlx-vlm 0.7.8)..."
      "${MLX_PY}" -m pip install --upgrade pip
      "${MLX_PY}" -m pip install "${MLX_REQS[@]}"
    else
      echo "❌ Could not find or bootstrap Python 3.11+ / uv. Install Homebrew Python ('brew install python@3.12') and re-run." >&2
      exit 1
    fi

    if ! mlx_venv_ready "${MLX_PY}"; then
      echo "❌ MLX runtime verification failed (prism_hadamard_qwen35 loader unavailable)." >&2
      exit 1
    fi
    echo "✔  MLX native runtime installed and verified"
  fi

  # Step 2: Locate or download MLX checkpoint
  echo ""
  echo "── Step 2: Checking Ternary Bonsai 2.5 27B MLX weights ──"
  if [[ ! -f "${MLX_DIR}/config.json" || "$(get_file_size_bytes "${MLX_DIR}/model.safetensors")" -lt 104857600 ]]; then
    for mlx_cache in \
      "${HOME}/.bonsai/models/mlx" \
      "${HOME}/models/Ternary-Bonsai-2.5-27B-mlx-2bit" \
      "${SCRIPT_DIR}/models/Ternary-Bonsai-2.5-27B-mlx-2bit"
    do
      if [[ -f "${mlx_cache}/config.json" && "$(get_file_size_bytes "${mlx_cache}/model.safetensors")" -ge 104857600 ]]; then
        echo "✔  Found cached MLX model at ${mlx_cache} — symlinking..."
        rm -rf "${MLX_DIR}"
        ln -s "${mlx_cache}" "${MLX_DIR}"
        break
      fi
    done
  fi

  if [[ ! -f "${MLX_DIR}/config.json" || "$(get_file_size_bytes "${MLX_DIR}/model.safetensors")" -lt 104857600 ]]; then
    if [[ "${HF_HUB_OFFLINE:-0}" == "1" ]]; then
      echo "❌ HF_HUB_OFFLINE=1 and MLX model pack not found at ${MLX_DIR}" >&2
      exit 1
    fi
    mkdir -p "${MLX_DIR}"
    echo "   Downloading ${HF_REPO_MLX} (~8.6 GB) to ${MLX_DIR} ..."
    HF_REPO_MLX="${HF_REPO_MLX}" MLX_DIR="${MLX_DIR}" HF_HUB_DISABLE_XET=1 PYTHONUTF8=1 \
      "${MLX_PY}" - <<'PY'
import os
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id=os.environ["HF_REPO_MLX"],
    local_dir=os.environ["MLX_DIR"],
    token=os.environ.get("HF_TOKEN") or None,
)
PY
    if [[ ! -f "${MLX_DIR}/config.json" || "$(get_file_size_bytes "${MLX_DIR}/model.safetensors")" -lt 104857600 ]]; then
      echo "❌ MLX model download appears incomplete in ${MLX_DIR}" >&2
      exit 1
    fi
    echo "✔  Downloaded MLX pack to ${MLX_DIR}"
  else
    echo "✔  MLX model pack ready at ${MLX_DIR}"
  fi

  # Optional one-shot prompt mode: bash start.sh mlx -p "prompt"
  if [[ "${MLX_ONCE}" == "1" ]]; then
    PROMPT_TEXT="${MLX_PROMPT:-What is 2 plus 2? Answer with the number only.}"
    echo ""
    echo "── Step 3: Running one-shot MLX generation ──"
    MLX_DIR="${MLX_DIR}" PROMPT_TEXT="${PROMPT_TEXT}" MODE="${MODE}" \
      TRANSFORMERS_VERBOSITY=error TOKENIZERS_PARALLELISM=false \
      "${MLX_PY}" - <<'PY'
import os
import mlx.core as mx
from mlx_vlm import generate, load
from mlx_vlm.prompt_utils import apply_chat_template

mx.set_default_device(mx.gpu)
pack = os.environ["MLX_DIR"]
mode = os.environ.get("MODE", "thinking")
thinking = (mode == "thinking")
model, processor = load(pack)
prompt = apply_chat_template(
    processor, model.config, os.environ["PROMPT_TEXT"], num_images=0, enable_thinking=thinking
)
out = generate(
    model,
    processor,
    prompt,
    [],
    max_tokens=4096 if thinking else 1024,
    temperature=1.0 if thinking else 0.7,
    top_p=0.95 if thinking else 0.80,
    top_k=20,
    min_p=0.0,
    presence_penalty=0.0 if thinking else 1.5,
    repetition_penalty=1.0,
    verbose=False,
)
print((out if isinstance(out, str) else getattr(out, "text", str(out))).strip())
PY
    exit 0
  fi

  # Default MLX mode: start OpenAI & Anthropic compatible mlx_vlm.server
  FINAL_PORT="$(select_free_port "${PORT}" || true)"
  if [[ -z "${FINAL_PORT}" ]]; then
    echo "❌ Ports ${PORT}..$((PORT + 2)) are all busy. Set PORT=<free_port> and re-run." >&2
    exit 1
  fi
  if [[ "${FINAL_PORT}" != "${PORT}" ]]; then
    echo "   Port ${PORT} busy → using port ${FINAL_PORT}"
  fi

  MLX_SERVER_ARGS=(
    -m mlx_vlm.server
    --model "${MLX_DIR}"
    --host "${HOST}"
    --port "${FINAL_PORT}"
    --max-kv-size "${MLX_CTX}"
  )
  if [[ "${MODE}" == "thinking" ]]; then
    MLX_SERVER_ARGS+=(--enable-thinking)
  fi
  if [[ "${MLX_KV4}" == "1" ]]; then
    MLX_SERVER_ARGS+=(--kv-bits 4)
  fi
  if [[ "${PARALLEL}" != "0" && -n "${PARALLEL}" ]]; then
    MLX_SERVER_ARGS+=(--max-num-seqs "${PARALLEL}")
  fi

  DISPLAY_HOST="${HOST}"
  [[ "${DISPLAY_HOST}" == "0.0.0.0" ]] && DISPLAY_HOST="localhost"

  echo ""
  echo "── Step 3: Starting MLX OpenAI/Anthropic Server ──"
  echo "   Model:     ${MLX_DIR}"
  echo "   OpenAI:    http://${DISPLAY_HOST}:${FINAL_PORT}/v1/chat/completions"
  echo "   Anthropic: http://${DISPLAY_HOST}:${FINAL_PORT}/v1/messages"
  echo "   API Docs:  http://${DISPLAY_HOST}:${FINAL_PORT}/docs"
  echo "   Context:   ${MLX_CTX} max KV tokens$( [[ "${MLX_KV4}" == "1" ]] && echo " (4-bit KV)" )"
  echo ""
  echo "   Test it:   PORT=${FINAL_PORT} bash test-model.sh"
  echo "   Stop it:   Press Ctrl+C or run: bash stop.sh"
  echo ""

  mkdir -p "$(dirname "${PID_FILE}")"
  export TRANSFORMERS_VERBOSITY=error
  export TOKENIZERS_PARALLELISM=false

  if [[ "${DETACHED}" == "1" ]]; then
    LOG_FILE="${BASE_DIR}/mlx-server.log"
    nohup "${MLX_PY}" "${MLX_SERVER_ARGS[@]}" > "${LOG_FILE}" 2>&1 &
    SERVER_PID=$!
    echo "${SERVER_PID}" > "${PID_FILE}"
    echo "   PID:  ${SERVER_PID} (saved to ${PID_FILE})"
    echo "   Logs: ${LOG_FILE}"
    exit 0
  fi

  SERVER_PID=""
  cleanup_mlx() {
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
      kill "${SERVER_PID}" 2>/dev/null || true
      wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
  }
  trap cleanup_mlx INT TERM

  "${MLX_PY}" "${MLX_SERVER_ARGS[@]}" &
  SERVER_PID=$!
  echo "${SERVER_PID}" > "${PID_FILE}"
  echo "   PID: ${SERVER_PID} (saved to ${PID_FILE})"
  wait "${SERVER_PID}"
  EXIT_CODE=$?
  rm -f "${PID_FILE}"
  exit "${EXIT_CODE}"
fi

# ─── Determine prebuilt release asset vs source build ─────────────────
resolve_release_tag() {
  if [[ "${PRISM_RELEASE}" != "latest" ]]; then
    echo "${PRISM_RELEASE}"
    return
  fi
  local tag=""
  if command -v curl >/dev/null 2>&1; then
    tag="$(curl -sL --max-time 10 -H "User-Agent: bonsai-runner2" "https://api.github.com/repos/PrismML-Eng/llama.cpp/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  fi
  if [[ -n "${tag}" ]]; then
    echo "${tag}"
  else
    echo "${DEFAULT_PRISM_RELEASE}"
  fi
}

RELEASE_TAG="$(resolve_release_tag)"
PREBUILT_ASSET=""
NEEDS_SOURCE_BUILD=0

if [[ "${BUILD_FROM_SOURCE}" == "1" ]]; then
  NEEDS_SOURCE_BUILD=1
else
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    if [[ "${ARCH_TAG}" == "arm64" ]]; then
      PREBUILT_ASSET="llama-${RELEASE_TAG}-bin-macos-arm64.tar.gz"
    else
      PREBUILT_ASSET="llama-${RELEASE_TAG}-bin-macos-x64.tar.gz"
    fi
  else
    # Linux
    case "${BACKEND}" in
      cuda)
        if [[ "${ARCH_TAG}" == "x64" ]]; then
          PREBUILT_ASSET="llama-${RELEASE_TAG}-bin-linux-cuda-${CUDA_TAG:-12.4}-x64.tar.gz"
        else
          # ARM64 + CUDA (e.g. DGX Spark GB10) has no prebuilt release archive → build from source
          NEEDS_SOURCE_BUILD=1
        fi
        ;;
      rocm)
        if [[ "${ARCH_TAG}" == "x64" ]]; then
          PREBUILT_ASSET="llama-${RELEASE_TAG}-bin-ubuntu-rocm-7.2-x64.tar.gz"
        else
          NEEDS_SOURCE_BUILD=1
        fi
        ;;
      vulkan)
        PREBUILT_ASSET="llama-${RELEASE_TAG}-bin-ubuntu-vulkan-${ARCH_TAG}.tar.gz"
        ;;
      cpu)
        PREBUILT_ASSET="llama-${RELEASE_TAG}-bin-ubuntu-${ARCH_TAG}.tar.gz"
        ;;
      *)
        NEEDS_SOURCE_BUILD=1
        ;;
    esac
  fi
fi

# Resolve hardware-aware context, VRAM safeguards, GPU layers, and MTP flags
CTX_VALUE="${CONTEXT_SIZE}"
EFF_NGL="${NGL}"

if [[ "${BACKEND}" == "cuda" && "${TOTAL_VRAM_MB}" -gt 0 && "${TOTAL_VRAM_MB}" -le 6800 ]]; then
  # <=6 GB VRAM laptop GPU (e.g. RTX 3050 / 3060 6GB / 4050): let --fit auto-split GPU/CPU layers cleanly
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=16384
  [[ "${USER_SET_MMPROJ_CPU}" == "0" ]] && MMPROJ_CPU=1
  [[ "${USER_SET_KV4}" == "0" ]] && KV4=1
  [[ "${USER_SET_NGL}" == "0" ]] && EFF_NGL="auto"
elif [[ "${BACKEND}" == "cuda" && "${TOTAL_VRAM_MB}" -gt 0 && "${TOTAL_VRAM_MB}" -le 9500 ]]; then
  # 8 GB VRAM GPU: fit PTQ1_0 + KV4 + 16K context comfortably by keeping mmproj in system RAM
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=16384
  [[ "${USER_SET_MMPROJ_CPU}" == "0" ]] && MMPROJ_CPU=1
  [[ "${USER_SET_KV4}" == "0" ]] && KV4=1
elif [[ "${BACKEND}" == "metal" && "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 14000 ]]; then
  # 8 GB Apple Silicon Mac: conservative 8K context + KV4 + CPU mmproj
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=8192
  [[ "${USER_SET_MMPROJ_CPU}" == "0" ]] && MMPROJ_CPU=1
  [[ "${USER_SET_KV4}" == "0" ]] && KV4=1
elif [[ "${BACKEND}" == "metal" && "${TOTAL_RAM_MB}" -ge 14000 && "${TOTAL_RAM_MB}" -lt 22000 ]]; then
  # 16–18 GB Apple Silicon Mac: 16K context leaves safe Metal wired headroom alongside macOS apps
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=16384
elif [[ "${BACKEND}" != "cuda" && "${BACKEND}" != "rocm" && "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 12000 ]]; then
  # Tight-RAM CPU/Vulkan host
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=8192
  [[ "${USER_SET_KV4}" == "0" ]] && KV4=1
elif [[ "${BACKEND}" != "cuda" && "${BACKEND}" != "rocm" && "${TOTAL_RAM_MB}" -ge 12000 && "${TOTAL_RAM_MB}" -lt 20000 ]]; then
  # 16 GB CPU/Vulkan laptop: 16K context keeps ~6 GB free for OS + browser
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=16384
fi
if [[ "${CTX_VALUE}" == "0" ]]; then
  CTX_VALUE=32768
fi

if [[ "${BACKEND}" == "cpu" ]]; then
  EFF_NGL=0
fi

compute_mtp_settings() {
  MTP_ENABLED=0
  EFF_MTP_NMAX=""
  EFF_MTP_PMIN=""
  if [[ "${HAS_MTP}" == "1" && "${MTP}" != "off" ]]; then
    if [[ "${MTP}" == "on" ]]; then
      MTP_ENABLED=1
    else
      case "${BACKEND}" in
        cuda|rocm|metal|vulkan) MTP_ENABLED=1 ;;
        *) MTP_ENABLED=0 ;;
      esac
    fi
  fi
  if [[ "${MTP_ENABLED}" == "1" ]]; then
    if [[ "${BACKEND}" == "metal" ]]; then
      EFF_MTP_NMAX="${MTP_NMAX:-1}"
      EFF_MTP_PMIN="${MTP_PMIN:-0.6}"
    elif [[ "${BACKEND}" == "vulkan" ]]; then
      if [[ "${VARIANT_KEY}" == "ptq1-mtp" ]]; then
        EFF_MTP_NMAX="${MTP_NMAX:-2}"
      else
        EFF_MTP_NMAX="${MTP_NMAX:-1}"
      fi
      EFF_MTP_PMIN="${MTP_PMIN:-0.1}"
    else
      EFF_MTP_NMAX="${MTP_NMAX:-3}"
      EFF_MTP_PMIN="${MTP_PMIN:-0.1}"
    fi
  fi
}

compute_mtp_settings

# Dry-run summary for automated cross-platform verification
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY_RUN_PLAN:"
  echo "  OS=${OS_NAME}"
  echo "  ARCH=${ARCH_TAG}"
  echo "  BACKEND=${BACKEND}"
  echo "  CUDA_TAG=${CUDA_TAG}"
  echo "  VRAM_MB=${TOTAL_VRAM_MB}"
  echo "  RAM_MB=${TOTAL_RAM_MB}"
  echo "  VARIANT=${VARIANT_KEY}"
  echo "  AUTO_REASON=${AUTO_REASON}"
  echo "  HF_REPO=${HF_REPO_GGUF}"
  echo "  MODEL_FILE=${MODEL_FILE}"
  echo "  MMPROJ_FILE=${MMPROJ_FILE}"
  echo "  MMPROJ_CPU=${MMPROJ_CPU}"
  echo "  RELEASE_TAG=${RELEASE_TAG}"
  echo "  PREBUILT_ASSET=${PREBUILT_ASSET}"
  echo "  NEEDS_SOURCE_BUILD=${NEEDS_SOURCE_BUILD}"
  echo "  MODE=${MODE}"
  echo "  MTP_ENABLED=${MTP_ENABLED}"
  echo "  MTP_NMAX=${EFF_MTP_NMAX}"
  echo "  MTP_PMIN=${EFF_MTP_PMIN}"
  echo "  CTX_VALUE=${CTX_VALUE}"
  echo "  PARALLEL=${PARALLEL}"
  echo "  EFF_NGL=${EFF_NGL}"
  echo "  KV4=${KV4}"
  echo "  GGML_METAL_TENSOR_DISABLE=${GGML_METAL_TENSOR_DISABLE:-}"
  exit 0
fi

HW_LINE="${OS_NAME}/${ARCH_TAG} · ${BACKEND}${CUDA_TAG:+ (CUDA ${CUDA_TAG})}"
[[ "${TOTAL_VRAM_MB}" -gt 0 ]] && HW_LINE="${HW_LINE} · ${TOTAL_VRAM_MB} MB VRAM"
[[ "${TOTAL_RAM_MB}" -gt 0 ]] && HW_LINE="${HW_LINE} · ${TOTAL_RAM_MB} MB RAM"

echo "══════════════════════════════════════════════════════════"
echo "  Ternary Bonsai 2.5 27B Runner"
echo "  Variant:    ${VARIANT_KEY} (${MODEL_SIZE_HINT})"
echo "  Hardware:   ${HW_LINE}"
[[ -n "${AUTO_REASON}" ]] && echo "  Auto-pick:  ${AUTO_REASON}"
echo "  Mode:       ${MODE}"
if [[ "${MTP_ENABLED}" == "1" ]]; then
  echo "  MTP Draft:  ON (n-max=${EFF_MTP_NMAX}, p-min=${EFF_MTP_PMIN})"
elif [[ "${HAS_MTP}" == "1" ]]; then
  echo "  MTP Draft:  OFF (set MTP=on to force on ${BACKEND})"
else
  echo "  MTP Draft:  not included in ${VARIANT_KEY}"
fi
echo "  HF repo:    ${HF_REPO_GGUF}"
echo "  Model:      ${MODEL_FILE}"
if [[ -n "${MMPROJ_FILE}" ]]; then
  echo "  Vision:     ${MMPROJ_FILE} (${MMPROJ_SIZE_HINT})"
else
  echo "  Vision:     disabled (NO_VISION=1)"
fi
if [[ "${METAL_TENSOR_WORKAROUND}" == "1" ]]; then
  echo "  macOS M5:   GGML_METAL_TENSOR_DISABLE=1 auto-applied (macOS 26.2–26.4 Metal shader fix)"
fi
echo "══════════════════════════════════════════════════════════"

download_hf_file() {
  local repo="$1" file="$2" dest="$3" min_bytes="$4"
  if [[ -f "${dest}" ]]; then
    local sz
    sz="$(get_file_size_bytes "${dest}")"
    if [[ "${sz}" -ge "${min_bytes}" ]]; then
      echo "✔  Already present: ${dest} ($(du -h "${dest}" | cut -f1))"
      return 0
    fi
    echo "   ⚠  Existing file looks incomplete (${sz} bytes) — re-downloading..."
    rm -f "${dest}"
  fi

  local cache
  for cache in \
    "${MODELS_DIR}/${file}" \
    "${HOME}/.bonsai/models/${file}" \
    "${HOME}/.cache/huggingface/hub/${file}" \
    "${HOME}/models/${file}" \
    "${SCRIPT_DIR}/models/${file}"
  do
    if [[ -f "${cache}" && "${cache}" != "${dest}" ]]; then
      local csz
      csz="$(get_file_size_bytes "${cache}")"
      if [[ "${csz}" -ge "${min_bytes}" ]]; then
        echo "✔  Found cached file at ${cache} — symlinking..."
        mkdir -p "$(dirname "${dest}")"
        ln -sf "${cache}" "${dest}"
        return 0
      fi
    fi
  done

  if [[ "${HF_HUB_OFFLINE:-0}" == "1" ]]; then
    echo "❌ HF_HUB_OFFLINE=1 and '${file}' was not found in local caches." >&2
    echo "   Expected at: ${dest}" >&2
    return 1
  fi

  local url="https://huggingface.co/${repo}/resolve/main/${file}"
  echo "   Downloading ${repo}/${file} ..."
  download_url "${url}" "${dest}"
  local final_sz
  final_sz="$(get_file_size_bytes "${dest}")"
  if [[ "${final_sz}" -lt "${min_bytes}" ]]; then
    echo "❌ Downloaded file '${dest}' is unexpectedly small (${final_sz} bytes)." >&2
    rm -f "${dest}"
    return 1
  fi
  echo "✔  Downloaded: ${dest} ($(du -h "${dest}" | cut -f1))"
}

# ─── Step 2: Acquire PrismML llama.cpp runtime ────────────────────────
find_server_bin() {
  local root="$1"
  local found=""
  if [[ -x "${root}/llama-server" ]]; then
    echo "${root}/llama-server"
    return 0
  fi
  found="$(find "${root}" -maxdepth 4 -type f -name "llama-server" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${found}" ]]; then
    chmod +x "${found}" 2>/dev/null || true
    echo "${found}"
    return 0
  fi
  return 1
}

run_with_bin_libpath() {
  local bin="$1"
  shift
  local bdir
  bdir="$(dirname "${bin}")"
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    DYLD_LIBRARY_PATH="${bdir}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}" "${bin}" "$@"
  else
    local ldp="${bdir}"
    [[ "${IS_WSL}" == "1" && -d /usr/lib/wsl/lib ]] && ldp="${ldp}:/usr/lib/wsl/lib"
    LD_LIBRARY_PATH="${ldp}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "${bin}" "$@"
  fi
}

smoke_test_server_bin() {
  local bin="$1"
  run_with_bin_libpath "${bin}" --version >/dev/null 2>&1
}

has_usable_gpu_device() {
  local bin="$1"
  local dev_out
  dev_out="$(run_with_bin_libpath "${bin}" --list-devices 2>&1 || true)"
  if printf '%s\n' "${dev_out}" | grep -q "(none)"; then
    return 1
  fi
  return 0
}

build_from_source() {
  echo ""
  echo "── Building PrismML llama.cpp from source (${BACKEND}) ──"
  local missing=0
  for tool in git cmake; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "⚠  ${tool} not found." >&2
      missing=1
    fi
  done
  if ! command -v make >/dev/null 2>&1 && ! command -v ninja >/dev/null 2>&1; then
    echo "⚠  neither make nor ninja found." >&2
    missing=1
  fi
  if [[ "${missing}" == "1" ]]; then
    echo "❌ Source build requires git, cmake, make (or ninja), and a C++ compiler." >&2
    if [[ "${OS_NAME}" == "Darwin" ]]; then
      echo "   Option A (install build tools): xcode-select --install && brew install cmake" >&2
      echo "   Option B (if Gatekeeper blocked prebuilt binary): System Settings → Privacy & Security → Allow Anyway" >&2
    else
      echo "   Debian/Ubuntu: sudo apt update && sudo apt install -y git cmake build-essential" >&2
      echo "   Fedora/RHEL:   sudo dnf install -y git cmake gcc-c++ make" >&2
    fi
    exit 1
  fi

  mkdir -p "${BASE_DIR}"
  if [[ -d "${LLAMA_CPP_DIR}/.git" ]]; then
    echo "   Updating ${LLAMA_CPP_DIR} ..."
    if ! (cd "${LLAMA_CPP_DIR}" && git pull --ff-only >/dev/null 2>&1); then
      echo "   Fork history rebased — re-cloning..."
      rm -rf "${LLAMA_CPP_DIR}"
      git clone --depth 1 -b prism "${LLAMA_CPP_REPO}" "${LLAMA_CPP_DIR}"
    fi
  else
    echo "   Cloning ${LLAMA_CPP_REPO} (branch: prism)..."
    git clone --depth 1 -b prism "${LLAMA_CPP_REPO}" "${LLAMA_CPP_DIR}"
  fi

  local bdir="${LLAMA_CPP_DIR}/build"
  local cmake_opts=("-DCMAKE_BUILD_TYPE=Release")
  case "${BACKEND}" in
    cuda)
      cmake_opts+=("-DGGML_CUDA=ON")
      if ! command -v nvcc >/dev/null 2>&1 && [[ -x /usr/local/cuda/bin/nvcc ]]; then
        export PATH="/usr/local/cuda/bin:${PATH}"
        cmake_opts+=("-DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc")
      fi
      ;;
    metal)
      cmake_opts+=("-DGGML_METAL=ON" "-DGGML_METAL_EMBED_LIBRARY=ON")
      ;;
    vulkan)
      cmake_opts+=("-DGGML_VULKAN=ON")
      ;;
    rocm)
      cmake_opts+=("-DGGML_HIP=ON")
      ;;
  esac

  local build_log="${BASE_DIR}/build.log"
  mkdir -p "${bdir}"
  echo "   Configuring CMake (log: ${build_log})..."
  if ! (cd "${bdir}" && cmake .. "${cmake_opts[@]}" > "${build_log}" 2>&1); then
    echo "   CMake configure failed — cleaning build directory and retrying..."
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    if ! (cd "${bdir}" && cmake .. "${cmake_opts[@]}" > "${build_log}" 2>&1); then
      echo "❌ CMake configuration failed. Last 30 lines of ${build_log}:" >&2
      tail -n 30 "${build_log}" >&2 || true
      exit 1
    fi
  fi

  local jobs
  jobs="$(get_cpu_count)"
  # Prevent nvcc/cicc OOM freezes during CUDA compilation on low-RAM/VRAM hosts
  if [[ "${BACKEND}" == "cuda" ]]; then
    if [[ "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 16000 ]] || [[ "${TOTAL_VRAM_MB}" -gt 0 && "${TOTAL_VRAM_MB}" -lt 16000 ]]; then
      [[ "${jobs}" -gt 2 ]] && jobs=2
      echo "   Limiting CUDA compile parallelism to -j ${jobs} to prevent memory exhaustion..."
    elif [[ "${jobs}" -gt 16 ]]; then
      jobs=16
    fi
  fi

  echo "   Compiling llama-server with ${jobs} threads..."
  if ! cmake --build "${bdir}" --config Release --target llama-server -j "${jobs}" >> "${build_log}" 2>&1; then
    echo "❌ Source compilation failed. Last 40 lines of ${build_log}:" >&2
    tail -n 40 "${build_log}" >&2 || true
    exit 1
  fi

  if [[ "${OS_NAME}" == "Darwin" ]]; then
    find "${bdir}" -type f \( -name "llama-*" -o -name "ggml-*" -o -name "*.dylib" \) -exec codesign -s - --force --timestamp=none {} \; 2>/dev/null || true
  fi

  SERVER_BIN="$(find_server_bin "${bdir}" || true)"
  if [[ -z "${SERVER_BIN}" || ! -x "${SERVER_BIN}" ]]; then
    echo "❌ Could not find llama-server after source build in ${bdir}" >&2
    exit 1
  fi
  echo "✔  Built llama-server from source: ${SERVER_BIN}"
}

acquire_prebuilt_bin() {
  local target_backend="$1" target_asset="$2"
  local bin_dest="${BIN_ROOT}/${RELEASE_TAG}-${target_backend}${CUDA_TAG:+-$CUDA_TAG}"
  local found=""
  found="$(find_server_bin "${bin_dest}" || true)"
  if [[ -z "${found}" ]]; then
    local asset_url="https://github.com/PrismML-Eng/llama.cpp/releases/download/${RELEASE_TAG}/${target_asset}"
    local archive_path="${BASE_DIR}/downloads/${target_asset}"
    echo "   Fetching prebuilt binary: ${target_asset}" >&2
    if download_url "${asset_url}" "${archive_path}"; then
      rm -rf "${bin_dest}"
      mkdir -p "${bin_dest}"
      echo "   Extracting..." >&2
      if tar -xzf "${archive_path}" -C "${bin_dest}"; then
        rm -f "${archive_path}"
        if [[ "${OS_NAME}" == "Darwin" ]]; then
          echo "   Clearing macOS Gatekeeper quarantine and ad-hoc signing..." >&2
          xattr -cr "${bin_dest}" 2>/dev/null || true
          find "${bin_dest}" -type f \( -name "llama-*" -o -name "ggml-*" -o -name "*.dylib" \) -exec codesign -s - --force --timestamp=none {} \; 2>/dev/null || true
        fi
        found="$(find_server_bin "${bin_dest}" || true)"
      else
        echo "   ⚠  Extraction failed." >&2
        rm -rf "${bin_dest}" "${archive_path}"
      fi
    fi
  else
    echo "✔  Using cached prebuilt binary: ${found}" >&2
  fi
  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi
  return 1
}

echo ""
echo "── Step 1: Setting up PrismML llama.cpp (${RELEASE_TAG}) ──"
SERVER_BIN=""

if [[ "${NEEDS_SOURCE_BUILD}" == "0" && -n "${PREBUILT_ASSET}" ]]; then
  SERVER_BIN="$(acquire_prebuilt_bin "${BACKEND}" "${PREBUILT_ASSET}" || true)"

  if [[ -n "${SERVER_BIN}" ]]; then
    if smoke_test_server_bin "${SERVER_BIN}"; then
      # If Vulkan was auto-selected via ICD detection, verify a usable Vulkan GPU device actually initializes
      if [[ "${BACKEND}" == "vulkan" && "${BACKEND_AUTO}" == "1" ]] && ! has_usable_gpu_device "${SERVER_BIN}"; then
        echo "   ⚠  Vulkan runtime reported 0 usable GPU devices — falling back to CPU backend..."
        BACKEND="cpu"
        EFF_NGL=0
        CUDA_TAG=""
        compute_mtp_settings
        CPU_ASSET="llama-${RELEASE_TAG}-bin-ubuntu-${ARCH_TAG}.tar.gz"
        SERVER_BIN="$(acquire_prebuilt_bin "cpu" "${CPU_ASSET}" || true)"
        if [[ -n "${SERVER_BIN}" ]] && smoke_test_server_bin "${SERVER_BIN}"; then
          echo "✔  CPU fallback smoke test passed"
        else
          SERVER_BIN=""
        fi
      else
        echo "✔  Runtime smoke test passed"
      fi
    else
      if [[ "${OS_NAME}" == "Linux" && "${BACKEND_AUTO}" == "1" && "${BACKEND}" != "cpu" && "${BACKEND}" != "cuda" ]]; then
        echo "   ⚠  ${BACKEND} binary failed smoke test — trying CPU prebuilt before source build..."
        BACKEND="cpu"
        EFF_NGL=0
        CUDA_TAG=""
        compute_mtp_settings
        CPU_ASSET="llama-${RELEASE_TAG}-bin-ubuntu-${ARCH_TAG}.tar.gz"
        SERVER_BIN="$(acquire_prebuilt_bin "cpu" "${CPU_ASSET}" || true)"
        if [[ -n "${SERVER_BIN}" ]] && smoke_test_server_bin "${SERVER_BIN}"; then
          echo "✔  CPU fallback smoke test passed"
        else
          SERVER_BIN=""
        fi
      else
        echo "   ⚠  Prebuilt binary failed smoke test (e.g., glibc/driver/Gatekeeper mismatch) — falling back to source build..."
        SERVER_BIN=""
      fi
    fi
  fi
fi

if [[ -z "${SERVER_BIN}" ]]; then
  build_from_source
fi

SERVER_BIN_DIR="$(cd "$(dirname "${SERVER_BIN}")" && pwd)"

# ─── Step 3: Download Model & Vision Projector ────────────────────────
echo ""
echo "── Step 2: Downloading Ternary Bonsai 2.5 27B weights ──"
mkdir -p "${MODELS_DIR}"

MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"
download_hf_file "${HF_REPO_GGUF}" "${MODEL_FILE}" "${MODEL_PATH}" 104857600

MMPROJ_PATH=""
if [[ -n "${MMPROJ_FILE}" ]]; then
  MMPROJ_PATH="${MODELS_DIR}/${MMPROJ_FILE}"
  download_hf_file "${HF_REPO_GGUF}" "${MMPROJ_FILE}" "${MMPROJ_PATH}" 10485760
fi

# ─── Step 4: Port Selection ───────────────────────────────────────────
FINAL_PORT="$(select_free_port "${PORT}" || true)"
if [[ -z "${FINAL_PORT}" ]]; then
  echo "❌ Ports ${PORT}..$((PORT + 2)) are all busy. Set PORT=<free_port> and re-run." >&2
  exit 1
fi
if [[ "${FINAL_PORT}" != "${PORT}" ]]; then
  echo "   Port ${PORT} busy → using port ${FINAL_PORT}"
fi

# ─── Step 5: Assemble llama-server arguments ──────────────────────────
SERVER_ARGS=(
  -m "${MODEL_PATH}"
  --host "${HOST}"
  --port "${FINAL_PORT}"
  -ngl "${EFF_NGL}"
  -fa on
  -c "${CTX_VALUE}"
  --jinja
)

if [[ "${MODE}" == "instruct" ]]; then
  SERVER_ARGS+=(
    --temp 0.7
    --top-p 0.80
    --top-k 20
    --min-p 0
    --presence-penalty 1.5
    --repeat-penalty 1.0
    --reasoning-budget 0
    --reasoning off
  )
else
  # Official Bonsai 2.5 thinking-mode sampling
  SERVER_ARGS+=(
    --temp 1.0
    --top-p 0.95
    --top-k 20
    --min-p 0
    --presence-penalty 0.0
    --repeat-penalty 1.0
  )
  if [[ "${REASONING_EFFORT}" != "default" ]]; then
    SERVER_ARGS+=(--reasoning-effort "${REASONING_EFFORT}")
  fi
fi

if [[ "${PARALLEL}" != "0" && -n "${PARALLEL}" ]]; then
  SERVER_ARGS+=(-np "${PARALLEL}")
fi

if [[ -n "${MMPROJ_PATH}" ]]; then
  SERVER_ARGS+=(--mmproj "${MMPROJ_PATH}")
  if [[ "${MMPROJ_CPU}" == "1" ]]; then
    SERVER_ARGS+=(--no-mmproj-offload)
  fi
  if [[ "${IMAGE_MAX_TOKENS}" != "0" && -n "${IMAGE_MAX_TOKENS}" ]]; then
    SERVER_ARGS+=(--image-max-tokens "${IMAGE_MAX_TOKENS}")
  fi
else
  # Prevent llama-server from auto-loading any cached mmproj in the same directory when NO_VISION=1
  SERVER_ARGS+=(--no-mmproj)
fi

if [[ "${MTP_ENABLED}" == "1" ]]; then
  SERVER_ARGS+=(
    --spec-type draft-mtp
    --spec-draft-n-min 0
    --spec-draft-n-max "${EFF_MTP_NMAX}"
    --spec-draft-p-min "${EFF_MTP_PMIN}"
  )
fi

if [[ "${KV4}" == "1" ]]; then
  SERVER_ARGS+=(--cache-type-k q4_0 --cache-type-v q4_0)
fi

# ─── Step 6: Start Server ─────────────────────────────────────────────
DISPLAY_HOST="${HOST}"
[[ "${DISPLAY_HOST}" == "0.0.0.0" ]] && DISPLAY_HOST="localhost"

echo ""
echo "── Step 3: Starting llama-server ──"
echo "   Binary:    ${SERVER_BIN}"
echo "   Model:     ${MODEL_PATH}"
[[ -n "${MMPROJ_PATH}" ]] && echo "   Vision:    ${MMPROJ_PATH}"
echo "   Web UI:    http://localhost:${FINAL_PORT}"
echo "   API:       http://${DISPLAY_HOST}:${FINAL_PORT}/v1/chat/completions"
echo "   Context:   ${CTX_VALUE} tokens"
echo "   Parallel:  ${PARALLEL} (1 = single-slot low VRAM, 0 = auto)"
echo "   GPU layers:${EFF_NGL} (backend: ${BACKEND})"
[[ "${MTP_ENABLED}" == "1" ]] && echo "   MTP:       enabled (n-max=${EFF_MTP_NMAX}, p-min=${EFF_MTP_PMIN})"
[[ "${KV4}" == "1" ]] && echo "   KV Cache:  Q4_0 (4-bit)"
[[ "${MMPROJ_CPU}" == "1" && -n "${MMPROJ_PATH}" ]] && echo "   Vision RAM: projector kept in system RAM (--no-mmproj-offload)"
echo ""
echo "   Test it:   PORT=${FINAL_PORT} bash test-model.sh"
echo "   Stop it:   Press Ctrl+C or run: bash stop.sh"
echo ""

mkdir -p "$(dirname "${PID_FILE}")"

if [[ "${OS_NAME}" == "Darwin" ]]; then
  export DYLD_LIBRARY_PATH="${SERVER_BIN_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
else
  LDP_PREFIX="${SERVER_BIN_DIR}"
  [[ "${IS_WSL}" == "1" && -d /usr/lib/wsl/lib ]] && LDP_PREFIX="${LDP_PREFIX}:/usr/lib/wsl/lib"
  export LD_LIBRARY_PATH="${LDP_PREFIX}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

open_browser_when_ready() {
  local pid="$1" port_num="$2"
  local ui_url="http://localhost:${port_num}"
  local i=0 code=""
  while [[ $i -lt 90 ]]; do
    kill -0 "${pid}" 2>/dev/null || return 0
    if command -v curl >/dev/null 2>&1; then
      code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:${port_num}/health" 2>/dev/null || echo 000)"
      if [[ "${code}" == "200" ]]; then
        if [[ "${OS_NAME}" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
          open "${ui_url}" >/dev/null 2>&1 || true
        elif [[ "${IS_WSL}" == "1" ]] && command -v wslview >/dev/null 2>&1; then
          wslview "${ui_url}" >/dev/null 2>&1 || true
        elif [[ "${IS_WSL}" == "1" && -x /mnt/c/Windows/System32/cmd.exe ]]; then
          /mnt/c/Windows/System32/cmd.exe /c start "" "${ui_url}" >/dev/null 2>&1 || true
        elif [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
          xdg-open "${ui_url}" >/dev/null 2>&1 || true
        fi
        return 0
      fi
    fi
    sleep 1
    i=$((i + 1))
  done
}

if [[ "${DETACHED}" == "1" ]]; then
  LOG_FILE="${BASE_DIR}/llama-server.log"
  nohup "${SERVER_BIN}" "${SERVER_ARGS[@]}" > "${LOG_FILE}" 2>&1 &
  SERVER_PID=$!
  echo "${SERVER_PID}" > "${PID_FILE}"
  echo "   PID:  ${SERVER_PID} (saved to ${PID_FILE})"
  echo "   Logs: ${LOG_FILE}"
  if [[ "${NO_BROWSER}" != "1" && -z "${SSH_CONNECTION:-}" ]]; then
    open_browser_when_ready "${SERVER_PID}" "${FINAL_PORT}" &
  fi
  exit 0
fi

SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
}
trap cleanup INT TERM

"${SERVER_BIN}" "${SERVER_ARGS[@]}" &
SERVER_PID=$!
echo "${SERVER_PID}" > "${PID_FILE}"
echo "   PID: ${SERVER_PID} (saved to ${PID_FILE})"

if [[ "${NO_BROWSER}" != "1" && -z "${SSH_CONNECTION:-}" ]]; then
  open_browser_when_ready "${SERVER_PID}" "${FINAL_PORT}" &
fi

wait "${SERVER_PID}"
EXIT_CODE=$?
rm -f "${PID_FILE}"
exit "${EXIT_CODE}"
