# Hardware Sizing, KV Cache & Theoretical Speed Guide — Ternary Bonsai 2.5 27B

Physics-backed reference for **Ternary Bonsai 2.5 27B** across desktop **NVIDIA RTX 30 / 40 / 50 series**, **gaming laptops**, **Apple Silicon MacBooks**, and **iGPU / workstation** hardware.

All model sizes and KV formulas below are extracted directly from the published `prism-ml/Ternary-Bonsai-2.5-27B-GGUF` headers (`qwen35` architecture) and calibrated against real measured points marked with **★** (PrismML model card + our controlled Windows Radeon 890M benchmarks).

---

## 1. Exact Model & Memory Accounting

### Checkpoint Footprints

| Packing | File Size (GiB / GB) | Active Weight Read / Token\* | MTP Draft Layer (`blk.64`) | Best Backend |
| --- | ---: | ---: | ---: | --- |
| **`PTQ1_0-mtp`** | **5.81 GiB** (6.23 GB) | **5.705 GB** | 0.239 GB (+0.278 GB shared LM head) | NVIDIA CUDA, AMD ROCm/HIP, tight-VRAM GPUs |
| **`PQ2_0-mtp`** | **6.98 GiB** (7.49 GB) | **6.904 GB** | 0.239 GB (+0.338 GB shared LM head) | Apple Silicon Metal, Vulkan, CPU |
| **`Q2_0-mtp`** | **7.37 GiB** (7.91 GB) | ~7.30 GB | 0.239 GB | Upstream stock `llama.cpp` (`b11556+`) |
| **Vision (`mmproj-Q8_0`)** | **0.60 GiB** (0.63 GB) | *(prefill only, on images)* | — | Optional (`NO_VISION=1` skips; `MMPROJ_CPU=1` keeps in RAM) |

\* `token_embd.weight` is indexed by 1 row per token rather than streamed, so active target weight traffic per decode step is `target_weights − token_embd`.

### Fixed Overhead (Per Server)
- **GDN linear-attention recurrent state** (48 of 64 layers are linear/SSM): **~0.15 GiB per slot (`-np`)** — constant, does **not** grow with context length.
- **Runtime & compute scratch buffers** (CUDA / Metal / Vulkan): **~0.65 GiB** (plus ~0.5–1.0 GiB OS/desktop VRAM headroom on display GPUs).

### Exact KV Cache Formula (Hybrid Attention)

Bonsai 2.5 27B uses hybrid attention (`block_count = 64` language layers, `full_attention_interval = 4`):
- **Only 16 layers** allocate a KV cache (`4` KV heads × `256` head dim × K & V = `32,768` elements/token across all 16 layers; plus 1 layer in the MTP head when drafting).
- **48 layers** are GDN linear-attention with fixed state (zero context growth).

| KV Cache Type | Flag | Bytes / Token | Per 1K Tokens | 8K | 16K | 32K (default) | 64K | 128K | 262K (max) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **FP16** *(default)* | *(none)* | 64 KiB | **64 MiB** | 0.50 GiB | 1.00 GiB | **2.00 GiB** | 4.00 GiB | 8.00 GiB | 16.00 GiB |
| **Q8_0** | `-ctk q8_0 -ctv q8_0` | 34 KiB | **34 MiB** | 0.27 GiB | 0.53 GiB | **1.06 GiB** | 2.13 GiB | 4.25 GiB | 8.50 GiB |
| **Q4_0** (`KV4=1`) | `KV4=1` / `-Kv4` | 18 KiB | **18 MiB** | 0.14 GiB | 0.28 GiB | **0.56 GiB** | 1.13 GiB | 2.25 GiB | 4.50 GiB |

**Total VRAM formula (`-np 1`):**

```text
Total VRAM ≈ Model_GiB + KV_GiB(context, kv_dtype) + 0.80 GiB (GDN + runtime) + 0.60 GiB (if vision on GPU)
```

Example: On an **8 GB VRAM** card with `PTQ1_0-mtp` (5.81 GiB) + `MMPROJ_CPU=1` (0 GiB VRAM) + `KV4=1` at 32K (0.56 GiB) + 0.80 GiB overhead = **~7.17 GiB** — fits cleanly without spilling to system RAM.

> **Concurrency (`PARALLEL` / `-np`):** KV cache and GDN state scale linearly with `-np`. Always keep `PARALLEL=1` (the `bonsai-runner2` default) on 8–12 GB GPUs.

---

## 2. How Decode Speed Is Calculated

Single-user (`c1`) token generation is **memory-bandwidth bound**:

```text
Theoretical Ceiling (no MTP) = Memory_Bandwidth (GB/s) ÷ Active_Weight_Read (GB/token)
                               = BW ÷ 5.705  (for PTQ1_0)
                               = BW ÷ 6.904  (for PQ2_0)
```

Measured kernel efficiency vs. spec bandwidth on `prism-b12178-03ec600`:
- **NVIDIA CUDA (`PTQ1_0`):** plain decode achieves **~55–63%** of spec bandwidth (★ RTX 4090: `112 / 177 = 63%`; ★ RTX 5090: `174 / 314 = 55%`). Built-in **MTP (`n-max=3, p-min=0.1`)** adds **~1.65–1.83×** decode speedup (★ 4090: `112 → 204 tok/s`; ★ 5090: `174 → 305 tok/s`).
- **Apple Silicon Metal (`PQ2_0`):** plain decode achieves **~58–68%** of spec bandwidth (★ M4 Pro: `22.9 / 39.5 = 58%`; ★ M5 Pro: `30.2 tok/s`). Built-in **MTP (`n-max=1, p-min=0.6`)** adds **~1.10–1.27×** (★ M4 Pro: `22.9 → 25.3–29.2 tok/s`).
- **AMD Vulkan (`PQ2_0`):** plain decode achieves **~64%** of spec bandwidth (★ Radeon 890M: `8.32 / 12.98 = 64%`). Built-in **MTP (`n-max=1, p-min=0.1`)** adds **~1.63×** (★ Radeon 890M: `8.32 → 13.56 tok/s`, 91.8% acceptance; `PTQ1_0 + n-max=2` reaches `14.45 tok/s` with slower prefill).

> **Long-context slowdown:** At short context (0–8K), KV reads are negligible. At **128K FP16 KV (8.0 GiB)**, every token reads `5.7 + 8.0 = 13.7 GB`, cutting decode roughly in half compared to short context. Enabling **`KV4=1`** shrinks 128K KV reads from `8.0 GiB → 2.25 GiB`, preserving much higher decode speed at long contexts.

---

## 3. Desktop NVIDIA GPUs (RTX 30 / 40 / 50 & Workstation)

All CUDA rows assume **`ptq1-mtp`** (5.81 GiB) and `-np 1`. Cards with **≤ 8 GB VRAM** assume `MMPROJ_CPU=1` (auto-applied by `bonsai-runner2`). **★ = measured on hardware.**

| GPU | VRAM | Spec BW | Ceiling (no MTP) | Est. Plain (`PTQ1_0`) | Est. +MTP (`n=3`) | Max Ctx (FP16 KV) | Max Ctx (`KV4=1`) | Auto / Recommended Setup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **RTX 3060 12 GB** | 12 GB | 360 GB/s | 63 t/s | ~38 t/s | **~65 t/s** | 64K | 128K+ | `ptq1-mtp`, 32K–64K |
| **RTX 3060 Ti 8 GB** | 8 GB | 448 GB/s | 79 t/s | ~47 t/s | **~81 t/s** | 12K | **48K** | Auto: `ptq1-mtp`, `KV4=1`, `MMPROJ_CPU=1` |
| **RTX 3070 / 3070 Ti 8 GB** | 8 GB | 448–608 GB/s | 79–107 t/s | ~47–64 t/s | **~81–110 t/s** | 12K | **48K** | Auto: `ptq1-mtp`, `KV4=1`, `MMPROJ_CPU=1` |
| **RTX 3080 10 GB** | 10 GB | 760 GB/s | 133 t/s | ~80 t/s | **~138 t/s** | 32K | 128K+ | `ptq1-mtp`, `-np 1` (~7.8 GB VRAM) |
| **RTX 3080 12 GB / 3080 Ti** | 12 GB | 912 GB/s | 160 t/s | ~96 t/s | **~165 t/s** | 64K | 128K+ | `ptq1-mtp`, 32K–64K |
| **RTX 3090 / 3090 Ti** | 24 GB | 936–1008 GB/s | 164–177 t/s | ~98–106 t/s | **~169–182 t/s** | 128K+ | **262K** | `ptq1-mtp`, up to full 262K (`KV4=1`) |
| **RTX 4060 8 GB** | 8 GB | 272 GB/s | 48 t/s | ~29 t/s | **~50 t/s** | 12K | **48K** | Auto: `ptq1-mtp`, `KV4=1`, `MMPROJ_CPU=1` |
| **RTX 4060 Ti 16 GB** | 16 GB | 288 GB/s | 50 t/s | ~30 t/s | **~52 t/s** | 112K | **262K** | `ptq1-mtp`, 64K–128K+ |
| **RTX 4070 / 4070 Super** | 12 GB | 504 GB/s | 88 t/s | ~53 t/s | **~91 t/s** | 64K | 128K+ | `ptq1-mtp`, 32K–64K |
| **RTX 4070 Ti Super** | 16 GB | 672 GB/s | 118 t/s | ~71 t/s | **~122 t/s** | 112K | **262K** | `ptq1-mtp`, 64K–128K+ |
| **RTX 4080 / 4080 Super** | 16 GB | 717–736 GB/s | 126–129 t/s | ~76–77 t/s | **~130–132 t/s** | 112K | **262K** | `ptq1-mtp`, 64K–128K+ |
| **RTX 4090 24 GB ★** | 24 GB | 1,008 GB/s | 177 t/s | **112 t/s ★** | **204–215 t/s ★** | 128K+ | **262K** | `ptq1-mtp`, CUDA 12.4+, full 262K (`KV4=1`) |
| **RTX 5060 8 GB** | 8 GB | 448 GB/s | 79 t/s | ~47 t/s | **~81 t/s** | 12K | **48K** | Auto: `ptq1-mtp`, `KV4=1`, `MMPROJ_CPU=1` |
| **RTX 5060 Ti 16 GB** | 16 GB | 448 GB/s | 79 t/s | ~47 t/s | **~81 t/s** | 112K | **262K** | `ptq1-mtp`, CUDA 12.8/13.3 |
| **RTX 5070 12 GB** | 12 GB | 672 GB/s | 118 t/s | ~71 t/s | **~122 t/s** | 64K | 128K+ | `ptq1-mtp`, CUDA 12.8/13.3 |
| **RTX 5070 Ti 16 GB** | 16 GB | 896 GB/s | 157 t/s | ~94 t/s | **~162 t/s** | 112K | **262K** | `ptq1-mtp`, CUDA 12.8/13.3 |
| **RTX 5080 16 GB** | 16 GB | 960 GB/s | 168 t/s | ~101 t/s | **~174 t/s** | 112K | **262K** | `ptq1-mtp`, CUDA 12.8/13.3 |
| **RTX 5090 32 GB ★** | 32 GB | 1,792 GB/s | 314 t/s | **174 t/s ★** | **305–312 t/s ★** | **262K** | **262K** | `ptq1-mtp`, CUDA 12.8/13.3, full 262K FP16 |
| **DGX Spark (GB10)** | 128 GB unified | 273 GB/s | 48 t/s | ~29 t/s | **~50 t/s** | **262K** | **262K** | Auto builds from source (ARM64 CUDA), `ptq1-mtp` |
| **RTX PRO 6000 96 GB ★** | 96 GB | 1,792 GB/s | 314 t/s | **158 t/s ★** | **277–283 t/s ★** | **262K** | **262K** | `ptq1-mtp`, multi-slot (`PARALLEL=4`) |

> **Blackwell note (RTX 50-series / RTX PRO 6000):** Use a CUDA 12.8 or 13.3 build (`start.sh` and `start.ps1` select this automatically from your driver version).

---

## 4. Gaming Laptops & Integrated-GPU Laptops

Mobile GPUs run slightly lower sustained clocks than desktop parts (~58% effective BW vs ~60%). **★ = measured.**

| Laptop GPU / APU | VRAM / RAM | Spec BW | Packing | Ceiling (no MTP) | Est. Plain | Est. +MTP | Max Ctx (FP16) | Max Ctx (`KV4=1`) |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| **RTX 3060 Laptop** | 6 GB | 336 GB/s | `ptq1-mtp` | 59 t/s | *(partial offload)* | ~15–25 t/s | Split GPU/CPU | Split (`-ngl 45`, `NO_VISION=1`) |
| **RTX 3070 / 3070 Ti Laptop** | 8 GB | 448 GB/s | `ptq1-mtp` | 79 t/s | ~46 t/s | **~78 t/s** | 12K | **48K** (`MMPROJ_CPU=1`) |
| **RTX 3080 Laptop (16 GB)** | 16 GB | 448 GB/s | `ptq1-mtp` | 79 t/s | ~46 t/s | **~78 t/s** | 112K | **262K** |
| **RTX 4060 / 4070 Laptop** | 8 GB | 256 GB/s | `ptq1-mtp` | 45 t/s | ~26 t/s | **~44 t/s** | 12K | **48K** (`MMPROJ_CPU=1`) |
| **RTX 4080 Laptop** | 12 GB | 432 GB/s | `ptq1-mtp` | 76 t/s | ~44 t/s | **~75 t/s** | 64K | 128K+ |
| **RTX 4090 Laptop** | 16 GB | 576 GB/s | `ptq1-mtp` | 101 t/s | ~59 t/s | **~100 t/s** | 128K+ | **262K** |
| **RTX 5060 / 5070 Laptop** | 8 GB | 384 GB/s | `ptq1-mtp` | 67 t/s | ~39 t/s | **~66 t/s** | 12K | **48K** (`MMPROJ_CPU=1`) |
| **RTX 5070 Ti Laptop** | 12 GB | 672 GB/s | `ptq1-mtp` | 118 t/s | ~68 t/s | **~116 t/s** | 64K | 128K+ |
| **RTX 5080 Laptop** | 16 GB | 896 GB/s | `ptq1-mtp` | 157 t/s | ~91 t/s | **~155 t/s** | 128K+ | **262K** |
| **RTX 5090 Laptop** | 24 GB | 896 GB/s | `ptq1-mtp` | 157 t/s | ~91 t/s | **~155 t/s** | **262K** | **262K** |
| **AMD Radeon 890M (DDR5-5600) ★** | 32–96 GB UMA | 89.6 GB/s | `pq2-mtp` | 13.0 t/s | **8.3 t/s ★** | **13.6 t/s ★** (`n=1`) | **262K** (on 48+ GB) | **262K** |
| **AMD Radeon 8060S (Strix Halo)** | 64–128 GB UMA | 256 GB/s | `pq2-mtp` | 37.1 t/s | ~23 t/s | **~37 t/s** | **262K** | **262K** |
| **Intel Core Ultra iGPU (SYCL) ★** | 32 GB UMA | ~120 GB/s | `ptq1-mtp` | 21.0 t/s | **11.1 t/s ★** | **23.1 t/s ★** (`n=8`) | 12K–32K | 64K+ |

> **6 GB VRAM laptops (e.g. RTX 3060 Laptop / RTX 4050 Laptop):** `PTQ1_0-mtp` is 5.81 GiB on disk, so full offload won't fit alongside KV cache. Use `NO_VISION=1 KV4=1 NGL=45 CONTEXT_SIZE=16384` to offload ~70% of layers to GPU and spill the rest to DDR5 RAM.

---

## 5. Apple Silicon MacBooks & Desktops (Metal)

macOS reserves ~75% of unified memory for Metal GPU wired allocations by default (`iogpu.wired_limit_mb`). All Metal rows use **`pq2-mtp`** (6.98 GiB — PrismML's benchmarked Metal packing; 8 GB Macs fall back to `ptq1-mtp`). **★ = measured by PrismML.**

| Mac / Chip | Unified RAM (Default GPU Limit) | Spec BW | Ceiling (no MTP) | Est. Plain (`PQ2_0`) | Est. +MTP (`n=1, p=0.6`) | Max Ctx (FP16 KV) | Max Ctx (`KV4=1`) | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **M1 / M2 / M3 Air (8 GB)** | 8 GB (~6 GB GPU) | 100 GB/s | 14.5 t/s | *(swaps)* | — | Not rec. | ~4K–8K (`NO_VISION=1`) | Very tight; use `ptq1` + `NO_VISION=1` + `KV4=1` |
| **M1 / M2 / M3 Air (16 GB)** | 16 GB (~12 GB GPU) | 100 GB/s | 14.5 t/s | ~8.4 t/s | **~9.7 t/s** | 48K | 128K+ | Works cleanly; use `REASONING_EFFORT=medium` |
| **M4 Air / Base (16–24 GB)** | 16–24 GB (12–18 GB GPU) | 120 GB/s | 17.4 t/s | ~10.1 t/s | **~11.6 t/s** | 48K–128K | 128K–262K | Smooth chat in `medium` / `instruct` |
| **M3 Pro (18–36 GB)** | 18–36 GB (13.5–27 GB GPU) | 150 GB/s | 21.7 t/s | ~12.6 t/s | **~14.5 t/s** | 64K–262K | **262K** | Good balance of quiet fan + speed |
| **M1 Pro / M2 Pro (16–32 GB)** | 16–32 GB (12–24 GB GPU) | 200 GB/s | 29.0 t/s | ~16.8 t/s | **~19.3 t/s** | 48K–128K+ | **262K** | Comfortable interactive coding |
| **M4 Pro (24–48 GB) ★** | 24–48 GB (18–36 GB GPU) | 273 GB/s | 39.5 t/s | **22.9 t/s ★** | **25.3–29.2 t/s ★** | 128K–262K | **262K** | Great daily driver |
| **M5 Pro (24–48 GB) ★** | 24–48 GB (18–36 GB GPU) | ~307+ GB/s | 44.5+ t/s | **30.2 t/s ★** | **~34–38 t/s** | 128K–262K | **262K** | Faster on `llama.cpp` Metal than MLX (21.7 t/s) |
| **M1 Max / M2 Max (32–64 GB)** | 32–64 GB (24–48 GB GPU) | 400 GB/s | 57.9 t/s | ~33.6 t/s | **~38.6 t/s** | 128K–262K | **262K** | Fast full-repo 262K agentic coding |
| **M3 Max (36–128 GB)** | 36–128 GB (27–96 GB GPU) | 400 GB/s | 57.9 t/s | ~33.6 t/s | **~38.6 t/s** | **262K** | **262K** | Full 262K in FP16 KV |
| **M4 Max (36–128 GB)** | 36–128 GB (27–96 GB GPU) | 546 GB/s | 79.1 t/s | ~45.9 t/s | **~52.8 t/s** | **262K** | **262K** | Laptop powerhouse |
| **M2 / M3 Ultra (128+ GB)** | 128–512 GB (96+ GB GPU) | 800 GB/s | 115.9 t/s | ~67.2 t/s | **~77.3 t/s** | **262K** | **262K** | Supports multi-slot (`PARALLEL=4`) |

> **Apple Silicon note:** Base M-series chips (`100–120 GB/s`) get smaller gains from MTP than Pro/Max/Ultra. If MTP feels slower on a base M1/M2, compare with `MTP=off bash start.sh pq2-mtp`.

---

## 6. Quick Copy-Paste Commands by Hardware Tier

| Hardware Tier | Linux / macOS | Windows PowerShell |
| --- | --- | --- |
| **Any machine (auto-tuned)** | `bash start.sh` | `powershell -ExecutionPolicy Bypass -File start.ps1` |
| **8 GB VRAM GPU (3070/4060/5060/Laptop)** | Auto-tuned (`ptq1-mtp`, 16K, `KV4=1`, `MMPROJ_CPU=1`) | Auto-tuned (`ptq1-mtp`, 16K, `-Kv4`, `-MmprojCpu`) |
| **12–32 GB NVIDIA GPU (long context)** | `CONTEXT_SIZE=131072 KV4=1 bash start.sh ptq1-mtp` | `powershell -ExecutionPolicy Bypass -File start.ps1 -Variant ptq1-mtp -ContextSize 131072 -Kv4` |
| **iGPU / Base Mac (fast responsive chat)** | `REASONING_EFFORT=medium bash start.sh` | `powershell -ExecutionPolicy Bypass -File start.ps1 -ReasoningEffort medium` |
| **Zero-thinking instant chat** | `MODE=instruct bash start.sh` | `powershell -ExecutionPolicy Bypass -File start.ps1 -Mode instruct` |
| **6 GB VRAM laptop (partial offload)** | `NO_VISION=1 KV4=1 NGL=45 CONTEXT_SIZE=16384 bash start.sh ptq1-mtp` | `powershell -ExecutionPolicy Bypass -File start.ps1 -Variant ptq1-mtp -NoVision -Kv4 -Ngl 45 -ContextSize 16384` |
