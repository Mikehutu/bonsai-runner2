# 🌳 Bonsai 2.5 27B Runner (`bonsai-runner2`)

Run **[Ternary Bonsai 2.5 27B](https://huggingface.co/collections/prism-ml/bonsai-25-27b)** locally on **macOS, Linux, or Windows** with **one command**.

> **~9× smaller than FP16 (5.9–7.5 GB)** · **FP16-level agentic tool calling** (77.2 vs 77.7) · **90% of FP16 agentic coding** (SWE-bench Verified 75.6, Terminal-Bench 2.1 60.1) · **262K context** · **Vision + Built-in MTP speculative decoding** · **Apache 2.0**

No cloud API. No subscription. No compiler or Python needed for GGUF serving — downloads the official prebuilt PrismML `llama.cpp` fork binary (with automatic source-build fallback on Linux/macOS when needed), pulls the GGUF weights from HuggingFace, and launches an OpenAI-compatible server with built-in Web UI.

---

## Quickstart

### macOS & Linux (and WSL2)

```bash
git clone https://github.com/Mikehutu/bonsai-runner2
cd bonsai-runner2

# One command: auto-detects GPU/VRAM/RAM, picks the optimal Bonsai 2.5 packing + safe memory settings, and starts!
bash start.sh

# In a second terminal, verify chat + native tool calling + measure tok/s:
bash test-model.sh

# Optional: interactive menu, or pick a specific variant directly:
bash start.sh --choose
bash start.sh ptq1-mtp    # 6.23 GB — fastest on NVIDIA CUDA & smallest MTP build
bash start.sh pq2-mtp     # 7.49 GB — benchmarked on Apple Silicon Metal / CPU / Vulkan
bash start.sh q2-mtp      # 7.91 GB — stock llama.cpp b11556+ compatible
bash start.sh mlx         # ~8.6 GB — Apple Silicon MLX 2-bit pack (macOS arm64 only)
```

Stop the server with `Ctrl+C` or `bash stop.sh`.

### Windows (native PowerShell — no WSL required)

```powershell
git clone https://github.com/Mikehutu/bonsai-runner2
cd bonsai-runner2

# One command: auto-detects GPU/VRAM/RAM (CUDA / HIP / Vulkan / CPU), downloads runtime + weights, and starts:
powershell -ExecutionPolicy Bypass -File start.ps1

# In a second PowerShell window, verify chat + native tool calling + measure tok/s:
powershell -ExecutionPolicy Bypass -File test-model.ps1

# Optional: interactive menu, or explicit variant/backend:
powershell -ExecutionPolicy Bypass -File start.ps1 -Choose
powershell -ExecutionPolicy Bypass -File start.ps1 -Variant ptq1-mtp
powershell -ExecutionPolicy Bypass -File stop.ps1
```

Once the model finishes loading, the built-in **llama.cpp Chat UI** automatically opens in your browser at **`http://localhost:8080`** (skip with `-NoBrowser` / `NO_BROWSER=1`), and the OpenAI-compatible API is live at `http://localhost:8080/v1/chat/completions`.

### How Auto-Selection Works

Running `start.sh` or `start.ps1` with no arguments automatically inspects your OS, CPU architecture, GPU vendor, VRAM, and system RAM:

- **NVIDIA CUDA (10+ GB VRAM or unified memory like DGX Spark) / AMD ROCm & HIP** → picks **`ptq1-mtp`** (6.23 GB, fastest NVIDIA decode + built-in MTP `n-max=3, p-min=0.1`), 32K context.
- **NVIDIA CUDA (≤ 8 GB VRAM, e.g. RTX 4060 / 3070)** → picks **`ptq1-mtp`** (6.23 GB) + auto-tunes **16K context**, **4-bit KV cache (`KV4=1`)**, and keeps the vision projector in system RAM (`--no-mmproj-offload`) so it fits cleanly without OOM.
- **Apple Silicon Mac (16+ GB RAM)** → picks **`pq2-mtp`** (7.49 GB, benchmarked on Metal + built-in MTP `n-max=1, p-min=0.6`), 32K context.
- **Apple Silicon Mac (8 GB RAM)** → picks **`ptq1-mtp`** (6.23 GB) + auto-tunes **8K context**, `KV4=1`, and CPU vision offload.
- **Linux / Windows Vulkan or CPU** → picks **`pq2-mtp`** (7.49 GB) when RAM ≥ 12 GB, or **`ptq1-mtp`** (6.23 GB) + 8K context + `KV4=1` on tighter machines.

> 📊 **Expected speeds & KV sizing for your exact GPU/Mac/laptop:** see **[HARDWARE-GUIDE.md](HARDWARE-GUIDE.md)** (exact GGUF-derived KV tables + theoretical & measured tok/s for RTX 30/40/50 desktop GPUs, gaming laptops, Apple Silicon MacBooks, and iGPUs).

---

## Variants

All GGUF files come from [`prism-ml/Ternary-Bonsai-2.5-27B-GGUF`](https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF) and represent the exact same ternary Qwen3.8-27B model weights with different packing/speed trade-offs:

| Variant | File | Size | Built-in MTP Head | Recommended For |
| --- | --- | ---: | :---: | --- |
| **`auto`** *(default)* | auto-selected | 6.2–7.5 GB | Yes | Everyone — picks `ptq1-mtp` on CUDA/ROCm/HIP or tight RAM (<12 GB), `pq2-mtp` on Apple Metal/CPU/Vulkan |
| **`ptq1-mtp`** | `Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf` | **6.23 GB** | Yes | **NVIDIA GPUs** (fastest decode, 1.76 bpw) and 8 GB VRAM / tight-RAM setups |
| **`pq2-mtp`** | `Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf` | **7.49 GB** | Yes | **Apple Silicon Metal** (benchmarked packing), CPU, Vulkan, fast prefill |
| **`q2-mtp`** | `Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf` | **7.91 GB** | Yes | Compatibility with upstream stock `llama.cpp` (`b11556+`) |
| **`ptq1`** | `Ternary-Bonsai-2.5-27B-PTQ1_0.gguf` | **5.99 GB** | No | Absolute smallest footprint without MTP head |
| **`pq2`** | `Ternary-Bonsai-2.5-27B-PQ2_0.gguf` | **7.25 GB** | No | PQ2_0 without MTP head |
| **`q2`** | `Ternary-Bonsai-2.5-27B-Q2_0.gguf` | **7.67 GB** | No | Stock `llama.cpp` `b11556+` without MTP head |
| **`mlx`** *(macOS arm64)* | [`prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit`](https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit) | **~8.6 GB** | Optional | Apple Silicon Python MLX workflow (note: `pq2-mtp` on Metal `llama-server` is faster and includes Web UI + OpenAI API) |

> **Built-in MTP speculative decoding:** The `-mtp` files embed a ~0.24 GB multi-token prediction draft head inside the same GGUF — no separate drafter file or conversion step needed, and prompt caching stays enabled. The head is inert when drafting is off, so `-mtp` files are drop-in replacements for the base files.

---

## Platform Support

One repo covers every desktop/server platform:

| Platform | Script | Auto-Detected Backend | Runtime Source | MTP Default |
| --- | --- | --- | --- | --- |
| **macOS Apple Silicon** (M1–M5) | `start.sh` | **Metal** (`arm64`) | Prebuilt PrismML macOS `arm64` archive (auto-clears Gatekeeper quarantine + ad-hoc signs) | **ON** (`n-max=1, p-min=0.6`) |
| **macOS Intel** | `start.sh` | **CPU** (`x64`) | Prebuilt PrismML macOS `x64` archive | OFF (`MTP=on` to force) |
| **Linux x86_64 + NVIDIA** | `start.sh` | **CUDA** (12.4 / 12.8 / 13.3 auto-matched to driver) | Prebuilt PrismML Linux CUDA archive | **ON** (`n-max=3, p-min=0.1`) |
| **Linux ARM64 + NVIDIA** (e.g. DGX Spark) | `start.sh` | **CUDA** (`aarch64`) | Auto-compiled from `PrismML-Eng/llama.cpp` (`-DGGML_CUDA=ON`) | **ON** (`n-max=3, p-min=0.1`) |
| **Linux x86_64 + AMD ROCm** | `start.sh` | **ROCm** | Prebuilt PrismML Ubuntu ROCm 7.2 archive | **ON** (`n-max=3, p-min=0.1`) |
| **Linux + Vulkan GPU** | `start.sh` | **Vulkan** (`x64` / `arm64`) | Prebuilt PrismML Ubuntu Vulkan archive | **ON** (`n-max=1` PQ2 / `n-max=2` PTQ1, `p-min=0.1`) |
| **Linux / WSL2 CPU** | `start.sh` | **CPU** (`x64` / `arm64`) | Prebuilt PrismML Ubuntu CPU archive (falls back to source build if glibc mismatch) | OFF (`MTP=on` to force) |
| **Windows 10/11 + NVIDIA** | `start.ps1` | **CUDA** (12.4 / 13.3 / arm64 13.4) | Prebuilt PrismML Windows CUDA + bundled `cudart` DLLs | **ON** (`n-max=3, p-min=0.1`) |
| **Windows 10/11 + AMD HIP** | `start.ps1` | **HIP** | Prebuilt PrismML Windows HIP Radeon archive | **ON** (`n-max=3, p-min=0.1`) |
| **Windows 10/11 + AMD/Intel GPU** | `start.ps1` | **Vulkan** | Prebuilt PrismML Windows Vulkan archive (auto-falls back to CPU if smoke test fails) | **ON** (`n-max=1` PQ2 / `n-max=2` PTQ1, `p-min=0.1`) |
| **Windows 10/11 CPU** | `start.ps1` | **CPU** (`x64` / `arm64`) | Prebuilt PrismML Windows CPU archive | OFF (`-Mtp on` to force) |

> **macOS note:** `start.sh` is written for strict **Bash 3.2 compatibility** (macOS's built-in `/bin/bash`) — no Homebrew bash required. It automatically runs `xattr -cr` and ad-hoc `codesign` on downloaded binaries and `.dylib` files. We verify Linux and Windows live and audit macOS paths via cross-platform dry-run simulation + Bash 3.2 static checks.

---

## Configuration

Copy `.env.example` to `.env` (automatically loaded by both `start.sh` and `start.ps1`), or pass environment variables / PowerShell flags directly:

| Env Var | PowerShell Flag | Default | Description |
| --- | --- | --- | --- |
| `MODEL_VARIANT` | `-Variant` | `auto` | `auto`, `ptq1-mtp`, `pq2-mtp`, `q2-mtp`, `ptq1`, `pq2`, `q2`, `mlx` |
| `BACKEND` | `-Backend` | auto | Force `cuda`, `rocm`, `hip` (Win), `vulkan`, `metal` (Mac), or `cpu` |
| `MODE` | `-Mode` | `thinking` | `thinking` (temp 1.0, top-p 0.95, top-k 20, min-p 0) or `instruct` (non-thinking, temp 0.7, presence-penalty 1.5) |
| `MTP` | `-Mtp` | `auto` | Built-in MTP speculative decoding: `auto`, `on`, or `off` |
| `PORT` | `-Port` | `8080` | Server port (auto-tries `PORT+1`, `PORT+2` if busy) |
| `HOST` | `-HostAddr` | `0.0.0.0` | Bind address |
| `NGL` | `-Ngl` | `99` | GPU layers to offload (auto `0` on CPU backend) |
| `CONTEXT_SIZE` | `-ContextSize` | `0` (→ `32768`) | Context tokens. `0` maps to safe 32K; set `262144` for full 262K |
| `PARALLEL` | `-Parallel` | `1` | Request slots (`-np`). `1` keeps VRAM ~7.8 GB on 8–10 GB GPUs; set `0` for auto or `4` for multi-user |
| `KV4` | `-Kv4` | `0` | Enable 4-bit KV cache (`--cache-type-k q4_0 --cache-type-v q4_0`) for long contexts on tight memory |
| `NO_VISION` | `-NoVision` | `0` | Skip downloading/loading the vision projector (`mmproj`) |
| `MMPROJ_QUANT` | `-MmprojQuant` | `Q8_0` | Vision projector quant: `Q8_0` (0.63 GB) or `BF16` (0.93 GB) |
| `MMPROJ_CPU` | `-MmprojCpu` | `0` | Keep vision projector in system RAM (`--no-mmproj-offload`) to save VRAM |
| `IMAGE_MAX_TOKENS` | `-ImageMaxTokens` | `1024` | Max vision tokens per image (`0` = uncapped for small-text OCR) |
| `PRISM_RELEASE` | `$env:PRISM_RELEASE` | `prism-b12178-03ec600` | Pinned PrismML `llama.cpp` release tag (or `latest`) |
| `BUILD_FROM_SOURCE` | *(Linux/Mac)* | `0` | Set `1` to compile `PrismML-Eng/llama.cpp` from source |
| `HF_TOKEN` | `$env:HF_TOKEN` | *(unset)* | Optional HuggingFace token |
| `HF_HUB_OFFLINE` | `$env:HF_HUB_OFFLINE` | `0` | Set `1` for airgapped machines with pre-cached models |

### Examples

```bash
# Full 262K context with 4-bit KV cache
CONTEXT_SIZE=262144 KV4=1 bash start.sh ptq1-mtp

# Fast non-thinking instruct mode on custom port
MODE=instruct PORT=9090 bash start.sh pq2-mtp

# Text-only (skip 0.63 GB vision projector) on tight VRAM
NO_VISION=1 bash start.sh ptq1-mtp

# Force compiling PrismML llama.cpp from source
BUILD_FROM_SOURCE=1 bash start.sh ptq1-mtp
```

---

## API & Vision Usage

### Chat Completions (OpenAI-compatible)

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bonsai-2.5",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant"},
      {"role": "user", "content": "Write a Python function to merge two sorted lists."}
    ],
    "max_tokens": 2048
  }'
```

> **Tip on `max_tokens` and reasoning effort:** Bonsai 2.5 thinks before answering (default effort `xhigh`). Give it a generous `max_tokens` (e.g. `2048`–`16384`) in thinking mode so it doesn't stop mid-thought, or start with `MODE=instruct` for immediate non-thinking replies.

### Verify MTP Speculative Decoding

Check `timings` in any `/v1/chat/completions` response — when MTP is active, `draft_n` and `draft_n_accepted` will be > 0.

### Vision (Images & Screenshots)

Vision is enabled out of the box via `Ternary-Bonsai-2.5-27B-mmproj-Q8_0.gguf`.
- **Web UI:** Click `+` in the message box at `http://localhost:8080` to attach images.
- **API:** Pass standard OpenAI `image_url` content parts (`data:image/png;base64,...`).

---

## Reference Benchmarks (from PrismML Model Card)

| Benchmark Category | Qwen3.8-27B FP16 (53.8 GB) | Bonsai 2 27B (5.93 GB) | **Bonsai 2.5 27B (5.93 GB)** |
| --- | ---: | ---: | ---: |
| **Agentic Tool Calling** (5-bench avg: τ²/τ³-Bench, BFCL v3/v4, AppWorld) | 77.7 | 67.0 | **77.2** (99.4% of FP16) |
| **Agentic Coding** (3-bench avg: SWE-bench Verified, Terminal-Bench 2.1, DeepSWE) | 60.5 | 37.9 | **54.2** (90% of FP16) |
| **General Capability** (16 benchmarks across 5 categories) | 84.3 | 81.6 | **82.1** (97.4% of FP16) |

---

## Cache Layout

All downloaded binaries and weights live under `~/.bonsai25/` (configurable via `BONSAI25_DIR`):

```
~/.bonsai25/
├── bin/<release>-<backend>/   # Prebuilt PrismML llama.cpp binaries
├── llama.cpp/                 # Source build (only if needed / BUILD_FROM_SOURCE=1)
├── models/                    # Downloaded GGUF weights + mmproj (+ mlx/ on Apple Silicon)
└── llama-server.pid           # Running server PID (used by stop.sh / stop.ps1)
```

---

## Validation

```bash
# Linux / macOS validation suite (syntax, Bash 3.2 compat, cross-platform dry-run matrix)
bash test-start.sh

# Windows PowerShell validation suite
powershell -ExecutionPolicy Bypass -File test-start.ps1
```

---

## License

Runner scripts: MIT. Model weights ([Ternary Bonsai 2.5 27B](https://huggingface.co/collections/prism-ml/bonsai-25-27b)): Apache 2.0 by Prism ML.
