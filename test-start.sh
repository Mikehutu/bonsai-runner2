#!/usr/bin/env bash
# test-start.sh — Comprehensive validation suite for bonsai-runner2
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

echo ""
echo "═══ 1. File structure & syntax ═══"
for f in start.sh stop.sh start.ps1 stop.ps1 .env.example .gitignore README.md AGENTS.md test-start.sh test-start.ps1; do
  [[ -f "$CD/$f" ]] && pass "$f exists" || fail "$f missing"
done
[[ -x "$CD/start.sh" ]] && pass "start.sh is executable" || fail "start.sh not executable"
[[ -x "$CD/stop.sh"  ]] && pass "stop.sh is executable"  || fail "stop.sh not executable"

bash -n "$CD/start.sh" 2>/dev/null && pass "start.sh passes bash -n syntax check" || fail "start.sh syntax error"
bash -n "$CD/stop.sh"  2>/dev/null && pass "stop.sh passes bash -n syntax check"  || fail "stop.sh syntax error"

echo ""
echo "═══ 2. macOS Bash 3.2 compatibility audit ═══"
START_SRC="$(cat "$CD/start.sh")"
# Strip comment lines for Bash 4+ construct checks
START_CODE="$(grep -vE '^[[:space:]]*#' "$CD/start.sh")"
check_not_contains "declare -A" "$START_CODE" "no Bash 4+ 'declare -A' in start.sh"
check_not_contains "mapfile"    "$START_CODE" "no Bash 4+ 'mapfile' in start.sh"
check_not_contains "readarray"  "$START_CODE" "no Bash 4+ 'readarray' in start.sh"
if printf '%s\n' "$START_CODE" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*,,|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^'; then
  fail "found Bash 4+ case conversion (\${var,,} / \${var^^}) in start.sh"
else
  pass "no Bash 4+ case conversion in start.sh"
fi
check_contains "hw.memsize" "$START_SRC" "macOS RAM detection (sysctl hw.memsize)"
check_contains "hw.ncpu"    "$START_SRC" "macOS CPU core detection (sysctl hw.ncpu)"
check_contains "xattr -cr"  "$START_SRC" "macOS Gatekeeper quarantine clearing"
check_contains "codesign"   "$START_SRC" "macOS ad-hoc binary/dylib signing"
check_contains "DYLD_LIBRARY_PATH" "$START_SRC" "macOS DYLD_LIBRARY_PATH handling"
check_contains "stat -f%z"  "$START_SRC" "macOS stat -f%z file-size fallback"

echo ""
echo "═══ 3. Help & error handling ═══"
H="$(bash "$CD/start.sh" --help 2>&1 || true)"
check_contains "ptq1-mtp" "$H" "help lists ptq1-mtp"
check_contains "pq2-mtp"  "$H" "help lists pq2-mtp"
check_contains "q2-mtp"   "$H" "help lists q2-mtp"
check_contains "mlx"      "$H" "help lists mlx"
check_contains "CONTEXT_SIZE" "$H" "help lists CONTEXT_SIZE"
check_contains "MTP"      "$H" "help lists MTP"
check_contains "PARALLEL" "$H" "help lists PARALLEL"

E="$(bash "$CD/start.sh" nonexistent_variant 2>&1 || true)"
check_contains "Unknown variant" "$E" "rejects unknown variant"
check_contains "ptq1-mtp"        "$E" "error lists valid variants"

E_MODE="$(MODE=bogus BONSAI_DRY_RUN=1 bash "$CD/start.sh" ptq1-mtp 2>&1 || true)"
check_contains "Unknown MODE" "$E_MODE" "rejects invalid MODE"

E_MTP="$(MTP=bogus BONSAI_DRY_RUN=1 bash "$CD/start.sh" ptq1-mtp 2>&1 || true)"
check_contains "Unknown MTP" "$E_MTP" "rejects invalid MTP"

E_MLX="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cpu bash "$CD/start.sh" mlx 2>&1 || true)"
check_contains "Apple Silicon Mac" "$E_MLX" "mlx variant cleanly rejected on Linux"

echo ""
echo "═══ 4. Cross-platform dry-run matrix ═══"

# 4a. macOS Apple Silicon (M-series, 32 GB)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=32768 bash "$CD/start.sh" 2>&1)"
check_contains "OS=Darwin" "$OUT" "macOS arm64: OS=Darwin"
check_contains "ARCH=arm64" "$OUT" "macOS arm64: ARCH=arm64"
check_contains "BACKEND=metal" "$OUT" "macOS arm64: BACKEND=metal"
check_contains "VARIANT=pq2-mtp" "$OUT" "macOS arm64 (32GB): auto picks pq2-mtp"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-macos-arm64.tar.gz" "$OUT" "macOS arm64: prebuilt macos-arm64 archive"
check_contains "MTP_ENABLED=1" "$OUT" "macOS arm64: MTP auto-enabled"
check_contains "MTP_NMAX=1" "$OUT" "macOS arm64: MTP n-max=1"
check_contains "MTP_PMIN=0.6" "$OUT" "macOS arm64: MTP p-min=0.6"
check_contains "CTX_VALUE=32768" "$OUT" "macOS arm64: safe 32K context default"

# 4b. macOS Apple Silicon (8 GB tight RAM)
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 BONSAI_TEST_RAM_MB=8192 bash "$CD/start.sh" 2>&1)"
check_contains "VARIANT=ptq1-mtp" "$OUT" "macOS arm64 (8GB): auto picks smaller ptq1-mtp"

# 4c. macOS Apple Silicon MLX dry run
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Darwin BONSAI_TEST_ARCH=arm64 bash "$CD/start.sh" mlx 2>&1)"
check_contains "HF_REPO=prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit" "$OUT" "macOS arm64 mlx: resolves MLX HF repo"

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
check_contains "MTP_ENABLED=0" "$OUT" "Vulkan: MTP off by default"

# 4j. Linux x86_64 CPU + MTP forced ON + base non-MTP check
OUT="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cpu MTP=on bash "$CD/start.sh" ptq1-mtp 2>&1)"
check_contains "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-ubuntu-x64.tar.gz" "$OUT" "Linux x64 CPU: matches ubuntu-x64 archive"
check_contains "MTP_ENABLED=1" "$OUT" "CPU + MTP=on forces MTP enabled"

OUT_BASE="$(BONSAI_DRY_RUN=1 BONSAI_TEST_OS=Linux BONSAI_TEST_ARCH=x86_64 BONSAI_TEST_BACKEND=cuda MTP=on bash "$CD/start.sh" ptq1 2>&1)"
check_contains "MODEL_FILE=Ternary-Bonsai-2.5-27B-PTQ1_0.gguf" "$OUT_BASE" "ptq1 resolves base PTQ1_0 file"
check_contains "MTP_ENABLED=0" "$OUT_BASE" "base non-MTP model keeps MTP_ENABLED=0 even if MTP=on"

# 4k. Verify NO machine-specific paths leaked into start.sh/start.ps1
echo ""
echo "═══ 5. Portability & hygiene checks ═══"
for bad in "/mnt/ugreen" "gx10-" "mikehutu" "DESKTOP-"; do
  if grep -qi "$bad" "$CD/start.sh" "$CD/start.ps1" "$CD/stop.sh" "$CD/stop.ps1"; then
    fail "Found machine-specific string '$bad' in runner scripts"
  else
    pass "No machine-specific '$bad' in runner scripts"
  fi
done

# 4l. Verify pinned release asset URLs actually exist on GitHub (HEAD check)
echo ""
echo "═══ 6. Remote URL verification (GitHub Releases + HuggingFace) ═══"
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
    code="$(curl -sI -L -o /dev/null -w "%{http_code}" "https://github.com/PrismML-Eng/llama.cpp/releases/download/prism-b12178-03ec600/${asset}" 2>/dev/null || echo 000)"
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
    code="$(curl -sI -L -o /dev/null -w "%{http_code}" "https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF/resolve/main/${hf_file}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      pass "HF GGUF file OK (HTTP 200): $hf_file"
    else
      fail "HF GGUF file failed (HTTP $code): $hf_file"
    fi
  done
fi

echo ""
echo "═══ 7. Static analysis (ShellCheck) ═══"
if command -v shellcheck >/dev/null 2>&1; then
  SC="$(shellcheck -S warning "$CD/start.sh" "$CD/stop.sh" 2>&1 || true)"
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
