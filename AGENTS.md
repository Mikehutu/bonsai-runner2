# AGENTS.md — Bonsai 2.5 27B Runner (`bonsai-runner2`)

Instructions for AI coding agents (Antigravity, Claude Code, Codex, OpenCode, etc.) working on or helping users run `bonsai-runner2`.

## Project Overview

`bonsai-runner2` is a zero-friction, cross-platform one-click local runner for **Ternary Bonsai 2.5 27B** (`https://huggingface.co/collections/prism-ml/bonsai-25-27b`):
- GGUF repo: `prism-ml/Ternary-Bonsai-2.5-27B-GGUF`
- Apple Silicon MLX repo: `prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit` (served via native `mlx-vlm==0.7.8` `prism_hadamard_qwen35`)
- Runtime: `PrismML-Eng/llama.cpp` (pinned prebuilt release `prism-b12178-03ec600` with automatic source-build fallback on Linux/macOS)

## Project Structure

```text
bonsai-runner2/
├── start.sh          # One-click runner for Linux, macOS (Metal & MLX, arm64 & Intel), WSL2, and Git Bash
├── stop.sh           # Stop server (llama-server or mlx_vlm.server)
├── test-model.sh     # Live model test (health, chat + tok/s + MTP stats, native tool calling)
├── start.ps1         # Native Windows PowerShell runner (PowerShell 5.1 & 7+, x64 & ARM64)
├── stop.ps1          # Stop server (Windows)
├── test-model.ps1    # Live model test on Windows (health, chat + tok/s, native tool calling)
├── .env.example      # Configuration reference (auto-loaded if copied to .env)
├── .gitattributes    # Enforces LF on *.sh and CRLF on *.ps1 across git checkouts
├── .gitignore        # Ignores .env, logs, PID files, local models/bin
├── README.md         # User documentation & troubleshooting
├── HARDWARE-GUIDE.md # Exact GGUF KV cache math & GPU/laptop/Mac speed tables
├── AGENTS.md         # This file
├── test-start.sh     # Cross-platform validation suite + simulated macOS Metal/MLX runtime checks
└── test-start.ps1    # PowerShell AST + pure-ASCII + Windows dry-run validation suite
```

## Critical Invariants (Do Not Break)

1. **Bash 3.2 compatibility & LF line endings in `*.sh`:**
   - macOS ships `/bin/bash` 3.2.57. NEVER use `declare -A`, `${var,,}`, `${var^^}`, `mapfile`, `readarray`, or GNU-only flags (`stat -c` without `stat -f` fallback, `nproc` without `sysctl -n hw.ncpu` fallback).
   - Keep all `*.sh` files strictly LF (`\n`, enforced by `.gitattributes` and `test-start.sh`).

2. **Pure 7-bit ASCII in `*.ps1`:**
   - Windows PowerShell 5.1 parses `.ps1` files without a UTF-8 BOM using the legacy system ANSI codepage (e.g. Windows-1252 / CP932 / CP936), where UTF-8 multi-byte sequences like `—` (`0xE2 0x80 0x94`) contain `0x94` (`”`), prematurely closing double-quoted strings at parse time.
   - NEVER put em-dashes, box-drawing characters, or any byte `>= 0x80` in `*.ps1` files (`test-start.sh` and `test-start.ps1` enforce pure ASCII).

3. **No machine-specific paths:**
   - Never hardcode hostnames, `/mnt/ugreen`, `gx10`, or personal usernames in runner scripts.
   - Use `~/.bonsai25/` (overridable via `BONSAI25_DIR`).

4. **Zero external dependencies for GGUF serving & self-bootstrapping MLX:**
   - `start.sh` downloads prebuilt binaries and HuggingFace GGUFs with `curl` (or `wget`) — no `python3`, `pip`, `cmake`, or `make` required on the GGUF happy path.
   - `start.ps1` uses built-in Windows `System32\curl.exe` and `Expand-Archive` (with `$ProgressPreference = 'SilentlyContinue'` to avoid PowerShell 5.1 progress-bar slowdowns).
   - Downloads write to `<dest>.part`, retry cleanly from byte 0 if a stale `.part` triggers HTTP 416, and check minimum byte size before/after atomic rename.
   - On macOS `mlx` (`bash start.sh mlx`), stock `/usr/bin/python3` is Python 3.9.6 which cannot install `mlx-lm>=0.32`. `start.sh` searches for Python >= 3.11 or `uv`, and automatically bootstraps standalone `uv` + Python 3.11 into `~/.bonsai25/uv-bin` when needed, installing the exact tested native stack (`mlx==0.32.3`, `mlx-vlm==0.7.8`, `mlx-lm==0.32.0`, `transformers==5.19.0`, `certifi>=2026.10.23`).

5. **Archive extraction & OS quirks:**
   - On macOS, always run `xattr -cr` and ad-hoc `codesign -s - --force --timestamp=none` on `llama-*`, `ggml-*`, and `*.dylib`. On Apple M5 + macOS 26.2–26.4, auto-export `GGML_METAL_TENSOR_DISABLE=1`.
   - On Windows GPU builds where the release zip only ships the backend DLL (e.g. `win-cuda-13.4-arm64.zip` contains only `ggml-cuda.dll`), `start.ps1` overlays `llama-<tag>-bin-win-cpu-<arch>.zip` first and re-extracts the GPU + `cudart` archives on top into `llama-server.exe`'s directory.

6. **Bonsai 2.5 model defaults:**
   - Thinking mode (default): `--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0`
   - Instruct mode: `--temp 0.7 --top-p 0.80 --top-k 20 --min-p 0 --presence-penalty 1.5 --repeat-penalty 1.0 --reasoning-budget 0 --reasoning off`
   - Always pass `-fa on --jinja`, and pass `--no-mmproj` when `NO_VISION=1` / `-NoVision` so cached projectors are not auto-loaded.
   - `CONTEXT_SIZE=0` maps to RAM/VRAM-tiered safe defaults (`8192`–`32768`); `<=6.8 GB` VRAM CUDA cards auto-set `-ngl auto`.
   - Built-in MTP (`*-mtp.gguf`): auto-enabled on `cuda`/`rocm`/`hip` (`n-max=3, p-min=0.1`), `metal` (`n-max=1, p-min=0.6`), and `vulkan` (`n-max=1` PQ2 / `n-max=2` PTQ1, `p-min=0.1`); off by default on `cpu` unless `MTP=on`.

## Testing

```bash
# Linux / macOS automated checks + simulated macOS Metal/MLX runtime tests
bash test-start.sh

# Windows PowerShell 5.1 or cross-platform PowerShell 7 (pwsh) validation suite
powershell -ExecutionPolicy Bypass -File test-start.ps1
```
