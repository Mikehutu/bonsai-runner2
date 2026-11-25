# AGENTS.md — Bonsai 2.5 27B Runner (`bonsai-runner2`)

Instructions for AI coding agents (Antigravity, Claude Code, Codex, OpenCode, etc.) working on or helping users run `bonsai-runner2`.

## Project Overview

`bonsai-runner2` is a zero-friction, cross-platform one-click local runner for **Ternary Bonsai 2.5 27B** (`https://huggingface.co/collections/prism-ml/bonsai-25-27b`):
- GGUF repo: `prism-ml/Ternary-Bonsai-2.5-27B-GGUF`
- Apple Silicon MLX repo: `prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit`
- Runtime: `PrismML-Eng/llama.cpp` (pinned prebuilt release `prism-b12178-03ec600` with automatic source-build fallback on Linux/macOS)

## Project Structure

```
bonsai-runner2/
├── start.sh          # One-click runner for Linux, macOS (Apple Silicon & Intel), and WSL2
├── stop.sh           # Stop server (Linux/macOS/WSL2)
├── start.ps1         # Native Windows PowerShell runner (PowerShell 5.1 & 7+)
├── stop.ps1          # Stop server (Windows)
├── .env.example      # Configuration reference (auto-loaded if copied to .env)
├── .gitignore        # Ignores .env, logs, PID files, local models/bin
├── README.md         # User documentation
├── AGENTS.md         # This file
├── test-start.sh     # Cross-platform validation suite for start.sh / stop.sh
└── test-start.ps1    # Windows PowerShell validation suite for start.ps1 / stop.ps1
```

## Critical Invariants (Do Not Break)

1. **Bash 3.2 compatibility in `start.sh` and `stop.sh`:**
   - macOS ships `/bin/bash` 3.2.57. NEVER use `declare -A`, `${var,,}`, `${var^^}`, `mapfile`, `readarray`, or GNU-only flags (`stat -c` without `stat -f` fallback, `nproc` without `sysctl -n hw.ncpu` fallback).
   - Under `set -euo pipefail`, always guard potentially empty arrays in Bash 3.2.

2. **No machine-specific paths:**
   - Never hardcode hostnames, `/mnt/ugreen`, `gx10`, or personal usernames in `start.sh` or `start.ps1`.
   - Use `~/.bonsai25/` (overridable via `BONSAI25_DIR`).

3. **Zero external dependencies for GGUF serving:**
   - `start.sh` downloads prebuilt binaries and HuggingFace GGUFs with `curl` (or `wget`) — no `python3`, `pip`, `cmake`, or `make` required on the happy path.
   - `start.ps1` uses built-in Windows `curl.exe` and `Expand-Archive` — no WSL, Git, Python, or Visual Studio required.
   - Downloads write to `<dest>.part` and atomically rename on success, checking minimum byte size so truncated/HTML responses never corrupt the cache.

4. **Archive extraction safety:**
   - PrismML `.tar.gz` archives have leading `./llama-<tag>/` path components, so `start.sh` extracts and recursively locates `llama-server` via `find`, setting `LD_LIBRARY_PATH` (Linux) / `DYLD_LIBRARY_PATH` (macOS) to `dirname "$SERVER_BIN"`.
   - On macOS, always run `xattr -cr` and ad-hoc `codesign -s - --force --timestamp=none` on extracted binaries and `.dylib`s.
   - On Windows CUDA, always download and extract the matching `cudart-llama-bin-win-cuda-<ver>-<arch>.zip` into the same directory as `llama-server.exe`.

5. **Bonsai 2.5 model defaults:**
   - Thinking mode (default): `--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0`
   - Instruct mode: `--temp 0.7 --top-p 0.80 --top-k 20 --min-p 0 --presence-penalty 1.5 --repeat-penalty 1.0 --reasoning-budget 0 --reasoning off`
   - Always pass `-fa on --jinja`.
   - `CONTEXT_SIZE=0` maps to `-c 32768` (GGUF metadata default is 262K, which can OOM smaller machines).
   - `PARALLEL=1` default (`-np 1`) avoids 4-slot KV allocation (~9.5 GB vs ~7.8 GB VRAM on 10 GB GPUs).
   - Built-in MTP (`*-mtp.gguf`): auto-enabled on `cuda`/`rocm`/`hip` (`n-max=3, p-min=0.1`) and `metal` (`n-max=1, p-min=0.6`); off by default on `cpu`/`vulkan` unless `MTP=on`.
   - Note: Upstream issue `PrismML-Eng/llama.cpp#180` (PQ2_0 CPU repack segfault) was fixed in `prism-b10735-842b188` (#245), so `--no-repack` is NOT needed on `prism-b12178-03ec600+`.

## Testing

```bash
# Linux / macOS automated checks + cross-platform dry-run matrix
bash test-start.sh

# Windows automated checks + dry-run matrix
powershell -ExecutionPolicy Bypass -File test-start.ps1
```

Dry-run test environment hooks supported by `start.sh`:
- `BONSAI_DRY_RUN=1`
- `BONSAI_TEST_OS` (`Linux` | `Darwin`)
- `BONSAI_TEST_ARCH` (`x86_64` | `arm64` | `aarch64`)
- `BONSAI_TEST_BACKEND` (`cuda` | `rocm` | `vulkan` | `metal` | `cpu`)
- `BONSAI_TEST_CUDA_VER` (e.g. `12.4`, `12.8`, `13.3`)
- `BONSAI_TEST_RAM_MB` / `BONSAI_TEST_VRAM_MB`

Dry-run hooks supported by `start.ps1`:
- `-DryRun`
- `$env:BONSAI_TEST_ARCH` (`AMD64` | `ARM64`)
- `$env:BONSAI_TEST_BACKEND` (`cuda` | `hip` | `vulkan` | `cpu`)
- `$env:BONSAI_TEST_CUDA_VER` (e.g. `12.4`, `13.3`)
