# 🌳 Bonsai 2.5 27B Runner (`bonsai-runner2`)

Run **[Ternary Bonsai 2.5 27B](https://huggingface.co/collections/prism-ml/bonsai-25-27b)** locally on **macOS (Metal & MLX), Linux, or Windows** with **one command**.

> **~9× smaller than FP16 (5.9–7.5 GB)** · **FP16-level agentic tool calling** (77.2 vs 77.7) · **90% of FP16 agentic coding** (SWE-bench Verified 75.6, Terminal-Bench 2.1 60.1) · **262K context** · **Vision + Built-in MTP speculative decoding** · **Apache 2.0**

No cloud API. No subscription. No compiler or Python needed for GGUF serving — downloads the official prebuilt PrismML `llama.cpp` fork binary (with automatic source-build fallback on Linux/macOS when needed), pulls the GGUF weights from HuggingFace, and launches an OpenAI-compatible server with built-in Web UI. On Apple Silicon Macs, `bash start.sh mlx` also auto-provisions Python 3.11 + native `mlx-vlm` (`0.7.8`) and launches an OpenAI & Anthropic (`/v1/messages`) compatible MLX server.

---

## Quickstart

### macOS & Linux (plus WSL2 & Git Bash)

```bash
git clone https://github.com/Mikehutu/bonsai-runner2
cd bonsai-runner2

# One command: auto-detects GPU/VRAM/RAM, picks the optimal Bonsai 2.5 packing + safe memory settings, and starts!
bash start.sh

# In a second terminal, verify chat + native tool calling + measure tok/s:
bash test-model.sh

# Optional: interactive menu, dry-run preview, or pick a specific variant directly:
bash start.sh --choose
bash start.sh --dry-run   # preview detected hardware & flags without downloading
bash start.sh ptq1-mtp    # 6.23 GB — fastest on NVIDIA CUDA / ROCm & smallest MTP build
bash start.sh pq2-mtp     # 7.49 GB — benchmarked on Apple Silicon Metal / CPU / Vulkan
bash start.sh q2-mtp      # 7.91 GB — stock llama.cpp b11556+ compatible
bash start.sh mlx         # ~8.6 GB — Apple Silicon MLX OpenAI/Anthropic server (macOS arm64)
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

# Optional: interactive menu, dry-run preview, or explicit variant/backend:
powershell -ExecutionPolicy Bypass -File start.ps1 -Choose
powershell -ExecutionPolicy Bypass -File start.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File start.ps1 -Variant ptq1-mtp
powershell -ExecutionPolicy Bypass -File stop.ps1
```

> **Git Bash on Windows:** Running `bash start.sh` or `bash stop.sh` inside Git Bash automatically delegates to `start.ps1` / `stop.ps1` via PowerShell.

Once `llama-server` finishes loading, the built-in **llama.cpp Chat UI** automatically opens in your browser at **`http://localhost:8080`** (skip with `-NoBrowser` / `--no-browser` / `NO_BROWSER=1`), and the OpenAI-compatible API is live at `http://localhost:8080/v1/chat/completions`.

### How Auto-Selection Works

Running `start.sh` or `start.ps1` with no arguments automatically inspects your OS, CPU architecture, GPU vendor, VRAM, and system RAM:

- **NVIDIA CUDA (10+ GB VRAM or unified memory like DGX Spark) / AMD ROCm & HIP** → picks **`ptq1-mtp`** (6.23 GB, fastest NVIDIA decode + built-in MTP `n-max=3, p-min=0.1`), 32K context.
- **NVIDIA CUDA (8 GB VRAM, e.g. RTX 4060 / 3070 / 5060)** → picks **`ptq1-mtp`** (6.23 GB) + auto-tunes **16K context**, **4-bit KV cache (`KV4=1`)**, and keeps the vision projector in system RAM (`--no-mmproj-offload`) so all 64 layers fit in VRAM without OOM.
- **NVIDIA CUDA (≤ 6 GB VRAM laptop, e.g. RTX 3060 6GB / RTX 4050)** → picks **`ptq1-mtp`** + **`-ngl auto`** (`llama-server --fit on` offloads the exact max layers that fit in free VRAM and spills the rest to RAM) + **16K context**, `KV4=1`, and CPU vision offload.
- **Apple Silicon Mac (24+ GB RAM)** → picks **`pq2-mtp`** (7.49 GB, benchmarked on Metal + built-in MTP `n-max=1, p-min=0.6`), 32K context.
- **Apple Silicon Mac (16–18 GB RAM)** → picks **`pq2-mtp`** (7.49 GB) + **16K context** (leaves comfortable macOS Metal wired memory headroom alongside desktop apps).
- **Apple Silicon Mac (8 GB RAM)** → picks **`ptq1-mtp`** (6.23 GB) + auto-tunes **8K context**, `KV4=1`, and CPU vision offload.
- **Linux / Windows Vulkan or CPU** → picks **`pq2-mtp`** (7.49 GB; 32K ctx on 24+ GB RAM, 16K ctx on 16 GB RAM), or **`ptq1-mtp`** (6.23 GB) + 8K context + `KV4=1` on <12 GB RAM machines.

> 📊 **Expected speeds & KV sizing for your exact GPU/Mac/laptop:** see **[HARDWARE-GUIDE.md](HARDWARE-GUIDE.md)** (exact GGUF-derived KV tables + theoretical & measured tok/s for RTX 30/40/50 desktop GPUs, gaming laptops, Apple Silicon MacBooks, and iGPUs).

---

## Variants

All GGUF files come from [`prism-ml/Ternary-Bonsai-2.5-27B-GGUF`](https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF) and represent the exact same ternary Qwen3.8-27B model weights with different packing/speed trade-offs:

| Variant | File / Repo | Size | Built-in MTP Head | Recommended For |
| --- | --- | ---: | :---: | --- |
| **`auto`** *(default)* | auto-selected | 6.2–7.5 GB | Yes | Everyone — picks `ptq1-mtp` on CUDA/ROCm/HIP or tight RAM (<12 GB), `pq2-mtp` on Apple Metal/CPU/Vulkan |
| **`ptq1-mtp`** | `Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf` | **6.23 GB** | Yes | **NVIDIA GPUs** (fastest decode, 1.76 bpw) and 6–8 GB VRAM / tight-RAM setups |
| **`pq2-mtp`** | `Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf` | **7.49 GB** | Yes | **Apple Silicon Metal** (benchmarked packing), CPU, Vulkan, fast prefill |
| **`q2-mtp`** | `Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf` | **7.91 GB** | Yes | Compatibility with upstream stock `llama.cpp` (`b11556+`) |
| **`ptq1`** | `Ternary-Bonsai-2.5-27B-PTQ1_0.gguf` | **5.99 GB** | No | Absolute smallest footprint without MTP head |
| **`pq2`** | `Ternary-Bonsai-2.5-27B-PQ2_0.gguf` | **7.25 GB** | No | PQ2_0 without MTP head |
| **`q2`** | `Ternary-Bonsai-2.5-27B-Q2_0.gguf` | **7.67 GB** | No | Stock `llama.cpp` `b11556+` without MTP head |
| **`mlx`** *(macOS arm64)* | [`prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit`](https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-mlx-2bit) | **~8.6 GB** | Sidecar | Apple Silicon native `mlx-vlm` (`0.7.8`) server — exposes OpenAI `/v1/chat/completions` + Anthropic `/v1/messages` (`pq2-mtp` on Metal `llama-server` is faster and includes Web UI) |

> **Built-in MTP speculative decoding:** The `-mtp` GGUF files embed a ~0.24 GB multi-token prediction draft head inside the same GGUF — no separate drafter file or conversion step needed, and prompt caching stays enabled. The head is inert when drafting is off, so `-mtp` files are drop-in replacements for the base files.

---

## Apple Silicon Mac: Metal (`llama.cpp`) vs MLX

On Apple Silicon Macs (M1 / M2 / M3 / M4 / M5), `bonsai-runner2` supports **both** runtimes out of the box:

1. **Recommended default — Metal `llama-server` (`bash start.sh`):**
   - Zero Python dependencies — downloads the prebuilt macOS `arm64` binary, clears Gatekeeper quarantine (`xattr -cr`), ad-hoc signs all binaries/dylibs, and starts `llama-server` with built-in Chat Web UI + OpenAI API + MTP speculative decoding (~30+ tok/s on M5 Pro, ~25–29 tok/s on M4 Pro).
   - Includes automatic `GGML_METAL_TENSOR_DISABLE=1` detection for Apple M5 Macs on macOS 26.2–26.4.
2. **Native Python MLX (`bash start.sh mlx`):**
   - Automatically avoids macOS's old system Python 3.9 (`/usr/bin/python3`) by finding Homebrew Python 3.11+ or bootstrapping standalone `uv` + Python 3.11 inside `~/.bonsai25/uv-bin`.
   - Installs PrismML's verified native Hadamard VLM stack (`mlx==0.32.3`, `mlx-vlm==0.7.8`, `mlx-lm==0.32.0`, `transformers==5.19.0`).
   - Launches `mlx_vlm.server` on `http://localhost:8080` with both **OpenAI** (`/v1/chat/completions`, `/v1/responses`) and **Anthropic** (`/v1/messages` — works directly with Claude Code!) endpoints, or run a quick one-shot prompt via `bash start.sh mlx -p "Your prompt"`.

---

## Platform Support

One repo covers every desktop/server platform:

| Platform | Script | Auto-Detected Backend | Runtime Source | MTP Default |
| --- | --- | --- | --- | --- |
| **macOS Apple Silicon** (M1–M5) | `start.sh` | **Metal** (`arm64`) | Prebuilt PrismML macOS `arm64` archive (auto-clears Gatekeeper quarantine + ad-hoc signs) | **ON** (`n-max=1, p-min=0.6`) |
| **macOS Apple Silicon (MLX)** | `start.sh mlx` | **MLX** (`arm64`) | Auto-provisioned Python 3.11 + `mlx-vlm==0.7.8` (`mlx_vlm.server`) | Native MLX |
| **macOS Intel** | `start.sh` | **CPU** (`x64`) | Prebuilt PrismML macOS `x64` archive | OFF (`MTP=on` to force) |
| **Linux x86_64 + NVIDIA** | `start.sh` | **CUDA** (12.4 / 12.8 / 13.3 auto-matched to driver) | Prebuilt PrismML Linux CUDA archive | **ON** (`n-max=3, p-min=0.1`) |
| **Linux ARM64 + NVIDIA** (e.g. DGX Spark) | `start.sh` | **CUDA** (`aarch64`) | Auto-compiled from `PrismML-Eng/llama.cpp` (`-DGGML_CUDA=ON`) | **ON** (`n-max=3, p-min=0.1`) |
| **Linux x86_64 + AMD ROCm** | `start.sh` | **ROCm** | Prebuilt PrismML Ubuntu ROCm 7.2 archive | **ON** (`n-max=3, p-min=0.1`) |
| **Linux + Vulkan GPU** | `start.sh` | **Vulkan** (`x64` / `arm64`) | Prebuilt PrismML Ubuntu Vulkan archive (detects ICDs even without `vulkaninfo`) | **ON** (`n-max=1` PQ2 / `n-max=2` PTQ1, `p-min=0.1`) |
| **Linux / WSL2** | `start.sh` | **CUDA** or **CPU** | Prebuilt PrismML Linux archive + WSL2 browser auto-open | Auto |
| **Windows 10/11 + NVIDIA** | `start.ps1` | **CUDA** (12.4 / 13.3 / arm64 13.4) | Prebuilt PrismML Windows CUDA (+ CPU base overlay on arm64) + bundled `cudart` DLLs | **ON** (`n-max=3, p-min=0.1`) |
| **Windows 10/11 + AMD HIP** | `start.ps1` | **HIP** | Prebuilt PrismML Windows HIP Radeon archive | **ON** (`n-max=3, p-min=0.1`) |
| **Windows 10/11 + AMD/Intel GPU** | `start.ps1` | **Vulkan** | Prebuilt PrismML Windows Vulkan archive (verifies usable GPU device, falls back to CPU) | **ON** (`n-max=1` PQ2 / `n-max=2` PTQ1, `p-min=0.1`) |
| **Windows 10/11 CPU** | `start.ps1` | **CPU** (`x64` / `arm64`) | Prebuilt PrismML Windows CPU archive | OFF (`-Mtp on` to force) |

---

## Configuration

Copy `.env.example` to `.env` (automatically loaded by `start.sh`, `start.ps1`, `test-model.sh`, and `test-model.ps1`), or pass CLI flags / environment variables directly:

| Env Var | `start.sh` Flag | `start.ps1` Flag | Default | Description |
| --- | --- | --- | --- | --- |
| `MODEL_VARIANT` | `[VARIANT]` | `-Variant` | `auto` | `auto`, `ptq1-mtp`, `pq2-mtp`, `q2-mtp`, `ptq1`, `pq2`, `q2`, `mlx` |
| `BACKEND` | `--backend` | `-Backend` | auto | Force `cuda`, `rocm`, `hip` (Win), `vulkan`, `metal` (Mac), or `cpu` |
| `MODE` | `--mode` | `-Mode` | `thinking` | `thinking` (temp 1.0, top-p 0.95, top-k 20, min-p 0) or `instruct` (non-thinking, temp 0.7, presence-penalty 1.5) |
| `REASONING_EFFORT` | `--reasoning-effort` | `-ReasoningEffort` | `default` | `default` (`xhigh`), `xhigh`, or `medium` (shorter, faster thinking) |
| `MTP` | `--mtp` | `-Mtp` | `auto` | Built-in MTP speculative decoding: `auto`, `on`, or `off` |
| `PORT` | `--port` | `-Port` | `8080` | Server port (auto-tries `PORT+1`, `PORT+2` if busy) |
| `HOST` | `--host` | `-HostAddr` | `0.0.0.0` | Bind address |
| `NGL` | `--ngl` | `-Ngl` | `99` | GPU layers to offload (`auto` on ≤6 GB VRAM, `0` on CPU) |
| `CONTEXT_SIZE` | `-c`, `--context-size` | `-ContextSize` | `0` (auto) | Context tokens. `0` maps to safe 8K–32K by RAM/VRAM; max `262144` |
| `PARALLEL` | `--parallel` | `-Parallel` | `1` | Request slots (`-np`). `1` keeps VRAM ~7.8 GB on 8–10 GB GPUs; `0` = auto |
| `KV4` | `--kv4` | `-Kv4` | `0` | Enable 4-bit KV cache (`q4_0` on llama.cpp / `--kv-bits 4` on MLX) |
| `NO_VISION` | `--no-vision` | `-NoVision` | `0` | Skip downloading/loading the vision projector (`--no-mmproj`) |
| `MMPROJ_QUANT` | *(env)* | `-MmprojQuant` | `Q8_0` | Vision projector quant: `Q8_0` (0.63 GB) or `BF16` (0.93 GB) |
| `MMPROJ_CPU` | `--mmproj-cpu` | `-MmprojCpu` | `0` | Keep vision projector in system RAM (`--no-mmproj-offload`) to save VRAM |
| `IMAGE_MAX_TOKENS` | *(env)* | `-ImageMaxTokens` | `1024` | Max vision tokens per image (`0` = uncapped for small-text OCR) |
| `NO_BROWSER` | `--no-browser` | `-NoBrowser` | `0` | Skip auto-opening Web UI in browser |
| `DETACHED` | `--detached`, `-d` | `-Detached` | `0` | Run server in background (`~/.bonsai25/*.log`) |
| `PRISM_RELEASE` | *(env)* | *(env)* | `prism-b12178-03ec600` | Pinned PrismML `llama.cpp` release tag (or `latest`) |
| `BUILD_FROM_SOURCE` | *(env)* | — | `0` | Set `1` to compile `PrismML-Eng/llama.cpp` from source |
| `HF_TOKEN` | *(env)* | *(env)* | *(unset)* | Optional HuggingFace token |
| `HF_HUB_OFFLINE` | *(env)* | *(env)* | `0` | Set `1` for airgapped machines with pre-cached models |

### Examples

```bash
# Full 262K context with 4-bit KV cache
bash start.sh ptq1-mtp -c 262144 --kv4

# Fast medium-effort thinking or instant non-thinking instruct mode
bash start.sh --reasoning-effort medium
bash start.sh pq2-mtp --mode instruct --port 9090

# Text-only (skip 0.63 GB vision projector) on tight VRAM
bash start.sh ptq1-mtp --no-vision

# Apple Silicon MLX server vs one-shot CLI prompt
bash start.sh mlx
bash start.sh mlx -p "Explain ternary quantization in 3 bullet points."
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

> **Tip on `max_tokens` and reasoning effort:** Bonsai 2.5 thinks before answering (default effort `xhigh`). Give it a generous `max_tokens` (e.g. `2048`–`16384`) in thinking mode so it doesn't stop mid-thought, pass `--reasoning-effort medium` for faster everyday replies, or start with `--mode instruct` for immediate non-thinking output. (On `mlx`, pass the model path returned by `curl http://localhost:8080/v1/models` in `"model"`.)

### Vision (Images & Screenshots)

Vision is enabled out of the box via `Ternary-Bonsai-2.5-27B-mmproj-Q8_0.gguf` (and natively in `mlx-vlm` on `mlx`).
- **Web UI (`llama-server`):** Click `+` in the message box at `http://localhost:8080` to attach images.
- **API:** Pass standard OpenAI `image_url` content parts (`data:image/png;base64,...`).

---

## Troubleshooting

- **macOS Gatekeeper blocks `llama-server`:** `start.sh` automatically clears quarantine (`xattr -cr`) and ad-hoc signs all binaries. On managed corporate Macs that restrict ad-hoc binaries, either click **Allow Anyway** under *System Settings → Privacy & Security*, or compile locally with `xcode-select --install && brew install cmake && BUILD_FROM_SOURCE=1 bash start.sh`.
- **Apple M5 Mac Metal shader error on macOS 26.2–26.4:** `start.sh` automatically sets `GGML_METAL_TENSOR_DISABLE=1` when it detects an M5 chip on macOS 26.2–26.4 to bypass the OS Metal header bug while keeping full Metal GPU speed. You can also set `GGML_METAL_TENSOR_DISABLE=1` manually if needed.
- **Windows `llama-server.exe` exits immediately on fresh Windows installs:** Install the official [Microsoft Visual C++ 2015–2022 Redistributable (x64 / ARM64)](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) (`vcruntime140.dll`).
- **Out of memory (VRAM/RAM) at startup:** Run with `--kv4 --no-vision -c 8192` (or `-Kv4 -NoVision -ContextSize 8192` on Windows). On 4–6 GB VRAM GPUs, `start.sh` and `start.ps1` automatically set `-ngl auto` so layers split safely across GPU and system RAM.

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

```text
~/.bonsai25/
├── bin/<release>-<backend>/   # Prebuilt PrismML llama.cpp binaries
├── llama.cpp/                 # Source build (only if needed / BUILD_FROM_SOURCE=1)
├── venv-mlx/                  # Python 3.11 + mlx-vlm 0.7.8 venv (macOS 'mlx' variant only)
├── models/                    # Downloaded GGUF weights + mmproj (+ mlx/ on Apple Silicon)
└── llama-server.pid           # Running server PID (used by stop.sh / stop.ps1)
```

---

## Validation

```bash
# Linux / macOS validation suite (syntax, LF/ASCII checks, Bash 3.2 audit, macOS Metal/MLX simulation, URL checks)
bash test-start.sh

# Windows PowerShell validation suite (PowerShell 5.1 & pwsh 7+)
powershell -ExecutionPolicy Bypass -File test-start.ps1
```

---

## License

Runner scripts: MIT. Model weights ([Ternary Bonsai 2.5 27B](https://huggingface.co/collections/prism-ml/bonsai-25-27b)): Apache 2.0 by Prism ML.
