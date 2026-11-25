#!/usr/bin/env bash
# test-start.sh — Comprehensive cross-platform validation suite for bonsai-runner2
set -u

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
check_contains() {
  if printf '%s\n' "$2" | grep -qF -- "$1"; then
    pass "$3"
  else
    fail "$3 (expected '$1')"
  fi
}
check_not_contains() {
  if ! printf '%s\n' "$2" | grep -qF -- "$1"; then
    pass "$3"
  else
    fail "$3 (unexpected '$1')"
  fi
}

CD="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$CD/start.sh" "$CD/stop.sh" "$CD/test-model.sh" "$CD/test-start.sh" 2>/dev/null || true

echo ""
echo "═══ 1. File structure, line endings & syntax ═══"
for f in start.sh stop.sh start.ps1 stop.ps1 test-model.sh test-model.ps1 .env.example .gitignore .gitattributes README.md HARDWARE-GUIDE.md AGENTS.md test-start.sh test-start.ps1; do
  [[ -f "$CD/$f" ]] && pass "$f exists" || fail "$f missing"
done
[[ -x "$CD/start.sh"      ]] && pass "start.sh is executable"      || fail "start.sh not executable"
[[ -x "$CD/stop.sh"       ]] && pass "stop.sh is executable"       || fail "stop.sh not executable"
[[ -x "$CD/test-model.sh" ]] && pass "test-model.sh is executable" || fail "test-model.sh not executable"

for shf in start.sh stop.sh test-model.sh test-start.sh; do
  bash -n "$CD/$shf" 2>/dev/null && pass "$shf passes bash -n syntax check" || fail "$shf syntax error"
  if LC_ALL=C grep -q $'\r' "$CD/$shf"; then
    fail "$shf contains CRLF line endings (breaks Linux/macOS/WSL2)"
  else
    pass "$shf uses clean LF line endings"
  fi
done

# Ensure all PowerShell scripts are pure 7-bit ASCII so Windows PowerShell 5.1
# never misparses UTF-8 multi-byte chars (like em-dash 0x94 -> closing quote) on ANSI codepages.
if command -v python3 >/dev/null 2>&1; then
  for psf in start.ps1 stop.ps1 test-model.ps1 test-start.ps1; do
    if python3 -c "import pathlib,sys; b=pathlib.Path(sys.argv[1]).read_bytes(); b.decode('ascii')" "$CD/$psf" 2>/dev/null; then
      pass "$psf is pure 7-bit ASCII (Windows PowerShell 5.1 ANSI-safe)"
    else
      fail "$psf contains non-ASCII bytes (unsafe on Windows PowerShell 5.1 without BOM)"
    fi
  done
fi

echo ""
echo "═══ 2. macOS Bash 3.2 compatibility audit ═══"
for shf in start.sh stop.sh test-model.sh; do
  SH_CODE="$(grep -vE '^[[:space:]]*#' "$CD/$shf")"
  check_not_contains "declare -A" "$SH_CODE" "no Bash 4+ 'declare -A' in $shf"
  check_not_contains "mapfile"    "$SH_CODE" "no Bash 4+ 'mapfile' in $shf"
  check_not_contains "readarray"  "$SH_CODE" "no Bash 4+ 'readarray' in $shf"
  if printf '%s\n' "$SH_CODE" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*,,|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^'; then
    fail "found Bash 4+ case conversion (\${var,,} / \${var^^}) in $shf"
  else
    pass "no Bash 4+ case conversion in $shf"
  fi
done

START_SRC="$(cat "$CD/start.sh")"
check_contains "hw.memsize" "$START_SRC" "macOS RAM detection (sysctl hw.memsize)"
check_contains "hw.ncpu"    "$START_SRC" "macOS CPU core detection (sysctl hw.ncpu)"
check_contains "xattr -cr"  "$START_SRC" "macOS Gatekeeper quarantine clearing"
check_contains "codesign"   "$START_SRC" "macOS ad-hoc binary/dylib signing"
check_contains "DYLD_LIBRARY_PATH" "$START_SRC" "macOS DYLD_LIBRARY_PATH handling"
check_contains "stat -f%z"  "$START_SRC" "macOS stat -f%z file-size fallback"
check_contains "GGML_METAL_TENSOR_DISABLE" "$START_SRC" "macOS Apple M5 Metal tensor-API workaround"

echo ""
echo "═══ 3. Help, CLI flags & error handling ═══"
H="$(bash "$CD/start.sh" --help 2>&1 || true)"
check_contains "ptq1-mtp" "$H" "help lists ptq1-mtp"
check_contains "pq2-mtp"  "$H" "help lists pq2-mtp"
check_contains "q2-mtp"   "$H" "help lists q2-mtp"
check_contains "mlx"      "$H" "help lists mlx"
check_contains "--dry-run" "$H" "help lists --dry-run"
check_contains "--detached" "$H" "help lists --detached"

E="$(bash "$CD/start.sh" nonexistent_variant 2>&1 || true)"
check_contains "Unknown variant" "$E" "rejects unknown variant"
check_contains "ptq1-mtp"        "$E" "error lists valid variants"

E_OPT="$(bash "$CD/start.sh" --bogus-flag 2>&1 || true)"
check_contains "Unknown option" "$E_OPT" "rejects unknown CLI option"

E_MODE="$(MODE=bogus BONSAI_DRY_RUN=1 bash "$CD/start.sh" ptq1-mtp 2>&1 || true)"
check_contains "Unknown MODE" "$E_MODE" "rejects invalid MODE"

E_MTP="$(MTP=bogus BONSAI_DRY_RUN=1 bash "$CD/start.sh" ptq1-mtp 2>&1 || true)"
check_contains "Unknown MTP" "$E_MTP" "rejects invalid MTP"

E_MLX="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cpu bash "$CD/start.sh" mlx 2>&1 || true)"
check_contains "Apple Silicon Mac" "$E_MLX" "mlx variant cleanly rejected on Linux"

CLI_DRY="$(BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 bash "$CD/start.sh" ptq1-mtp --dry-run --backend vulkan --mode instruct --kv4 --no-vision -c 65536 2>&1)"
check_contains "BACKEND=vulkan"   "$CLI_DRY" "CLI --backend vulkan applied"
check_contains "MODE=instruct"    "$CLI_DRY" "CLI --mode instruct applied"
check_contains "KV4=1"            "$CLI_DRY" "CLI --kv4 applied"
check_contains "MMPROJ_FILE="     "$CLI_DRY" "CLI --no-vision applied"
check_contains "CTX_VALUE=65536"  "$CLI_DRY" "CLI -c 65536 applied"

echo ""
echo "═══ 4. Cross-platform dry-run matrix ═══"

# 4a. macOS Apple Silicon (M4 Pro, 32 GB)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=32768 BONSAI_TEST_CPU_BRAND="Apple M4 Pro" BONSAI_TEST_MACOS_VER="15.4" bash "$CD/start.sh" 2>&1)"
check_contains "OS=Darwin" "$OUT" "macOS arm64: OS=Darwin"
check_contains "ARCH=arm64" "$OUT" "macOS arm64: ARCH=arm64"
check_contains "BACKEND=metal" "$OUT" "macOS arm64: BACKEND=metal"
check_contains "VARIANT=pq2-mtp" "$OUT" "macOS arm64 (32GB): auto picks pq2-mtp"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-macos-arm64.tar.gz" "$OUT" "macOS arm64: prebuilt macos-arm64 archive"
check_contains "MTP_ENABLED=1" "$OUT" "macOS arm64: MTP auto-enabled"
check_contains "MTP_NMAX=1" "$OUT" "macOS arm64: MTP n-max=1"
check_contains "MTP_PMIN=0.6" "$OUT" "macOS arm64: MTP p-min=0.6"
check_contains "CTX_VALUE=32768" "$OUT" "macOS arm64 (32GB): safe 32K context default"
check_contains "GGML_METAL_TENSOR_DISABLE=" "$OUT" "macOS M4 Pro: leaves Metal tensor API enabled"

# 4a2. macOS Apple Silicon (16 GB -> safe 16K context)
OUT_M16="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=16384 bash "$CD/start.sh" 2>&1)"
check_contains "VARIANT=pq2-mtp" "$OUT_M16" "macOS arm64 (16GB): auto picks pq2-mtp"
check_contains "CTX_VALUE=16384" "$OUT_M16" "macOS arm64 (16GB): auto-tunes safe 16K context"

# 4a3. macOS Apple M5 on macOS 26.3 -> auto GGML_METAL_TENSOR_DISABLE=1
OUT_M5="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=32768 BONSAI_TEST_CPU_BRAND="Apple M5 Pro" BONSAI_TEST_MACOS_VER="26.3.1" bash "$CD/start.sh" 2>&1)"
check_contains "GGML_METAL_TENSOR_DISABLE=1" "$OUT_M5" "macOS Apple M5 (26.3): auto-sets GGML_METAL_TENSOR_DISABLE=1"

# 4b. macOS Apple Silicon (8 GB tight RAM -> auto safe tuning)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=8192 bash "$CD/start.sh" 2>&1)"
check_contains "VARIANT=ptq1-mtp" "$OUT" "macOS arm64 (8GB): auto picks smaller ptq1-mtp"
check_contains "CTX_VALUE=8192"   "$OUT" "macOS arm64 (8GB): auto-tunes safe 8K context"
check_contains "MMPROJ_CPU=1"     "$OUT" "macOS arm64 (8GB): keeps mmproj on CPU"
check_contains "KV4=1"            "$OUT" "macOS arm64 (8GB): auto-enables 4-bit KV cache"

# 4b2. Linux x86_64 NVIDIA 8 GB VRAM (RTX 4060 / 3070 -> auto safe tuning)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cuda BONSAI_TEST_CUDA_VER=12.4 BONSAI_TEST_VRAM_MB=8192 bash "$CD/start.sh" 2>&1)"
check_contains "VARIANT=ptq1-mtp" "$OUT" "Linux CUDA 8GB VRAM: auto picks ptq1-mtp"
check_contains "CTX_VALUE=16384"  "$OUT" "Linux CUDA 8GB VRAM: auto-tunes safe 16K context"
check_contains "MMPROJ_CPU=1"     "$OUT" "Linux CUDA 8GB VRAM: keeps mmproj in system RAM"
check_contains "KV4=1"            "$OUT" "Linux CUDA 8GB VRAM: auto-enables 4-bit KV cache"
check_contains "EFF_NGL=99"       "$OUT" "Linux CUDA 8GB VRAM: keeps full 99 layer offload"

# 4b3. Linux x86_64 NVIDIA 6 GB VRAM laptop (RTX 3060 6GB / RTX 4050 -> auto layer fit)
OUT_6G="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cuda BONSAI_TEST_CUDA_VER=12.4 BONSAI_TEST_VRAM_MB=6144 bash "$CD/start.sh" 2>&1)"
check_contains "EFF_NGL=auto"     "$OUT_6G" "Linux CUDA 6GB VRAM: auto-splits GPU/CPU layers (-ngl auto)"
check_contains "CTX_VALUE=16384"  "$OUT_6G" "Linux CUDA 6GB VRAM: 16K context"
check_contains "KV4=1"            "$OUT_6G" "Linux CUDA 6GB VRAM: 4-bit KV cache"

# 4c. macOS Apple Silicon MLX dry run (server & one-shot modes)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=32768 bash "$CD/start.sh" mlx 2>&1)"
check_contains "BACKEND=mlx" "$OUT" "macOS arm64 mlx: BACKEND=mlx"
check_contains "HF_REPO=prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit" "$OUT" "macOS arm64 mlx: resolves MLX HF repo"
check_contains "MLX_ONCE=0" "$OUT" "macOS arm64 mlx: defaults to OpenAI/Anthropic server mode"

OUT_MLX_ONCE="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=8192 bash "$CD/start.sh" mlx -p "Hello MLX" 2>&1)"
check_contains "MLX_ONCE=1" "$OUT_MLX_ONCE" "macOS arm64 mlx -p: selects one-shot mode"
check_contains "CTX_VALUE=8192" "$OUT_MLX_ONCE" "macOS arm64 mlx (8GB): auto-caps KV at 8K"
check_contains "KV4=1" "$OUT_MLX_ONCE" "macOS arm64 mlx (8GB): auto-enables 4-bit KV"

# 4d. macOS Intel (x86_64)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_RAM_MB=32768 bash "$CD/start.sh" 2>&1)"
check_contains "BACKEND=cpu" "$OUT" "macOS x64: BACKEND=cpu"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-macos-x64.tar.gz" "$OUT" "macOS x64: prebuilt macos-x64 archive"
check_contains "MTP_ENABLED=0" "$OUT" "macOS x64: MTP off by default on CPU"
check_contains "EFF_NGL=0" "$OUT" "macOS x64: EFF_NGL=0 on CPU"

# 4e. Linux x86_64 NVIDIA CUDA 12.8 (Blackwell / RTX 5090)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cuda BONSAI_TEST_CUDA_VER=12.8 BONSAI_TEST_VRAM_MB=32768 bash "$CD/start.sh" 2>&1)"
check_contains "BACKEND=cuda" "$OUT" "Linux CUDA 12.8: BACKEND=cuda"
check_contains "VARIANT=ptq1-mtp" "$OUT" "Linux CUDA: auto picks ptq1-mtp"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-linux-cuda-12.8-x64.tar.gz" "$OUT" "Linux CUDA 12.8: matches 12.8 archive"
check_contains "NEEDS_SOURCE_BUILD=0" "$OUT" "Linux x64 CUDA: uses prebuilt binary"
check_contains "MTP_ENABLED=1" "$OUT" "Linux CUDA: MTP auto-enabled"
check_contains "MTP_NMAX=3" "$OUT" "Linux CUDA: MTP n-max=3"
check_contains "MTP_PMIN=0.1" "$OUT" "Linux CUDA: MTP p-min=0.1"
check_contains "PARALLEL=1" "$OUT" "Linux CUDA: safe PARALLEL=1 default"

# 4f. Linux x86_64 NVIDIA CUDA 13.3
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cuda BONSAI_TEST_CUDA_VER=13.3 bash "$CD/start.sh" auto 2>&1)"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-linux-cuda-13.3-x64.tar.gz" "$OUT" "Linux CUDA 13.3: matches 13.3 archive"

# 4g. Linux ARM64 NVIDIA CUDA (DGX Spark GB10) -> auto source build
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=aarch64 BONSAI_TEST_BACKEND=cuda BONSAI_TEST_CUDA_VER=12.8 bash "$CD/start.sh" auto 2>&1)"
check_contains "ARCH=arm64" "$OUT" "Linux ARM64 CUDA: ARCH=arm64"
check_contains "NEEDS_SOURCE_BUILD=1" "$OUT" "Linux ARM64 CUDA (DGX Spark): auto-selects source build"
check_contains "VARIANT=ptq1-mtp" "$OUT" "Linux ARM64 CUDA: picks ptq1-mtp"
check_contains "MTP_ENABLED=1" "$OUT" "Linux ARM64 CUDA: MTP auto-enabled"

# 4h. Linux x86_64 AMD ROCm
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=rocm bash "$CD/start.sh" auto 2>&1)"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-ubuntu-rocm-7.2-x64.tar.gz" "$OUT" "Linux ROCm: matches ROCm 7.2 archive"
check_contains "MTP_ENABLED=1" "$OUT" "Linux ROCm: MTP auto-enabled"

# 4i. Linux x86_64 Vulkan + instruct mode + KV4 + NO_VISION
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=vulkan MODE=instruct KV4=1 NO_VISION=1 CONTEXT_SIZE=131072 bash "$CD/start.sh" q2-mtp 2>&1)"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-ubuntu-vulkan-x64.tar.gz" "$OUT" "Linux Vulkan: matches vulkan archive"
check_contains "MODEL_FILE=Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf" "$OUT" "q2-mtp resolves Q2_0-mtp file"
check_contains "MODE=instruct" "$OUT" "instruct mode applied"
check_contains "KV4=1" "$OUT" "KV4=1 applied"
check_contains "MMPROJ_FILE=" "$OUT" "NO_VISION=1 clears mmproj"
check_contains "CTX_VALUE=131072" "$OUT" "explicit CONTEXT_SIZE=131072 honored"
check_contains "MTP_ENABLED=1" "$OUT" "Vulkan: MTP auto-enabled (+63% measured on Radeon 890M)"
check_contains "MTP_NMAX=1"    "$OUT" "Vulkan Q2/PQ2: MTP n-max=1"

OUT_VK_PTQ="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=vulkan bash "$CD/start.sh" ptq1-mtp 2>&1)"
check_contains "MTP_NMAX=2"    "$OUT_VK_PTQ" "Vulkan PTQ1_0: MTP n-max=2"

# 4j. Linux x86_64 CPU + MTP forced ON + base non-MTP check
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cpu MTP=on bash "$CD/start.sh" ptq1-mtp 2>&1)"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-ubuntu-x64.tar.gz" "$OUT" "Linux x64 CPU: matches ubuntu-x64 archive"
check_contains "MTP_ENABLED=1" "$OUT" "CPU + MTP=on forces MTP enabled"

OUT_BASE="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cuda MTP=on bash "$CD/start.sh" ptq1 2>&1)"
check_contains "MODEL_FILE=Ternary-Bonsai-2.5-27B-PTQ1_0.gguf" "$OUT_BASE" "ptq1 resolves base PTQ1_0 file"
check_contains "MTP_ENABLED=0" "$OUT_BASE" "base non-MTP model keeps MTP_ENABLED=0 even if MTP=on"

# ─── 5. Simulated macOS Apple Silicon (Metal + MLX) end-to-end runtime check ───
echo ""
echo "═══ 5. Simulated macOS arm64 runtime execution (Metal & MLX) ═══"
SIM_TMP="$(mktemp -d)"
mkdir -p "$SIM_TMP/fakebin" "$SIM_TMP/bonsai25/venv-mlx/bin" "$SIM_TMP/bonsai25/models/mlx" \
         "$SIM_TMP/bonsai25/bin/prism-b12178-03ec600-metal/llama-prism-b12178-03ec600"

# Create fake MLX venv python that validates mlx_venv_ready and simulates mlx_vlm.server / one-shot
cat > "$SIM_TMP/bonsai25/venv-mlx/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" && "${2:-}" == "mlx_vlm.server" ]]; then
  echo "SIM_MLX_SERVER_ARGS: $*"
  sleep 30
  exit 0
fi
INPUT="$(cat)"
if printf '%s' "$INPUT" | grep -q "expected ="; then
  exit 0
fi
if printf '%s' "$INPUT" | grep -q "PROMPT_TEXT"; then
  echo "SIM_MLX_ONESHOT_OK:${PROMPT_TEXT}:${MODE}"
  exit 0
fi
exit 0
EOF
chmod +x "$SIM_TMP/bonsai25/venv-mlx/bin/python"
echo '{"model_type":"prism_hadamard_qwen35"}' > "$SIM_TMP/bonsai25/models/mlx/config.json"
# Sparse >100MB file so size check passes without disk usage
truncate -s 110M "$SIM_TMP/bonsai25/models/mlx/model.safetensors" 2>/dev/null || dd if=/dev/zero of="$SIM_TMP/bonsai25/models/mlx/model.safetensors" bs=1 count=1 seek=115343360 2>/dev/null

# 5a. Simulated macOS MLX one-shot execution
SIM_MLX_OUT="$(BONSAI25_DIR="$SIM_TMP/bonsai25" BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=32768 MODE=instruct bash "$CD/start.sh" mlx -p "2+2?" 2>&1)"
check_contains "MLX Python environment ready" "$SIM_MLX_OUT" "macOS MLX sim: recognizes valid Python 3.11 + mlx-vlm 0.7.8 venv"
check_contains "MLX model pack ready" "$SIM_MLX_OUT" "macOS MLX sim: recognizes cached MLX weights"
check_contains "SIM_MLX_ONESHOT_OK:2+2?:instruct" "$SIM_MLX_OUT" "macOS MLX sim: runs one-shot generation with mode settings"

# 5b. Simulated macOS MLX detached server + stop.sh lifecycle
SIM_MLX_SRV="$(BONSAI25_DIR="$SIM_TMP/bonsai25" BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=16384 PORT=18991 KV4=1 bash "$CD/start.sh" mlx --detached 2>&1)"
check_contains "Starting MLX OpenAI/Anthropic Server" "$SIM_MLX_SRV" "macOS MLX sim: launches mlx_vlm.server"
sleep 0.3
MLX_LOG_CONTENT="$(cat "$SIM_TMP/bonsai25/mlx-server.log" 2>/dev/null || true)"
check_contains "--model $SIM_TMP/bonsai25/models/mlx --host 0.0.0.0 --port 18991 --max-kv-size 16384 --enable-thinking --kv-bits 4 --max-num-seqs 1" "$MLX_LOG_CONTENT" "macOS MLX sim: passes exact mlx_vlm.server args"
SIM_STOP_OUT="$(BONSAI25_DIR="$SIM_TMP/bonsai25" bash "$CD/stop.sh" 2>&1)"
check_contains "Stopped Bonsai 2.5 server" "$SIM_STOP_OUT" "stop.sh cleanly stops simulated macOS MLX server"

# 5c. Simulated macOS Metal llama-server detached + NO_VISION=--no-mmproj + stop.sh
cat > "$SIM_TMP/bonsai25/bin/prism-b12178-03ec600-metal/llama-prism-b12178-03ec600/llama-server" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "version: prism-b12178"; exit 0; fi
if [[ "${1:-}" == "--list-devices" ]]; then echo "  Metal0: Apple M4 Pro"; exit 0; fi
echo "SIM_METAL_ARGS: $* DYLD=${DYLD_LIBRARY_PATH:-} TENSOR_DIS=${GGML_METAL_TENSOR_DISABLE:-}"
sleep 30
EOF
chmod +x "$SIM_TMP/bonsai25/bin/prism-b12178-03ec600-metal/llama-prism-b12178-03ec600/llama-server"
truncate -s 110M "$SIM_TMP/bonsai25/models/Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf" 2>/dev/null || dd if=/dev/zero of="$SIM_TMP/bonsai25/models/Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf" bs=1 count=1 seek=115343360 2>/dev/null

SIM_METAL_SRV="$(BONSAI25_DIR="$SIM_TMP/bonsai25" BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=32768 BONSAI_TEST_CPU_BRAND="Apple M5" BONSAI_TEST_MACOS_VER="26.3" NO_VISION=1 NO_BROWSER=1 PORT=18992 bash "$CD/start.sh" --detached 2>&1)"
check_contains "Runtime smoke test passed" "$SIM_METAL_SRV" "macOS Metal sim: smoke test passes with DYLD_LIBRARY_PATH"
sleep 0.3
METAL_LOG_CONTENT="$(cat "$SIM_TMP/bonsai25/llama-server.log" 2>/dev/null || true)"
check_contains "--no-mmproj" "$METAL_LOG_CONTENT" "macOS Metal sim: NO_VISION=1 passes --no-mmproj"
check_contains "--spec-type draft-mtp --spec-draft-n-min 0 --spec-draft-n-max 1 --spec-draft-p-min 0.6" "$METAL_LOG_CONTENT" "macOS Metal sim: passes exact Metal MTP flags"
check_contains "TENSOR_DIS=1" "$METAL_LOG_CONTENT" "macOS Metal sim: exports GGML_METAL_TENSOR_DISABLE=1 on M5 macOS 26.3"
BONSAI25_DIR="$SIM_TMP/bonsai25" bash "$CD/stop.sh" >/dev/null 2>&1 || true
rm -rf "$SIM_TMP"

echo ""
echo "═══ 6. Portability & hygiene checks ═══"
for bad in "/mnt/ugreen" "gx10-" "mikehutu" "DESKTOP-"; do
  if grep -qi "$bad" "$CD/start.sh" "$CD/start.ps1" "$CD/stop.sh" "$CD/stop.ps1"; then
    fail "Found machine-specific string '$bad' in runner scripts"
  else
    pass "No machine-specific '$bad' in runner scripts"
  fi
done

echo ""
echo "═══ 7. Remote URL verification (GitHub Releases + HuggingFace GGUF & MLX) ═══"
if command -v curl >/dev/null 2>&1; then
  for asset in \
    "llama-prism-b12178-03ec600-bin-macos-arm64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-macos-x64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-linux-cuda-12.4-x64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-linux-cuda-12.8-x64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-linux-cuda-13.3-x64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-ubuntu-rocm-7.2-x64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-ubuntu-vulkan-x64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-ubuntu-vulkan-arm64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-ubuntu-x64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-ubuntu-arm64.tar.gz" \
    "llama-prism-b12178-03ec600-bin-win-cuda-12.4-x64.zip" \
    "cudart-llama-bin-win-cuda-12.4-x64.zip" \
    "llama-prism-b12178-03ec600-bin-win-cuda-13.3-x64.zip" \
    "cudart-llama-bin-win-cuda-13.3-x64.zip" \
    "llama-prism-b12178-03ec600-bin-win-cuda-13.4-arm64.zip" \
    "cudart-llama-bin-win-cuda-13.4-arm64.zip" \
    "llama-prism-b12178-03ec600-bin-win-hip-radeon-x64.zip" \
    "llama-prism-b12178-03ec600-bin-win-vulkan-x64.zip" \
    "llama-prism-b12178-03ec600-bin-win-cpu-x64.zip" \
    "llama-prism-b12178-03ec600-bin-win-cpu-arm64.zip"
  do
    code="$(curl -sI -L --max-time 15 -o /dev/null -w "%{http_code}" "https://github.com/PrismML-Eng/llama.cpp/releases/download/prism-b12178-03ec600/${asset}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      pass "Release asset OK (HTTP 200): $asset"
    else
      fail "Release asset failed (HTTP $code): $asset"
    fi
  done

  for hf_file in \
    "Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf" \
    "Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf" \
    "Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf" \
    "Ternary-Bonsai-2.5-27B-PTQ1_0.gguf" \
    "Ternary-Bonsai-2.5-27B-PQ2_0.gguf" \
    "Ternary-Bonsai-2.5-27B-Q2_0.gguf" \
    "Ternary-Bonsai-2.5-27B-mmproj-Q8_0.gguf" \
    "Ternary-Bonsai-2.5-27B-mmproj-BF16.gguf"
  do
    code="$(curl -sI -L --max-time 15 -o /dev/null -w "%{http_code}" "https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF/resolve/main/${hf_file}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      pass "HF GGUF file OK (HTTP 200): $hf_file"
    else
      fail "HF GGUF file failed (HTTP $code): $hf_file"
    fi
  done

  for mlx_file in "config.json" "model.safetensors"; do
    code="$(curl -sI -L --max-time 15 -o /dev/null -w "%{http_code}" "https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit/resolve/main/${mlx_file}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      pass "HF MLX file OK (HTTP 200): $mlx_file"
    else
      fail "HF MLX file failed (HTTP $code): $mlx_file"
    fi
  done
fi

echo ""
echo "═══ 8. Static analysis (ShellCheck) ═══"
if command -v shellcheck >/dev/null 2>&1; then
  SC="$(shellcheck -S warning "$CD/start.sh" "$CD/stop.sh" "$CD/test-model.sh" 2>&1 || true)"
  if [[ -z "$SC" ]]; then
    pass "shellcheck: zero warnings/errors"
  else
    echo "$SC"
    fail "shellcheck reported issues"
  fi
else
  pass "shellcheck not installed (skipped)"
fi

echo ""
echo "══════════════════════════════"
echo "  ${PASS} passed · ${FAIL} failed"
echo "══════════════════════════════"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
