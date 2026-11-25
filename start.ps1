# start.ps1 — Ternary Bonsai 2.5 27B one-click runner for Windows (native PowerShell)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File start.ps1
#   powershell -ExecutionPolicy Bypass -File start.ps1 -Variant ptq1-mtp
#   powershell -ExecutionPolicy Bypass -File start.ps1 -Variant pq2-mtp -ContextSize 65536
#   powershell -ExecutionPolicy Bypass -File start.ps1 -Backend cpu -NoVision
#
# Works on Windows 10/11 with built-in PowerShell 5.1 or PowerShell 7+ and curl.exe.
# No WSL, Python, Git, or C++ compiler required.

param(
    [string]$Variant = "",            # auto | ptq1-mtp | pq2-mtp | q2-mtp | ptq1 | pq2 | q2
    [string]$Backend = "",            # auto | cuda | hip | vulkan | cpu
    [string]$Mode = "",               # thinking | instruct
    [string]$Mtp = "",                # auto | on | off
    [int]$Port = 0,                   # 0 = 8080 with 8081/8082 fallback
    [string]$HostAddr = "",           # "" = 0.0.0.0
    [int]$Ngl = -1,                   # -1 = default (99 GPU / 0 CPU)
    [int]$ContextSize = -1,           # -1/0 = safe 32K default (max 262144)
    [int]$Parallel = -1,              # -1 = default 1 (safe VRAM); 0 = llama-server auto
    [string]$MmprojQuant = "",        # Q8_0 | BF16
    [int]$ImageMaxTokens = -1,        # -1 = default 1024; 0 = uncapped
    [switch]$NoVision,
    [switch]$MmprojCpu,
    [switch]$Kv4,
    [switch]$Choose,
    [switch]$NoBrowser,
    [switch]$Detached,
    [switch]$NonInteractive,
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ─── Optional .env loader (never overwrites already-set env vars) ─────
$envPath = Join-Path $PSScriptRoot ".env"
if (Test-Path $envPath) {
    foreach ($rawLine in (Get-Content -Path $envPath -ErrorAction SilentlyContinue)) {
        $line = $rawLine.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -le 0) { continue }
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim()
        if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            if ($v.Length -ge 2) { $v = $v.Substring(1, $v.Length - 2) }
        }
        if (-not (Test-Path "Env:$k")) {
            Set-Item -Path "Env:$k" -Value $v
        }
    }
}

# ─── Help ─────────────────────────────────────────────────────────────
if ($Help -or $Variant -in @("-h", "--help", "help")) {
    Write-Host "Usage: powershell -ExecutionPolicy Bypass -File start.ps1 [options]"
    Write-Host ""
    Write-Host "Run Ternary Bonsai 2.5 27B locally on Windows (native, no WSL required)."
    Write-Host ""
    Write-Host "Variants:"
    Write-Host "  auto       (default) CUDA/HIP -> ptq1-mtp (6.2 GB), Vulkan/CPU -> pq2-mtp (7.5 GB)"
    Write-Host "  ptq1-mtp   PTQ1_0 + built-in MTP head (6.23 GB, 1.76 bpw) - fastest on NVIDIA GPUs"
    Write-Host "  pq2-mtp    PQ2_0  + built-in MTP head (7.49 GB, 2-bit slots)"
    Write-Host "  q2-mtp     Q2_0   + built-in MTP head (7.91 GB) - stock llama.cpp b11556+ compatible"
    Write-Host "  ptq1       PTQ1_0 base without MTP    (5.99 GB)"
    Write-Host "  pq2        PQ2_0  base without MTP    (7.25 GB)"
    Write-Host "  q2         Q2_0   base without MTP    (7.67 GB)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Variant <name>       Model variant (default: auto)"
    Write-Host "  -Backend <name>       auto | cuda | hip | vulkan | cpu"
    Write-Host "  -Mode <name>          thinking (default) | instruct"
    Write-Host "  -Mtp <name>           auto (on for CUDA/HIP) | on | off"
    Write-Host "  -Port <N>             Server port (default: 8080, fallback 8081-8082)"
    Write-Host "  -HostAddr <IP>        Bind address (default: 0.0.0.0)"
    Write-Host "  -Ngl <N>              GPU layers (default: 99, auto 0 on CPU)"
    Write-Host "  -ContextSize <N>      Context length (0 = safe 32768; max 262144)"
    Write-Host "  -Parallel <N>         Concurrent slots (default: 1; 0 = auto)"
    Write-Host "  -NoVision             Skip multimodal vision projector (mmproj)"
    Write-Host "  -MmprojQuant <Q>      Q8_0 (0.63 GB, default) | BF16 (0.93 GB)"
    Write-Host "  -MmprojCpu            Keep vision projector in RAM (--no-mmproj-offload)"
    Write-Host "  -ImageMaxTokens <N>   Max vision tokens (default: 1024; 0 = uncapped)"
    Write-Host "  -Kv4                  Enable 4-bit KV cache (q4_0)"
    Write-Host "  -Choose               Interactive variant menu"
    Write-Host "  -NoBrowser            Do not auto-open the Web UI in your browser"
    Write-Host "  -Detached             Run llama-server in background (logs to ~/.bonsai25/llama-server.log)"
    Write-Host "  -DryRun               Print resolved plan and exit without downloading"
    Write-Host ""
    Write-Host "Stop server: powershell -ExecutionPolicy Bypass -File stop.ps1"
    exit 0
}

# ─── Resolve config from CLI params + env vars ────────────────────────
$rawVariant = $Variant
if ($Variant -eq "") {
    if ($env:MODEL_VARIANT) { $Variant = $env:MODEL_VARIANT } else { $Variant = "auto" }
}
if ($Backend -eq "") {
    if ($env:BACKEND) { $Backend = $env:BACKEND }
    elseif ($env:BONSAI_BACKEND) { $Backend = $env:BONSAI_BACKEND }
    else { $Backend = "auto" }
}
if ($Mode -eq "") {
    if ($env:MODE) { $Mode = $env:MODE } else { $Mode = "thinking" }
}
if ($Mtp -eq "") {
    if ($env:MTP) { $Mtp = $env:MTP } else { $Mtp = "auto" }
}
if ($Port -eq 0) {
    if ($env:PORT) { $Port = [int]$env:PORT } else { $Port = 8080 }
}
if ($HostAddr -eq "") {
    if ($env:HOST) { $HostAddr = $env:HOST } else { $HostAddr = "0.0.0.0" }
}
if ($Ngl -lt 0) {
    if ($env:NGL) { $Ngl = [int]$env:NGL } else { $Ngl = 99 }
}
if ($ContextSize -lt 0) {
    if ($env:CONTEXT_SIZE) { $ContextSize = [int]$env:CONTEXT_SIZE } else { $ContextSize = 0 }
}
if ($Parallel -lt 0) {
    if ($env:PARALLEL) { $Parallel = [int]$env:PARALLEL } else { $Parallel = 1 }
}
if ($MmprojQuant -eq "") {
    if ($env:MMPROJ_QUANT) { $MmprojQuant = $env:MMPROJ_QUANT } else { $MmprojQuant = "Q8_0" }
}
if ($ImageMaxTokens -lt 0) {
    if ($env:IMAGE_MAX_TOKENS) { $ImageMaxTokens = [int]$env:IMAGE_MAX_TOKENS } else { $ImageMaxTokens = 1024 }
}
$userSetMmprojCpu = $MmprojCpu.IsPresent -or ($null -ne $env:MMPROJ_CPU)
$userSetKv4       = $Kv4.IsPresent       -or ($null -ne $env:KV4)
if (-not $NoVision -and $env:NO_VISION -eq "1") { $NoVision = $true }
if (-not $MmprojCpu -and $env:MMPROJ_CPU -eq "1") { $MmprojCpu = $true }
if (-not $Kv4 -and $env:KV4 -eq "1") { $Kv4 = $true }
if (-not $NoBrowser -and $env:NO_BROWSER -eq "1") { $NoBrowser = $true }
if (-not $DryRun -and $env:BONSAI_DRY_RUN -eq "1") { $DryRun = $true }

$Variant = $Variant.ToLowerInvariant()
$Backend = $Backend.ToLowerInvariant()
$Mode = $Mode.ToLowerInvariant()
$Mtp = $Mtp.ToLowerInvariant()
if ($Mtp -eq "1") { $Mtp = "on" }
if ($Mtp -eq "0") { $Mtp = "off" }
$MmprojQuant = $MmprojQuant.ToUpperInvariant()

if ($Mode -notin @("thinking", "instruct")) {
    Write-Host "[ERR] Unknown Mode '$Mode'. Valid: thinking, instruct" -ForegroundColor Red
    exit 1
}
if ($Mtp -notin @("auto", "on", "off")) {
    Write-Host "[ERR] Unknown Mtp '$Mtp'. Valid: auto, on, off" -ForegroundColor Red
    exit 1
}
if ($MmprojQuant -notin @("Q8_0", "BF16")) {
    Write-Host "[ERR] Unknown MmprojQuant '$MmprojQuant'. Valid: Q8_0, BF16" -ForegroundColor Red
    exit 1
}

$HF_REPO = "prism-ml/Ternary-Bonsai-2.5-27B-GGUF"
$DEFAULT_RELEASE = "prism-b12178-03ec600"
$PRISM_RELEASE = if ($env:PRISM_RELEASE) { $env:PRISM_RELEASE } else { $DEFAULT_RELEASE }

$VARIANTS = @{
    "ptq1-mtp" = @{ File = "Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf"; SizeMB = 6230; Hint = "6.23 GB"; HasMtp = $true }
    "pq2-mtp"  = @{ File = "Ternary-Bonsai-2.5-27B-PQ2_0-mtp.gguf";  SizeMB = 7490; Hint = "7.49 GB"; HasMtp = $true }
    "q2-mtp"   = @{ File = "Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf";   SizeMB = 7910; Hint = "7.91 GB"; HasMtp = $true }
    "ptq1"     = @{ File = "Ternary-Bonsai-2.5-27B-PTQ1_0.gguf";     SizeMB = 5990; Hint = "5.99 GB"; HasMtp = $false }
    "pq2"      = @{ File = "Ternary-Bonsai-2.5-27B-PQ2_0.gguf";      SizeMB = 7250; Hint = "7.25 GB"; HasMtp = $false }
    "q2"       = @{ File = "Ternary-Bonsai-2.5-27B-Q2_0.gguf";       SizeMB = 7670; Hint = "7.67 GB"; HasMtp = $false }
}

if ($Variant -in @("default", "bonsai25", "bonsai2.5")) { $Variant = "auto" }
if ($Variant -ne "auto" -and -not $VARIANTS.ContainsKey($Variant)) {
    Write-Host "[ERR] Unknown variant '$Variant'. Valid: auto, ptq1-mtp, pq2-mtp, q2-mtp, ptq1, pq2, q2" -ForegroundColor Red
    exit 1
}

# ─── Paths ────────────────────────────────────────────────────────────
$baseDir   = if ($env:BONSAI25_DIR) { $env:BONSAI25_DIR } else { Join-Path $HOME ".bonsai25" }
$modelsDir = if ($env:MODELS_DIR) { $env:MODELS_DIR } else { Join-Path $baseDir "models" }
$binRoot   = Join-Path $baseDir "bin"
$dlDir     = Join-Path $baseDir "downloads"
$pidFile   = Join-Path $baseDir "llama-server.pid"
$logFile   = Join-Path $baseDir "llama-server.log"

# ─── Architecture & Hardware Detection ────────────────────────────────
$archRaw = if ($env:BONSAI_TEST_ARCH) { $env:BONSAI_TEST_ARCH } else { $env:PROCESSOR_ARCHITECTURE }
$archSuffix = if ($archRaw -match "ARM64") { "arm64" } else { "x64" }

$totalRamMB = 0
if ($env:BONSAI_TEST_RAM_MB) {
    $totalRamMB = [int]$env:BONSAI_TEST_RAM_MB
} else {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.TotalPhysicalMemory) {
            $totalRamMB = [int][math]::Floor($cs.TotalPhysicalMemory / 1MB)
        }
    } catch {}
}

function Detect-NvidiaVramMB {
    if ($env:BONSAI_TEST_VRAM_MB) { return [int]$env:BONSAI_TEST_VRAM_MB }
    $nvsmiPaths = @(
        "nvidia-smi.exe",
        "$env:SystemRoot\System32\nvidia-smi.exe",
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    foreach ($p in $nvsmiPaths) {
        try {
            $out = & $p --query-gpu=memory.total --format=csv,noheader,nounits 2>&1 | Select-Object -First 1
            if ($out -and ($out.ToString().Trim() -match '^\d+$')) {
                return [int]$out.ToString().Trim()
            }
        } catch {}
    }
    return 0
}

function Detect-CudaTag {
    if ($env:BONSAI_TEST_CUDA_VER) {
        $ver = $env:BONSAI_TEST_CUDA_VER
        if ($ver -match '^(\d+)\.(\d+)') {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            if ($archSuffix -eq "arm64") { return "13.4" }
            if ($maj -gt 13 -or ($maj -eq 13 -and $min -ge 3)) { return "13.3" }
            return "12.4"
        }
    }
    $nvsmiPaths = @(
        "nvidia-smi.exe",
        "$env:SystemRoot\System32\nvidia-smi.exe",
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    foreach ($p in $nvsmiPaths) {
        try {
            $out = & $p 2>&1 | Out-String
            if ($out -match 'CUDA(?:\s+UMD)?\s+Version:\s+(\d+)\.(\d+)') {
                $maj = [int]$Matches[1]; $min = [int]$Matches[2]
                if ($archSuffix -eq "arm64") { return "13.4" }
                if ($maj -gt 13 -or ($maj -eq 13 -and $min -ge 3)) { return "13.3" }
                if ($maj -gt 12 -or ($maj -eq 12 -and $min -ge 4)) { return "12.4" }
                return "too-old"
            }
        } catch {}
    }
    if ($archSuffix -eq "arm64") { return "13.4" }
    return "12.4"
}

$gpuNames = @()
try {
    $gpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
} catch {}
$gpuStr = $gpuNames -join "; "

$cudaTag = ""
$backendAuto = ($Backend -eq "auto")

if ($env:BONSAI_TEST_BACKEND) {
    $Backend = $env:BONSAI_TEST_BACKEND.ToLowerInvariant()
    if ($Backend -eq "cuda") { $cudaTag = Detect-CudaTag }
} elseif ($Backend -eq "auto") {
    $detectedCuda = $false
    if ($gpuStr -match "NVIDIA") {
        $ct = Detect-CudaTag
        if ($ct -ne "too-old") {
            $Backend = "cuda"
            $cudaTag = $ct
            $detectedCuda = $true
        } else {
            Write-Host "[WARN] NVIDIA GPU driver CUDA version < 12.4; falling back." -ForegroundColor Yellow
        }
    }
    if (-not $detectedCuda) {
        $hasHip = $false
        if ($archSuffix -eq "x64") {
            if ($env:HIP_PATH -and (Test-Path $env:HIP_PATH)) { $hasHip = $true }
            elseif (Get-Command hipcc -ErrorAction SilentlyContinue) { $hasHip = $true }
        }
        if ($hasHip) {
            $Backend = "hip"
        } elseif ($archSuffix -eq "x64" -and ($gpuStr -match "AMD|Radeon|Intel|Arc" -or (Get-Command vulkaninfo -ErrorAction SilentlyContinue))) {
            $Backend = "vulkan"
        } else {
            $Backend = "cpu"
        }
    }
} elseif ($Backend -eq "cuda") {
    $cudaTag = Detect-CudaTag
    if ($cudaTag -eq "too-old") { $cudaTag = "12.4" }
}

if ($Backend -notin @("cuda", "hip", "vulkan", "cpu")) {
    Write-Host "[ERR] Unknown backend '$Backend'. Valid: auto, cuda, hip, vulkan, cpu" -ForegroundColor Red
    exit 1
}

# Guard arm64 for backends that only ship x64 archives
if ($archSuffix -eq "arm64" -and $Backend -in @("hip", "vulkan")) {
    Write-Host "[WARN] No Windows ARM64 prebuilt archive for '$Backend' - falling back to cpu." -ForegroundColor Yellow
    $Backend = "cpu"
}

# Detect VRAM on CUDA & recommend optimal variant + memory tuning
$totalVramMB = if ($Backend -eq "cuda") { Detect-NvidiaVramMB } else { 0 }

$autoReason = ""
$recommended = ""
if ($Backend -eq "cuda") {
    $recommended = "ptq1-mtp"
    if ($totalVramMB -gt 0 -and $totalVramMB -le 9000) {
        $autoReason = "CUDA <=9GB VRAM ($totalVramMB MB): smallest PTQ1_0-mtp + 16K ctx + KV4 + CPU mmproj"
    } elseif ($totalVramMB -gt 0) {
        $autoReason = "CUDA ($totalVramMB MB VRAM): PTQ1_0-mtp is fastest decode on NVIDIA + built-in MTP"
    } else {
        $autoReason = "CUDA: PTQ1_0-mtp is fastest decode on NVIDIA + built-in MTP"
    }
} elseif ($Backend -eq "hip") {
    $recommended = "ptq1-mtp"
    $autoReason = "AMD HIP: PTQ1_0-mtp + built-in MTP"
} elseif ($totalRamMB -gt 0 -and $totalRamMB -lt 12000) {
    $recommended = "ptq1-mtp"
    $autoReason = "$Backend tight RAM ($totalRamMB MB): smallest PTQ1_0-mtp + 8K ctx + KV4"
} else {
    $recommended = "pq2-mtp"
    $autoReason = "$Backend ($totalRamMB MB RAM): PQ2_0-mtp for smooth unpacking and strong prefill"
}

if ($Choose -and -not $NonInteractive -and -not $DryRun) {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Ternary Bonsai 2.5 27B Runner — Interactive Setup" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "   Backend:    $Backend$(if ($cudaTag) { " (CUDA $cudaTag)" })"
    if ($totalVramMB -gt 0) { Write-Host "   GPU VRAM:   $totalVramMB MB" }
    if ($totalRamMB -gt 0)  { Write-Host "   System RAM: $totalRamMB MB" }
    Write-Host "   Auto-pick:  $recommended ($autoReason)"
    Write-Host ""
    Write-Host "   Variants: ptq1-mtp (6.23 GB), pq2-mtp (7.49 GB), q2-mtp (7.91 GB), ptq1, pq2, q2"
    $picked = Read-Host "Choose variant (Enter for $recommended)"
    if ($picked -and $picked.Trim() -ne "") {
        $Variant = $picked.Trim().ToLowerInvariant()
        if (-not $VARIANTS.ContainsKey($Variant)) {
            Write-Host "[ERR] Unknown variant '$Variant'." -ForegroundColor Red
            exit 1
        }
    } else {
        $Variant = $recommended
    }
}

if ($Variant -eq "auto") {
    $Variant = $recommended
}

$vInfo = $VARIANTS[$Variant]
$modelFile = $vInfo.File
$modelHint = $vInfo.Hint
$hasMtp = $vInfo.HasMtp
$mmprojFile = if ($NoVision) { "" } else { "Ternary-Bonsai-2.5-27B-mmproj-$MmprojQuant.gguf" }

# ─── Resolve PrismML Release Tag & Assets ─────────────────────────────
$relTag = $PRISM_RELEASE
if ($relTag -eq "latest") {
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/PrismML-Eng/llama.cpp/releases/latest" -Headers @{ "User-Agent" = "bonsai-runner2" } -TimeoutSec 10
        if ($rel.tag_name) { $relTag = $rel.tag_name } else { $relTag = $DEFAULT_RELEASE }
    } catch {
        $relTag = $DEFAULT_RELEASE
    }
}

function Get-AssetNames($be, $cTag, $arch, $tag) {
    switch ($be) {
        "cuda" {
            return @{
                Main   = "llama-$tag-bin-win-cuda-$cTag-$arch.zip"
                Cudart = "cudart-llama-bin-win-cuda-$cTag-$arch.zip"
            }
        }
        "hip" {
            return @{ Main = "llama-$tag-bin-win-hip-radeon-x64.zip"; Cudart = "" }
        }
        "vulkan" {
            return @{ Main = "llama-$tag-bin-win-vulkan-x64.zip"; Cudart = "" }
        }
        default {
            return @{ Main = "llama-$tag-bin-win-cpu-$arch.zip"; Cudart = "" }
        }
    }
}

$assets = Get-AssetNames $Backend $cudaTag $archSuffix $relTag
$effCtx = $ContextSize
if ($Backend -eq "cuda" -and $totalVramMB -gt 0 -and $totalVramMB -le 9000) {
    if ($effCtx -eq 0) { $effCtx = 16384 }
    if (-not $userSetMmprojCpu) { $MmprojCpu = $true }
    if (-not $userSetKv4) { $Kv4 = $true }
} elseif ($Backend -notin @("cuda", "hip") -and $totalRamMB -gt 0 -and $totalRamMB -lt 12000) {
    if ($effCtx -eq 0) { $effCtx = 8192 }
    if (-not $userSetKv4) { $Kv4 = $true }
}
if ($effCtx -eq 0) { $effCtx = 32768 }
$effNgl = if ($Backend -eq "cpu") { 0 } else { $Ngl }

$mtpEnabled = $false
if ($hasMtp -and $Mtp -ne "off") {
    if ($Mtp -eq "on" -or $Backend -in @("cuda", "hip")) {
        $mtpEnabled = $true
    }
}
$effMtpNmax = if ($env:MTP_NMAX) { $env:MTP_NMAX } else { "3" }
$effMtpPmin = if ($env:MTP_PMIN) { $env:MTP_PMIN } else { "0.1" }

if ($DryRun) {
    Write-Host "DRY_RUN_PLAN:"
    Write-Host "  OS=Windows"
    Write-Host "  ARCH=$archSuffix"
    Write-Host "  BACKEND=$Backend"
    Write-Host "  CUDA_TAG=$cudaTag"
    Write-Host "  VRAM_MB=$totalVramMB"
    Write-Host "  RAM_MB=$totalRamMB"
    Write-Host "  VARIANT=$Variant"
    Write-Host "  AUTO_REASON=$autoReason"
    Write-Host "  HF_REPO=$HF_REPO"
    Write-Host "  MODEL_FILE=$modelFile"
    Write-Host "  MMPROJ_FILE=$mmprojFile"
    Write-Host "  MMPROJ_CPU=$MmprojCpu"
    Write-Host "  RELEASE_TAG=$relTag"
    Write-Host "  PREBUILT_ASSET=$($assets.Main)"
    Write-Host "  CUDART_ASSET=$($assets.Cudart)"
    Write-Host "  MODE=$Mode"
    Write-Host "  MTP_ENABLED=$mtpEnabled"
    Write-Host "  MTP_NMAX=$effMtpNmax"
    Write-Host "  MTP_PMIN=$effMtpPmin"
    Write-Host "  CTX_VALUE=$effCtx"
    Write-Host "  PARALLEL=$Parallel"
    Write-Host "  EFF_NGL=$effNgl"
    Write-Host "  KV4=$Kv4"
    exit 0
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Ternary Bonsai 2.5 27B Runner (Windows)" -ForegroundColor Cyan
Write-Host "  Variant:    $Variant ($modelHint)"
Write-Host "  Backend:    $Backend$(if ($cudaTag) { " (CUDA $cudaTag)" }) on Windows/$archSuffix"
if ($gpuStr) { Write-Host "  GPU(s):     $gpuStr" }
if ($totalVramMB -gt 0) { Write-Host "  GPU VRAM:   $totalVramMB MB" }
if ($totalRamMB -gt 0) { Write-Host "  System RAM: $totalRamMB MB" }
if ($autoReason) { Write-Host "  Auto-pick:  $autoReason" }
Write-Host "  Mode:       $Mode"
if ($mtpEnabled) {
    Write-Host "  MTP Draft:  ON (n-max=$effMtpNmax, p-min=$effMtpPmin)"
} elseif ($hasMtp) {
    Write-Host "  MTP Draft:  OFF (use -Mtp on to force on $Backend)"
} else {
    Write-Host "  MTP Draft:  not included in $Variant"
}
Write-Host "  HF repo:    $HF_REPO"
Write-Host "  Model:      $modelFile"
if ($mmprojFile) { Write-Host "  Vision:     $mmprojFile" } else { Write-Host "  Vision:     disabled (-NoVision)" }
Write-Host "==========================================================" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $modelsDir, $binRoot, $dlDir | Out-Null

# ─── Helper: Download with curl.exe (atomic .part) ────────────────────
function Download-Url($url, $dest) {
    $parent = Split-Path -Parent $dest
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $part = "$dest.part"
    $curlArgs = @("-L", "--fail", "--retry", "3", "--retry-delay", "2", "-C", "-", "-o", $part)
    if ($env:HF_TOKEN -and $url -like "*huggingface.co*") {
        $curlArgs += @("-H", "Authorization: Bearer $($env:HF_TOKEN)")
    }
    $curlArgs += $url
    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Download failed (exit $LASTEXITCODE): $url"
    }
    Move-Item -Force -Path $part -Destination $dest
}

function Ensure-PrismBinary($be, $cTag) {
    $a = Get-AssetNames $be $cTag $archSuffix $relTag
    $stamp = if ($be -eq "cuda") { "$relTag-cuda-$cTag" } else { "$relTag-$be" }
    $binDir = Join-Path $binRoot $stamp
    $found = $null
    if (Test-Path $binDir) {
        $found = Get-ChildItem -Path $binDir -Recurse -Filter "llama-server.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $found) {
        $zipPath = Join-Path $dlDir $a.Main
        $url = "https://github.com/PrismML-Eng/llama.cpp/releases/download/$relTag/$($a.Main)"
        Write-Host "   Downloading $($a.Main) ..."
        Download-Url $url $zipPath
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        Write-Host "   Extracting $($a.Main) ..."
        Expand-Archive -Path $zipPath -DestinationPath $binDir -Force
        Remove-Item -Force -Path $zipPath -ErrorAction SilentlyContinue

        if ($a.Cudart -ne "") {
            $dllZip = Join-Path $dlDir $a.Cudart
            $dllUrl = "https://github.com/PrismML-Eng/llama.cpp/releases/download/$relTag/$($a.Cudart)"
            Write-Host "   Downloading CUDA runtime DLLs ($($a.Cudart)) ..."
            try {
                Download-Url $dllUrl $dllZip
                Expand-Archive -Path $dllZip -DestinationPath $binDir -Force
                Remove-Item -Force -Path $dllZip -ErrorAction SilentlyContinue
            } catch {
                Write-Host "[WARN] Could not download CUDA runtime DLLs; system CUDA toolkit will be required." -ForegroundColor Yellow
            }
        }

        $found = Get-ChildItem -Path $binDir -Recurse -Filter "llama-server.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found -and $be -eq "vulkan") {
            # Safety fallback if a future vulkan archive only contains ggml-vulkan.dll
            $cpuAsset = "llama-$relTag-bin-win-cpu-$archSuffix.zip"
            $cpuZip = Join-Path $dlDir $cpuAsset
            Write-Host "   Overlaying CPU base binaries ($cpuAsset) ..."
            Download-Url "https://github.com/PrismML-Eng/llama.cpp/releases/download/$relTag/$cpuAsset" $cpuZip
            Expand-Archive -Path $cpuZip -DestinationPath $binDir -Force
            Remove-Item -Force -Path $cpuZip -ErrorAction SilentlyContinue
            $found = Get-ChildItem -Path $binDir -Recurse -Filter "llama-server.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    } else {
        Write-Host "   [OK] Using cached binary: $($found.FullName)" -ForegroundColor Green
    }

    if (-not $found) {
        throw "llama-server.exe not found after extracting $($a.Main)"
    }
    return $found.FullName
}

function Test-ServerBinary($exePath) {
    try {
        $proc = Start-Process -FilePath $exePath -ArgumentList @("--version") -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\bonsai25-ver-out.txt" -RedirectStandardError "$env:TEMP\bonsai25-ver-err.txt"
        return ($proc.ExitCode -eq 0)
    } catch {
        return $false
    }
}

Write-Host ""
Write-Host "-- Step 1: Setting up PrismML llama.cpp ($relTag) --"
$serverExe = Ensure-PrismBinary $Backend $cudaTag
if (-not (Test-ServerBinary $serverExe)) {
    if ($backendAuto -and $Backend -ne "cpu") {
        Write-Host "[WARN] $Backend binary failed smoke test - falling back to CPU backend." -ForegroundColor Yellow
        $Backend = "cpu"
        $effNgl = 0
        $mtpEnabled = ($hasMtp -and $Mtp -eq "on")
        $serverExe = Ensure-PrismBinary "cpu" ""
        if (-not (Test-ServerBinary $serverExe)) {
            Write-Host "[ERR] CPU binary also failed smoke test." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "[ERR] llama-server.exe failed smoke test (--version). Try -Backend cpu." -ForegroundColor Red
        exit 1
    }
}
Write-Host "   [OK] Runtime smoke test passed" -ForegroundColor Green

# ─── Step 2: Download Model + Vision Projector ────────────────────────
function Download-HfFile($file, $minBytes) {
    $dest = Join-Path $modelsDir $file
    if (Test-Path $dest) {
        $len = (Get-Item $dest).Length
        if ($len -ge $minBytes) {
            $gb = [math]::Round($len / 1GB, 2)
            Write-Host "   [OK] Already present: $dest ($gb GB)" -ForegroundColor Green
            return $dest
        }
        Write-Host "   [WARN] Existing file looks incomplete ($len bytes) - re-downloading..." -ForegroundColor Yellow
        Remove-Item -Force -Path $dest
    }

    # Check common local caches
    $cacheCandidates = @(
        (Join-Path $HOME ".bonsai\models\$file"),
        (Join-Path $HOME "models\$file"),
        (Join-Path $PSScriptRoot "models\$file")
    )
    foreach ($c in $cacheCandidates) {
        if ((Test-Path $c) -and ((Get-Item $c).Length -ge $minBytes)) {
            Write-Host "   [OK] Using cached file: $c" -ForegroundColor Green
            return $c
        }
    }

    if ($env:HF_HUB_OFFLINE -eq "1") {
        Write-Host "[ERR] HF_HUB_OFFLINE=1 and '$file' not found locally." -ForegroundColor Red
        exit 1
    }

    $url = "https://huggingface.co/$HF_REPO/resolve/main/$file"
    Write-Host "   Downloading $HF_REPO/$file ..."
    Download-Url $url $dest
    $finalLen = (Get-Item $dest).Length
    if ($finalLen -lt $minBytes) {
        Remove-Item -Force -Path $dest -ErrorAction SilentlyContinue
        throw "Downloaded file '$dest' is unexpectedly small ($finalLen bytes)."
    }
    $gb = [math]::Round($finalLen / 1GB, 2)
    Write-Host "   [OK] Downloaded: $dest ($gb GB)" -ForegroundColor Green
    return $dest
}

Write-Host ""
Write-Host "-- Step 2: Downloading Ternary Bonsai 2.5 27B weights --"
$modelPath = Download-HfFile $modelFile 104857600
$mmprojPath = ""
if ($mmprojFile -ne "") {
    $mmprojPath = Download-HfFile $mmprojFile 10485760
}

# ─── Step 3: Port Fallback ────────────────────────────────────────────
function Test-PortFree($p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect("127.0.0.1", $p, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(300)
        if ($ok -and $c.Connected) { return $false }
        return $true
    } catch { return $true }
    finally { $c.Close() }
}

$finalPort = $Port
$portFound = $false
for ($tryP = $Port; $tryP -le ($Port + 2); $tryP++) {
    if (Test-PortFree $tryP) {
        $finalPort = $tryP
        $portFound = $true
        break
    }
}
if (-not $portFound) {
    Write-Host "[ERR] Ports $Port..$($Port + 2) are all busy. Pass -Port <free_port>." -ForegroundColor Red
    exit 1
}
if ($finalPort -ne $Port) {
    Write-Host "   Port $Port busy -> using port $finalPort"
}

# ─── Step 4: Assemble llama-server Arguments ──────────────────────────
$serverArgs = @(
    "-m", $modelPath,
    "--host", $HostAddr,
    "--port", "$finalPort",
    "-ngl", "$effNgl",
    "-fa", "on",
    "-c", "$effCtx",
    "--jinja"
)

if ($Mode -eq "instruct") {
    $serverArgs += @(
        "--temp", "0.7",
        "--top-p", "0.80",
        "--top-k", "20",
        "--min-p", "0",
        "--presence-penalty", "1.5",
        "--repeat-penalty", "1.0",
        "--reasoning-budget", "0",
        "--reasoning", "off"
    )
} else {
    $serverArgs += @(
        "--temp", "1.0",
        "--top-p", "0.95",
        "--top-k", "20",
        "--min-p", "0",
        "--presence-penalty", "0.0",
        "--repeat-penalty", "1.0"
    )
}

if ($Parallel -gt 0) {
    $serverArgs += @("-np", "$Parallel")
}

if ($mmprojPath -ne "") {
    $serverArgs += @("--mmproj", $mmprojPath)
    if ($MmprojCpu) { $serverArgs += "--no-mmproj-offload" }
    if ($ImageMaxTokens -gt 0) { $serverArgs += @("--image-max-tokens", "$ImageMaxTokens") }
}

if ($mtpEnabled) {
    $serverArgs += @(
        "--spec-type", "draft-mtp",
        "--spec-draft-n-min", "0",
        "--spec-draft-n-max", "$effMtpNmax",
        "--spec-draft-p-min", "$effMtpPmin"
    )
}

if ($Kv4) {
    $serverArgs += @("--cache-type-k", "q4_0", "--cache-type-v", "q4_0")
}

# ─── Step 5: Launch Server ────────────────────────────────────────────
Write-Host ""
Write-Host "-- Step 3: Starting llama-server --"
Write-Host "   Binary:    $serverExe"
Write-Host "   Model:     $modelPath"
if ($mmprojPath -ne "") { Write-Host "   Vision:    $mmprojPath" }
Write-Host "   Web UI:    http://localhost:$finalPort" -ForegroundColor Green
Write-Host "   API:       http://$HostAddr`:$finalPort/v1/chat/completions"
Write-Host "   Backend:   $Backend  Context: $effCtx tokens  Parallel: $Parallel"
if ($mtpEnabled) { Write-Host "   MTP:       enabled (n-max=$effMtpNmax, p-min=$effMtpPmin)" }
if ($Kv4)        { Write-Host "   KV Cache:  Q4_0 (4-bit)" }
if ($MmprojCpu -and $mmprojPath -ne "") { Write-Host "   Vision RAM: projector kept in system RAM (--no-mmproj-offload)" }
Write-Host "   Test it:   powershell -ExecutionPolicy Bypass -File test-model.ps1 -Port $finalPort"
Write-Host "   Stop it:   Ctrl+C or powershell -ExecutionPolicy Bypass -File stop.ps1"
Write-Host ""

# Quote any argument with spaces or JSON quotes for Start-Process
function Format-WinArg($s) {
    if ($s -match '[\s"]') {
        return '"' + ($s -replace '"', '\"') + '"'
    }
    return $s
}
$argLine = ($serverArgs | ForEach-Object { Format-WinArg $_ }) -join " "

function Wait-And-OpenBrowser($portNum, $serverProc) {
    $url = "http://localhost:$portNum"
    Write-Host "   Waiting for model to finish loading..."
    for ($i = 0; $i -lt 90; $i++) {
        if ($serverProc.HasExited) { return }
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$portNum/health" -TimeoutSec 2 -UseBasicParsing
            if ($r.StatusCode -eq 200) {
                Write-Host "   [OK] Server ready at $url" -ForegroundColor Green
                if (-not $NoBrowser) {
                    Write-Host "   Opening llama.cpp Chat UI in your browser..." -ForegroundColor Cyan
                    try { Start-Process $url } catch {}
                }
                return
            }
        } catch {}
        Start-Sleep -Seconds 1
    }
}

if ($Detached) {
    $errLog = Join-Path $baseDir "llama-server.err.log"
    $proc = Start-Process -FilePath $serverExe -ArgumentList $argLine -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError $errLog -PassThru
    Set-Content -Path $pidFile -Value $proc.Id -Encoding ascii
    Write-Host "   PID: $($proc.Id) (saved to $pidFile)"
    Write-Host "   Logs: $logFile / $errLog"
    Wait-And-OpenBrowser $finalPort $proc
    exit 0
}

$proc = Start-Process -FilePath $serverExe -ArgumentList $argLine -NoNewWindow -PassThru
Set-Content -Path $pidFile -Value $proc.Id -Encoding ascii
Write-Host "   PID: $($proc.Id) (saved to $pidFile)"
Wait-And-OpenBrowser $finalPort $proc
try {
    $proc.WaitForExit()
    $code = $proc.ExitCode
} finally {
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $pidFile -ErrorAction SilentlyContinue
}
exit $code
