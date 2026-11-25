# test-start.ps1 - Validation suite for start.ps1, stop.ps1, and test-model.ps1
# Compatible with Windows PowerShell 5.1 (powershell.exe) and PowerShell 7+ (pwsh).
$ErrorActionPreference = "Continue"

$pass = 0
$fail = 0
function Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:pass++ }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Check($haystack, $needle, $msg) {
    if ($haystack -and $haystack.Contains($needle)) { Pass $msg } else { Fail "$msg (missing '$needle')" }
}

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) {
    $psExe = if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { "powershell.exe" } else { "pwsh" }
}

$startPs1     = Join-Path $PSScriptRoot "start.ps1"
$stopPs1      = Join-Path $PSScriptRoot "stop.ps1"
$testModelPs1 = Join-Path $PSScriptRoot "test-model.ps1"
$selfPs1      = Join-Path $PSScriptRoot "test-start.ps1"

Write-Host ""
Write-Host "=== 1. PowerShell AST Syntax & Pure-ASCII Encoding ==="
foreach ($scriptPath in @($startPs1, $stopPs1, $testModelPs1, $selfPs1)) {
    $leaf = Split-Path -Leaf $scriptPath
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) {
        Pass "$leaf parsed with 0 syntax errors"
    } else {
        Fail "$leaf syntax errors: $($errors | Out-String)"
    }

    $bytes = [System.IO.File]::ReadAllBytes($scriptPath)
    $nonAscii = $false
    foreach ($b in $bytes) {
        if ($b -ge 128) { $nonAscii = $true; break }
    }
    if (-not $nonAscii) {
        Pass "$leaf is pure 7-bit ASCII (Windows PowerShell 5.1 ANSI-safe)"
    } else {
        Fail "$leaf contains non-ASCII bytes (breaks Windows PowerShell 5.1 without BOM)"
    }
}

Write-Host ""
Write-Host "=== 2. Help & Error Handling ==="
$helpOut = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -Help 2>&1 | Out-String)
Check $helpOut "ptq1-mtp" "help lists ptq1-mtp"
Check $helpOut "pq2-mtp"  "help lists pq2-mtp"
Check $helpOut "q2-mtp"   "help lists q2-mtp"
Check $helpOut "-Backend" "help lists -Backend"
Check $helpOut "-Mtp"     "help lists -Mtp"

$badOut = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -Variant bogus 2>&1 | Out-String)
Check $badOut "Unknown variant" "rejects invalid variant"

$mlxOut = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -Variant mlx 2>&1 | Out-String)
Check $mlxOut "Apple Silicon macOS" "cleanly explains mlx is macOS arm64 only"

Write-Host ""
Write-Host "=== 3. Windows Backend & Variant Dry-Run Matrix ==="

# 3a. Auto detection on current machine (with normalized 32GB test RAM so any host size passes)
$env:BONSAI_TEST_RAM_MB = "32768"
$outAuto = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outAuto "DRY_RUN_PLAN:" "native auto dry-run succeeded"
Check $outAuto "HF_REPO=prism-ml/Ternary-Bonsai-2.5-27B-GGUF" "resolves Bonsai 2.5 HF repo"
Check $outAuto "PARALLEL=1" "default parallel is 1"

# 3b. Windows x64 CUDA 12.4 (24 GB VRAM)
$env:BONSAI_TEST_ARCH = "AMD64"
$env:BONSAI_TEST_BACKEND = "cuda"
$env:BONSAI_TEST_CUDA_VER = "12.4"
$env:BONSAI_TEST_VRAM_MB = "24576"
$outCuda12 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outCuda12 "BACKEND=cuda" "Win x64 CUDA 12.4: backend=cuda"
Check $outCuda12 "VARIANT=ptq1-mtp" "Win x64 CUDA: auto picks ptq1-mtp"
Check $outCuda12 "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cuda-12.4-x64.zip" "Win x64 CUDA 12.4: binary asset"
Check $outCuda12 "CUDART_ASSET=cudart-llama-bin-win-cuda-12.4-x64.zip" "Win x64 CUDA 12.4: cudart DLL asset"
Check $outCuda12 "MTP_ENABLED=True" "Win x64 CUDA: MTP auto-enabled"
Check $outCuda12 "CTX_VALUE=32768" "Win x64 CUDA 24GB: 32K default context"

# 3b2. Windows x64 CUDA 8 GB VRAM (RTX 4060 / 3070 -> auto safe tuning)
$env:BONSAI_TEST_VRAM_MB = "8192"
$outCuda8g = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outCuda8g "VARIANT=ptq1-mtp" "Win CUDA 8GB VRAM: auto picks ptq1-mtp"
Check $outCuda8g "CTX_VALUE=16384"  "Win CUDA 8GB VRAM: auto-tunes 16K context"
Check $outCuda8g "MMPROJ_CPU=True"  "Win CUDA 8GB VRAM: keeps mmproj in system RAM"
Check $outCuda8g "KV4=True"         "Win CUDA 8GB VRAM: auto-enables 4-bit KV cache"
Check $outCuda8g "EFF_NGL=99"       "Win CUDA 8GB VRAM: keeps 99 GPU layers"

# 3b3. Windows x64 CUDA 6 GB VRAM Laptop (RTX 3060 6GB / RTX 4050 -> auto layer fit)
$env:BONSAI_TEST_VRAM_MB = "6144"
$outCuda6g = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outCuda6g "EFF_NGL=auto"     "Win CUDA 6GB VRAM: auto-splits GPU/CPU layers (-ngl auto)"
Check $outCuda6g "CTX_VALUE=16384"  "Win CUDA 6GB VRAM: auto-tunes 16K context"
Check $outCuda6g "MMPROJ_CPU=True"  "Win CUDA 6GB VRAM: keeps mmproj in system RAM"
Check $outCuda6g "KV4=True"         "Win CUDA 6GB VRAM: auto-enables 4-bit KV cache"
Remove-Item Env:BONSAI_TEST_VRAM_MB -ErrorAction SilentlyContinue

# 3c. Windows x64 CUDA 13.3
$env:BONSAI_TEST_CUDA_VER = "13.3"
$outCuda13 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outCuda13 "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cuda-13.3-x64.zip" "Win x64 CUDA 13.3: binary asset"
Check $outCuda13 "CUDART_ASSET=cudart-llama-bin-win-cuda-13.3-x64.zip" "Win x64 CUDA 13.3: cudart DLL asset"

# 3d. Windows ARM64 CUDA 13.4 + verify CPU base overlay logic exists for single-DLL archive
$env:BONSAI_TEST_ARCH = "ARM64"
$env:BONSAI_TEST_CUDA_VER = "13.4"
$outArmCuda = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outArmCuda "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cuda-13.4-arm64.zip" "Win ARM64 CUDA 13.4: binary asset"
Check $outArmCuda "CUDART_ASSET=cudart-llama-bin-win-cuda-13.4-arm64.zip" "Win ARM64 CUDA 13.4: cudart DLL asset"
$startSrc = Get-Content -Path $startPs1 -Raw
Check $startSrc 'if (-not $found -and $be -ne "cpu")' "start.ps1 overlays CPU base package for DLL-only GPU archives (e.g. win-cuda-13.4-arm64)"
Check $startSrc '--no-mmproj' "start.ps1 passes --no-mmproj when vision is disabled"

# 3e. Windows x64 HIP Radeon
$env:BONSAI_TEST_ARCH = "AMD64"
$env:BONSAI_TEST_BACKEND = "hip"
Remove-Item Env:BONSAI_TEST_CUDA_VER -ErrorAction SilentlyContinue
$outHip = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outHip "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-hip-radeon-x64.zip" "Win x64 HIP: binary asset"
Check $outHip "MTP_ENABLED=True" "Win x64 HIP: MTP auto-enabled"

# 3f. Windows x64 Vulkan (32GB vs 16GB vs 8GB RAM tiers)
$env:BONSAI_TEST_BACKEND = "vulkan"
$env:BONSAI_TEST_RAM_MB = "16384"
$outVk16 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outVk16 "CTX_VALUE=16384" "Win Vulkan 16GB RAM: safe 16K context"

$env:BONSAI_TEST_RAM_MB = "32768"
$outVk = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun -Mode instruct -Kv4 -NoVision -ContextSize 65536 2>&1 | Out-String)
Check $outVk "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-vulkan-x64.zip" "Win x64 Vulkan: binary asset"
Check $outVk "MODE=instruct" "Win Vulkan: instruct mode"
Check $outVk "KV4=True" "Win Vulkan: KV4 enabled"
Check $outVk "CTX_VALUE=65536" "Win Vulkan: explicit context 65536"
Check $outVk "MTP_ENABLED=True" "Win Vulkan: MTP auto-enabled (+63% measured)"
Check $outVk "MTP_NMAX=1"       "Win Vulkan PQ2_0: MTP n-max=1"

$outVkPtq = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun -Variant ptq1-mtp 2>&1 | Out-String)
Check $outVkPtq "MTP_NMAX=2"    "Win Vulkan PTQ1_0: MTP n-max=2"

# 3g. Windows ARM64 CPU
$env:BONSAI_TEST_ARCH = "ARM64"
$env:BONSAI_TEST_BACKEND = "cpu"
$outArmCpu = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun -Variant q2 2>&1 | Out-String)
Check $outArmCpu "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cpu-arm64.zip" "Win ARM64 CPU: binary asset"
Check $outArmCpu "MODEL_FILE=Ternary-Bonsai-2.5-27B-Q2_0.gguf" "Win ARM64 CPU: q2 model file"
Check $outArmCpu "EFF_NGL=0" "Win ARM64 CPU: NGL=0"

Remove-Item Env:BONSAI_TEST_ARCH, Env:BONSAI_TEST_BACKEND, Env:BONSAI_TEST_CUDA_VER, Env:BONSAI_TEST_RAM_MB -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=============================="
Write-Host "  $pass passed / $fail failed"
Write-Host "=============================="
if ($fail -eq 0) { exit 0 } else { exit 1 }
