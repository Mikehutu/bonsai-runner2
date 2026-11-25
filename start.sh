#!/usr/bin/env bash
# start.sh — Ternary Bonsai 2.5 27B one-click runner (Linux, macOS, WSL2)
#
# Usage:
#   bash start.sh                  # auto-detect hardware & pick best variant
#   bash start.sh ptq1-mtp         # 6.2 GB PTQ1_0 + MTP head (best for NVIDIA CUDA)
#   bash start.sh pq2-mtp          # 7.5 GB PQ2_0 + MTP head (best for Apple Metal / CPU / Vulkan)
#   bash start.sh q2-mtp           # 7.9 GB Q2_0 + MTP head (stock llama.cpp b11556+ compatible)
#   bash start.sh ptq1             # 6.0 GB PTQ1_0 (no MTP head)
#   bash start.sh pq2              # 7.3 GB PQ2_0 (no MTP head)
#   bash start.sh q2               # 7.7 GB Q2_0 (no MTP head)
#   bash start.sh mlx              # Apple Silicon MLX pack (macOS arm64 only)
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
        # Trim whitespace around key
        key="$(printf '%s' "${key}" | tr -d '[:space:]')"
        # Only valid shell identifiers
        case "${key}" in
          ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;;
        esac
        # Strip optional surrounding single or double quotes
        case "${val}" in
          \"*\") val="${val#\"}"; val="${val%\"}" ;;
          \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        # Set only if not already set in environment
        if [[ -z "${!key+x}" ]]; then
          export "${key}=${val}"
        fi
        ;;
    esac
  done < "${env_file}"
}

load_dotenv "${SCRIPT_DIR}/.env"

# ─── Configuration ────────────────────────────────────────────────────
CHOOSE_MODE=0
RAW_VARIANT=""
for arg in "$@"; do
  case "${arg}" in
    --choose|-i|--interactive) CHOOSE_MODE=1 ;;
    -h|--help|help) RAW_VARIANT="--help" ;;
    *)
      if [[ -z "${RAW_VARIANT}" ]]; then
        RAW_VARIANT="${arg}"
      fi
      ;;
  esac
done
MODEL_VARIANT="${RAW_VARIANT:-${MODEL_VARIANT:-auto}}"

# Track whether user explicitly set memory-tuning overrides
USER_SET_MMPROJ_CPU=0
USER_SET_KV4=0
[[ -n "${MMPROJ_CPU+x}" ]] && USER_SET_MMPROJ_CPU=1
[[ -n "${KV4+x}" ]] && USER_SET_KV4=1

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
CONTEXT_SIZE="${CONTEXT_SIZE:-0}"     # 0 = safe 32K default (max 262144)
MODE="${MODE:-thinking}"              # thinking | instruct
MTP="${MTP:-auto}"                    # auto | on | off
MTP_NMAX="${MTP_NMAX:-}"
MTP_PMIN="${MTP_PMIN:-}"
NO_VISION="${NO_VISION:-0}"           # 1 = skip vision mmproj
MMPROJ_QUANT="${MMPROJ_QUANT:-Q8_0}"  # Q8_0 (0.63 GB) | BF16 (0.93 GB)
MMPROJ_CPU="${MMPROJ_CPU:-0}"         # 1 = keep vision projector in RAM (--no-mmproj-offload)
IMAGE_MAX_TOKENS="${IMAGE_MAX_TOKENS:-1024}"  # 0 = uncapped
KV4="${KV4:-0}"                       # 1 = 4-bit KV cache (--cache-type-k q4_0 --cache-type-v q4_0)
BACKEND_OVERRIDE="${BACKEND:-${BONSAI_BACKEND:-}}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
DRY_RUN="${BONSAI_DRY_RUN:-0}"

# ─── Help ─────────────────────────────────────────────────────────────
show_help() {
  cat <<'EOF'
Usage: bash start.sh [VARIANT]

Run Ternary Bonsai 2.5 27B locally with one command (Linux, macOS, WSL2).
Downloads prebuilt PrismML llama.cpp binaries (with automatic source-build
fallback) + GGUF weights from HuggingFace and starts an OpenAI-compatible
server with built-in Web UI.

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
  mlx        Apple Silicon MLX 2-bit pack (~8.6 GB, macOS arm64 only)

Environment variables (or set in .env):
  PORT=8080               Server port (auto-falls back to PORT+1, PORT+2 if busy)
  HOST=0.0.0.0            Bind address
  NGL=99                  GPU layers to offload (auto-set to 0 on CPU)
  CONTEXT_SIZE=0          Context tokens (0 = safe 32768 default; max 262144)
  PARALLEL=1              Concurrent slots (1 = low VRAM default; 0 = llama-server auto)
  MODE=thinking           thinking (default) | instruct (non-thinking)
  MTP=auto                Speculative decoding: auto (on for CUDA/ROCm/Metal) | on | off
  MTP_NMAX=               Override draft tokens per step (default: 3 CUDA/ROCm, 1 Metal)
  MTP_PMIN=               Override draft min probability (default: 0.1 CUDA/ROCm, 0.6 Metal)
  NO_VISION=0             Set 1 to skip multimodal vision projector (mmproj)
  MMPROJ_QUANT=Q8_0       Vision projector quant: Q8_0 (0.63 GB) or BF16 (0.93 GB)
  MMPROJ_CPU=0            Set 1 to keep vision projector in RAM (--no-mmproj-offload)
  IMAGE_MAX_TOKENS=1024   Max vision tokens per image (0 = uncapped for OCR)
  KV4=0                   Set 1 to enable 4-bit KV cache (q4_0) for long contexts
  BACKEND=                Force backend: cuda | rocm | vulkan | metal | cpu
  BUILD_FROM_SOURCE=0     Set 1 to compile PrismML llama.cpp from source
  PRISM_RELEASE=          Pin PrismML llama.cpp tag (default: prism-b12178-03ec600, or 'latest')
  HF_TOKEN=               Optional HuggingFace token
  HF_HUB_OFFLINE=0        Set 1 for airgapped machines with pre-cached models

Examples:
  bash start.sh                  # auto-detect hardware, pick optimal variant & start immediately
  bash start.sh --choose         # interactive menu to pick variant & context size
  bash start.sh ptq1-mtp         # explicit variant (skip auto-pick)
  CONTEXT_SIZE=131072 KV4=1 bash start.sh pq2-mtp
  MODE=instruct PORT=9090 bash start.sh ptq1-mtp
  bash test-model.sh             # verify chat + tool calling + measure tok/s
  bash stop.sh                   # stop the running server
EOF
}

case "${MODEL_VARIANT}" in
  -h|--help|help)
    show_help
    exit 0
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

# ─── Variant metadata resolver (no declare -A for Bash 3.2) ───────────
# Sets: VARIANT_KEY, MODEL_FILE, MODEL_SIZE_MB, MODEL_SIZE_HINT, HAS_MTP, IS_MLX
resolve_variant() {
  local v
  v="$(to_lower "$1")"
  IS_MLX=0
  HAS_MTP=0
  case "${v}" in
    auto|default|bonsai25|bonsai2.5)
      VARIANT_KEY="auto"
      MODEL_FILE=""
      MODEL_SIZE_MB=6230
      MODEL_SIZE_HINT="~6.2–7.5 GB"
      HAS_MTP=1
      ;;
    ptq1-mtp|ptq1_0-mtp)
      VARIANT_KEY="ptq1-mtp"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf"
      MODEL_SIZE_MB=6230
      MODEL_SIZE_HINT="6.23 GB"
      HAS_MTP=1
      ;;
    pq2-mtp|pq2_0-mtp)
      VARIANT_KEY="pq2-mtp"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf"
      MODEL_SIZE_MB=7490
      MODEL_SIZE_HINT="7.49 GB"
      HAS_MTP=1
      ;;
    q2-mtp|q2_0-mtp)
      VARIANT_KEY="q2-mtp"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf"
      MODEL_SIZE_MB=7910
      MODEL_SIZE_HINT="7.91 GB"
      HAS_MTP=1
      ;;
    ptq1|ptq1_0)
      VARIANT_KEY="ptq1"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PTQ1_0.gguf"
      MODEL_SIZE_MB=5990
      MODEL_SIZE_HINT="5.99 GB"
      HAS_MTP=0
      ;;
    pq2|pq2_0)
      VARIANT_KEY="pq2"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-PQ2_0.gguf"
      MODEL_SIZE_MB=7250
      MODEL_SIZE_HINT="7.25 GB"
      HAS_MTP=0
      ;;
    q2|q2_0)
      VARIANT_KEY="q2"
      MODEL_FILE="Ternary-Bonsai-2.5-27B-Q2_0.gguf"
      MODEL_SIZE_MB=7670
      MODEL_SIZE_HINT="7.67 GB"
      HAS_MTP=0
      ;;
    mlx)
      VARIANT_KEY="mlx"
      MODEL_FILE="model.safetensors"
      MODEL_SIZE_MB=8600
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

# Validate initial variant early
resolve_variant "${MODEL_VARIANT}"

# Validate MODE and MTP
MODE="$(to_lower "${MODE}")"
case "${MODE}" in
  thinking|instruct) ;;
  *)
    echo "❌ Unknown MODE '${MODE}' (valid: thinking, instruct)" >&2
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
OS_NAME="${BONSAI_TEST_OS:-$(uname -s)}"
ARCH_RAW="${BONSAI_TEST_ARCH:-$(uname -m)}"
case "${ARCH_RAW}" in
  x86_64|amd64) ARCH_TAG="x64" ;;
  arm64|aarch64) ARCH_TAG="arm64" ;;
  *)
    echo "❌ Unsupported CPU architecture: ${ARCH_RAW} (supported: x86_64, arm64/aarch64)" >&2
    exit 1
    ;;
esac

case "${OS_NAME}" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "ℹ  Detected Windows shell (${OS_NAME}). For native Windows, run:" >&2
    echo "   powershell -ExecutionPolicy Bypass -File start.ps1" >&2
    exit 1
    ;;
  *)
    echo "❌ Unsupported OS: ${OS_NAME}" >&2
    exit 1
    ;;
esac

BACKEND=""
CUDA_VER=""
CUDA_TAG=""
TOTAL_VRAM_MB=0
TOTAL_RAM_MB="$(get_ram_mb)"

detect_cuda_version() {
  if [[ -n "${BONSAI_TEST_CUDA_VER:-}" ]]; then
    CUDA_VER="${BONSAI_TEST_CUDA_VER}"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    CUDA_VER="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA[ A-Z]*Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
  fi
  if [[ -z "${CUDA_VER}" ]] && command -v nvcc >/dev/null 2>&1; then
    CUDA_VER="$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
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
    *)
      echo "❌ Unknown BACKEND '${BACKEND_OVERRIDE}' (valid: cuda, rocm, vulkan, metal, cpu)" >&2
      exit 1
      ;;
  esac
  if [[ "${BACKEND}" == "cuda" ]]; then
    detect_cuda_version
  fi
elif [[ "${OS_NAME}" == "Darwin" ]]; then
  if [[ "${ARCH_TAG}" == "arm64" ]]; then
    BACKEND="metal"
  else
    BACKEND="cpu"
  fi
else
  # Linux hardware detection
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 | grep -q . 2>/dev/null; then
    BACKEND="cuda"
    detect_cuda_version
    local_vram="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' ' || echo 0)"
    if [[ "${local_vram}" =~ ^[0-9]+$ ]]; then
      TOTAL_VRAM_MB="${local_vram}"
    fi
  elif [[ "${ARCH_TAG}" == "x64" ]] && { command -v rocminfo >/dev/null 2>&1 || command -v rocm-smi >/dev/null 2>&1; }; then
    if rocm-smi --showproductname 2>/dev/null | grep -qiE "AMD|Radeon|Instinct|GPU" || rocminfo 2>/dev/null | grep -q "Device Type:.*GPU"; then
      BACKEND="rocm"
    fi
  fi
  if [[ -z "${BACKEND}" ]] && command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary 2>/dev/null | grep -E "deviceType" | grep -qv "CPU"; then
      BACKEND="vulkan"
    fi
  fi
  if [[ -z "${BACKEND}" ]]; then
    BACKEND="cpu"
  fi
fi

# Determine recommended variant and hardware-aware tuning reason
RECOMMENDED_VARIANT=""
AUTO_REASON=""
if [[ "${BACKEND}" == "cuda" ]]; then
  RECOMMENDED_VARIANT="ptq1-mtp"
  if [[ "${TOTAL_VRAM_MB}" -gt 0 && "${TOTAL_VRAM_MB}" -le 9000 ]]; then
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
  else
    RECOMMENDED_VARIANT="pq2-mtp"
    AUTO_REASON="Apple Silicon Metal (${TOTAL_RAM_MB} MB RAM): PQ2_0-mtp is PrismML's benchmarked Metal packing"
  fi
else
  if [[ "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 12000 ]]; then
    RECOMMENDED_VARIANT="ptq1-mtp"
    AUTO_REASON="${BACKEND} tight RAM (${TOTAL_RAM_MB} MB): smallest PTQ1_0-mtp + 8K ctx + KV4"
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
    echo "   mlx       ~8.6 GB — Apple Silicon MLX 2-bit pack"
  fi
  echo ""
  echo "   Auto-recommended: ${RECOMMENDED_VARIANT} (${AUTO_REASON})"
  echo ""
  read -r -p "Choose variant [ptq1-mtp/pq2-mtp/q2-mtp/ptq1/pq2/q2] (default: ${RECOMMENDED_VARIANT}): " CHOSEN
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

# ─── MLX path (Apple Silicon macOS only) ──────────────────────────────
if [[ "${IS_MLX}" == "1" ]]; then
  if [[ "${OS_NAME}" != "Darwin" || "${ARCH_TAG}" != "arm64" ]]; then
    echo "❌ The 'mlx' variant requires an Apple Silicon Mac (macOS arm64)." >&2
    echo "   On ${OS_NAME} (${ARCH_TAG}), use: bash start.sh ${RECOMMENDED_VARIANT}" >&2
    exit 1
  fi
  echo "══════════════════════════════════════════════════════════"
  echo "  Ternary Bonsai 2.5 27B — Apple Silicon MLX"
  echo "  HF repo: ${HF_REPO_MLX}"
  echo "══════════════════════════════════════════════════════════"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY_RUN: OS=${OS_NAME} ARCH=${ARCH_TAG} BACKEND=mlx VARIANT=mlx HF_REPO=${HF_REPO_MLX}"
    exit 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 is required for the MLX variant. Install Xcode CLI or Homebrew Python." >&2
    exit 1
  fi
  MLX_DIR="${MODELS_DIR}/mlx"
  MLX_VENV="${BASE_DIR}/venv-mlx"
  mkdir -p "${MLX_DIR}"
  if [[ ! -d "${MLX_VENV}" ]]; then
    echo "── Creating MLX Python venv at ${MLX_VENV} ──"
    python3 -m venv "${MLX_VENV}"
  fi
  "${MLX_VENV}/bin/pip" install -q --upgrade pip huggingface_hub
  if [[ ! -f "${MLX_DIR}/model.safetensors" ]]; then
    echo "── Downloading ${HF_REPO_MLX} (~8.6 GB) ──"
    ( unset HF_HUB_OFFLINE; export HF_HUB_DISABLE_XET=1; "${MLX_VENV}/bin/hf" download "${HF_REPO_MLX}" --local-dir "${MLX_DIR}" )
  else
    echo "✔  MLX model pack already downloaded at ${MLX_DIR}"
  fi
  if [[ -f "${MLX_DIR}/runtime/requirements.txt" ]]; then
    echo "── Installing MLX runtime requirements ──"
    "${MLX_VENV}/bin/pip" install -q -r "${MLX_DIR}/runtime/requirements.txt"
  fi
  echo ""
  echo "✔  MLX pack ready at ${MLX_DIR}"
  echo "   Running quickstart check (note: for OpenAI API + Web UI + faster decode on Mac, use: bash start.sh pq2-mtp)"
  shift 1 || true
  PROMPT_ARG="${1:-What is 2 plus 2?}"
  (cd "${MLX_DIR}" && PYTHONPATH=runtime "${MLX_VENV}/bin/python" quickstart.py "${PROMPT_ARG}")
  exit 0
fi

# ─── Determine prebuilt release asset vs source build ─────────────────
resolve_release_tag() {
  if [[ "${PRISM_RELEASE}" != "latest" ]]; then
    echo "${PRISM_RELEASE}"
    return
  fi
  local tag=""
  if command -v curl >/dev/null 2>&1; then
    tag="$(curl -sL -H "User-Agent: bonsai-runner2" "https://api.github.com/repos/PrismML-Eng/llama.cpp/releases/latest" \
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
if [[ "${BACKEND}" == "cuda" && "${TOTAL_VRAM_MB}" -gt 0 && "${TOTAL_VRAM_MB}" -le 9000 ]]; then
  # 8 GB VRAM GPU: fit PTQ1_0 + KV4 + 16K context comfortably by keeping mmproj in system RAM
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=16384
  [[ "${USER_SET_MMPROJ_CPU}" == "0" ]] && MMPROJ_CPU=1
  [[ "${USER_SET_KV4}" == "0" ]] && KV4=1
elif [[ "${BACKEND}" == "metal" && "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 14000 ]]; then
  # 8 GB Apple Silicon Mac: conservative 8K context + KV4 + CPU mmproj
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=8192
  [[ "${USER_SET_MMPROJ_CPU}" == "0" ]] && MMPROJ_CPU=1
  [[ "${USER_SET_KV4}" == "0" ]] && KV4=1
elif [[ "${BACKEND}" != "cuda" && "${BACKEND}" != "rocm" && "${TOTAL_RAM_MB}" -gt 0 && "${TOTAL_RAM_MB}" -lt 12000 ]]; then
  # Tight-RAM CPU/Vulkan host
  [[ "${CTX_VALUE}" == "0" ]] && CTX_VALUE=8192
  [[ "${USER_SET_KV4}" == "0" ]] && KV4=1
fi
if [[ "${CTX_VALUE}" == "0" ]]; then
  CTX_VALUE=32768
fi

EFF_NGL="${NGL}"
if [[ "${BACKEND}" == "cpu" ]]; then
  EFF_NGL=0
fi

MTP_ENABLED=0
EFF_MTP_NMAX=""
EFF_MTP_PMIN=""
if [[ "${HAS_MTP}" == "1" && "${MTP}" != "off" ]]; then
  if [[ "${MTP}" == "on" ]]; then
    MTP_ENABLED=1
  else
    # auto: enable where PrismML measured a decode speedup
    case "${BACKEND}" in
      cuda|rocm|metal) MTP_ENABLED=1 ;;
      *) MTP_ENABLED=0 ;;
    esac
  fi
fi

if [[ "${MTP_ENABLED}" == "1" ]]; then
  if [[ "${BACKEND}" == "metal" ]]; then
    EFF_MTP_NMAX="${MTP_NMAX:-1}"
    EFF_MTP_PMIN="${MTP_PMIN:-0.6}"
  else
    EFF_MTP_NMAX="${MTP_NMAX:-3}"
    EFF_MTP_PMIN="${MTP_PMIN:-0.1}"
  fi
fi

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
echo "══════════════════════════════════════════════════════════"

# ─── Download helper (zero-dependency curl/wget, atomic .part) ────────
download_url() {
  local url="$1" dest="$2"
  local tmp="${dest}.part"
  mkdir -p "$(dirname "${dest}")"

  local auth_header=""
  if [[ -n "${HF_TOKEN:-}" && "${url}" == *"huggingface.co"* ]]; then
    auth_header="Authorization: Bearer ${HF_TOKEN}"
  fi

  if command -v curl >/dev/null 2>&1; then
    if [[ -n "${auth_header}" ]]; then
      curl -L --fail --retry 3 --retry-delay 2 -C - --progress-bar -H "${auth_header}" -o "${tmp}" "${url}"
    else
      curl -L --fail --retry 3 --retry-delay 2 -C - --progress-bar -o "${tmp}" "${url}"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [[ -n "${auth_header}" ]]; then
      wget --tries=3 -c --show-progress --header="${auth_header}" -O "${tmp}" "${url}"
    else
      wget --tries=3 -c --show-progress -O "${tmp}" "${url}"
    fi
  else
    echo "❌ Neither curl nor wget found. Install curl and re-run." >&2
    return 1
  fi
  mv -f "${tmp}" "${dest}"
}

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

  # Check common local cache paths before hitting the network
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

smoke_test_server_bin() {
  local bin="$1"
  local bdir
  bdir="$(dirname "${bin}")"
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    DYLD_LIBRARY_PATH="${bdir}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}" "${bin}" --version >/dev/null 2>&1
  else
    LD_LIBRARY_PATH="${bdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "${bin}" --version >/dev/null 2>&1
  fi
}

build_from_source() {
  echo ""
  echo "── Building PrismML llama.cpp from source (${BACKEND}) ──"
  local missing=0
  for tool in git cmake make; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "⚠  ${tool} not found." >&2
      missing=1
    fi
  done
  if [[ "${missing}" == "1" ]]; then
    echo "❌ Source build requires git, cmake, make, and a C++ compiler." >&2
    echo "   Debian/Ubuntu: sudo apt install git cmake build-essential" >&2
    echo "   macOS:         xcode-select --install && brew install cmake" >&2
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
  local cmake_opts=()
  cmake_opts+=("-DCMAKE_BUILD_TYPE=Release")
  case "${BACKEND}" in
    cuda)   cmake_opts+=("-DGGML_CUDA=ON") ;;
    metal)  cmake_opts+=("-DGGML_METAL=ON") ;;
    vulkan) cmake_opts+=("-DGGML_VULKAN=ON") ;;
    rocm)   cmake_opts+=("-DGGML_HIP=ON") ;;
  esac

  mkdir -p "${bdir}"
  echo "   Configuring CMake..."
  if ! (cd "${bdir}" && cmake .. "${cmake_opts[@]}" 2>&1 | tail -n 5); then
    echo "   CMake configure failed — cleaning build directory and retrying..."
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    (cd "${bdir}" && cmake .. "${cmake_opts[@]}" 2>&1 | tail -n 5)
  fi

  local jobs
  jobs="$(get_cpu_count)"
  echo "   Compiling with ${jobs} threads..."
  cmake --build "${bdir}" --config Release --target llama-server -j "${jobs}" 2>&1 | tail -n 8

  SERVER_BIN="$(find_server_bin "${bdir}" || true)"
  if [[ -z "${SERVER_BIN}" || ! -x "${SERVER_BIN}" ]]; then
    echo "❌ Could not find llama-server after source build in ${bdir}" >&2
    exit 1
  fi
  echo "✔  Built llama-server from source: ${SERVER_BIN}"
}

echo ""
echo "── Step 1: Setting up PrismML llama.cpp (${RELEASE_TAG}) ──"
SERVER_BIN=""

if [[ "${NEEDS_SOURCE_BUILD}" == "0" && -n "${PREBUILT_ASSET}" ]]; then
  BIN_DEST="${BIN_ROOT}/${RELEASE_TAG}-${BACKEND}${CUDA_TAG:+-$CUDA_TAG}"
  SERVER_BIN="$(find_server_bin "${BIN_DEST}" || true)"

  if [[ -z "${SERVER_BIN}" ]]; then
    ASSET_URL="https://github.com/PrismML-Eng/llama.cpp/releases/download/${RELEASE_TAG}/${PREBUILT_ASSET}"
    ARCHIVE_PATH="${BASE_DIR}/downloads/${PREBUILT_ASSET}"
    echo "   Fetching prebuilt binary: ${PREBUILT_ASSET}"
    if download_url "${ASSET_URL}" "${ARCHIVE_PATH}"; then
      rm -rf "${BIN_DEST}"
      mkdir -p "${BIN_DEST}"
      echo "   Extracting..."
      if tar -xzf "${ARCHIVE_PATH}" -C "${BIN_DEST}"; then
        rm -f "${ARCHIVE_PATH}"
        if [[ "${OS_NAME}" == "Darwin" ]]; then
          echo "   Clearing macOS Gatekeeper quarantine and ad-hoc signing..."
          xattr -cr "${BIN_DEST}" 2>/dev/null || true
          find "${BIN_DEST}" -type f \( -name "llama-*" -o -name "*.dylib" \) -exec codesign -s - --force --timestamp=none {} \; 2>/dev/null || true
        fi
        SERVER_BIN="$(find_server_bin "${BIN_DEST}" || true)"
      else
        echo "   ⚠  Extraction failed — will fall back to source build."
        rm -rf "${BIN_DEST}" "${ARCHIVE_PATH}"
      fi
    else
      echo "   ⚠  Prebuilt download failed — will fall back to source build."
    fi
  else
    echo "✔  Using cached prebuilt binary: ${SERVER_BIN}"
  fi

  if [[ -n "${SERVER_BIN}" ]]; then
    if smoke_test_server_bin "${SERVER_BIN}"; then
      echo "✔  Runtime smoke test passed"
    else
      echo "   ⚠  Prebuilt binary failed smoke test (e.g., glibc/driver mismatch) — falling back to source build..."
      SERVER_BIN=""
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
FINAL_PORT="${PORT}"
PORT_FOUND=0
for try_port in "${PORT}" $((PORT + 1)) $((PORT + 2)); do
  if is_port_free "${try_port}"; then
    FINAL_PORT="${try_port}"
    PORT_FOUND=1
    break
  fi
done
if [[ "${PORT_FOUND}" == "0" ]]; then
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
echo ""
echo "── Step 3: Starting llama-server ──"
echo "   Binary:    ${SERVER_BIN}"
echo "   Model:     ${MODEL_PATH}"
[[ -n "${MMPROJ_PATH}" ]] && echo "   Vision:    ${MMPROJ_PATH}"
echo "   Web UI:    http://localhost:${FINAL_PORT}"
echo "   API:       http://${HOST}:${FINAL_PORT}/v1/chat/completions"
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
  export LD_LIBRARY_PATH="${SERVER_BIN_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
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

wait "${SERVER_PID}"
EXIT_CODE=$?
rm -f "${PID_FILE}"
exit "${EXIT_CODE}"
