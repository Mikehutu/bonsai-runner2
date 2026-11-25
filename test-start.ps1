# test-start.ps1 — Validation suite for start.ps1 and stop.ps1 on Windows
$ErrorActionPreference = "Continue"

$pass = 0
$fail = 0
function Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:pass++ }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Check($haystack, $needle, $msg) {
    if ($haystack -and $haystack.Contains($needle)) { Pass $msg } else { Fail "$msg (missing '$needle')" }
}

$startPs1 = Join-Path $PSScriptRoot "start.ps1"
$stopPs1  = Join-Path $PSScriptRoot "stop.ps1"

Write-Host ""
Write-Host "=== 1. PowerShell AST Syntax Parse ==="
foreach ($scriptPath in @($startPs1, $stopPs1)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) {
        Pass "$(Split-Path -Leaf $scriptPath) parsed with 0 syntax errors"
    } else {
        Fail "$(Split-Path -Leaf $scriptPath) syntax errors: $($errors | Out-String)"
    }
}

Write-Host ""
Write-Host "=== 2. Help & Error Handling ==="
$helpOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -Help 2>&1 | Out-String)
Check $helpOut "ptq1-mtp" "help lists ptq1-mtp"
Check $helpOut "pq2-mtp"  "help lists pq2-mtp"
Check $helpOut "q2-mtp"   "help lists q2-mtp"
Check $helpOut "-Backend" "help lists -Backend"
Check $helpOut "-Mtp"     "help lists -Mtp"

$badOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -Variant bogus 2>&1 | Out-String)
Check $badOut "Unknown variant" "rejects invalid variant"

Write-Host ""
Write-Host "=== 3. Windows Backend & Variant Dry-Run Matrix ==="

# 3a. Auto detection on current machine
$outAuto = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outAuto "DRY_RUN_PLAN:" "native auto dry-run succeeded"
Check $outAuto "HF_REPO=prism-ml/Ternary-Bonsai-2.5-27B-GGUF" "resolves Bonsai 2.5 HF repo"
Check $outAuto "CTX_VALUE=32768" "default context maps to 32768"
Check $outAuto "PARALLEL=1" "default parallel is 1"

# 3b. Windows x64 CUDA 12.4
$env:BONSAI_TEST_ARCH = "AMD64"
$env:BONSAI_TEST_BACKEND = "cuda"
$env:BONSAI_TEST_CUDA_VER = "12.4"
$outCuda12 = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outCuda12 "BACKEND=cuda" "Win x64 CUDA 12.4: backend=cuda"
Check $outCuda12 "VARIANT=ptq1-mtp" "Win x64 CUDA: auto picks ptq1-mtp"
Check $outCuda12 "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cuda-12.4-x64.zip" "Win x64 CUDA 12.4: binary asset"
Check $outCuda12 "CUDART_ASSET=cudart-llama-bin-win-cuda-12.4-x64.zip" "Win x64 CUDA 12.4: cudart DLL asset"
Check $outCuda12 "MTP_ENABLED=True" "Win x64 CUDA: MTP auto-enabled"

# 3c. Windows x64 CUDA 13.3
$env:BONSAI_TEST_CUDA_VER = "13.3"
$outCuda13 = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outCuda13 "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cuda-13.3-x64.zip" "Win x64 CUDA 13.3: binary asset"
Check $outCuda13 "CUDART_ASSET=cudart-llama-bin-win-cuda-13.3-x64.zip" "Win x64 CUDA 13.3: cudart DLL asset"

# 3d. Windows ARM64 CUDA 13.4
$env:BONSAI_TEST_ARCH = "ARM64"
$env:BONSAI_TEST_CUDA_VER = "13.4"
$outArmCuda = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outArmCuda "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cuda-13.4-arm64.zip" "Win ARM64 CUDA 13.4: binary asset"
Check $outArmCuda "CUDART_ASSET=cudart-llama-bin-win-cuda-13.4-arm64.zip" "Win ARM64 CUDA 13.4: cudart DLL asset"

# 3e. Windows x64 HIP Radeon
$env:BONSAI_TEST_ARCH = "AMD64"
$env:BONSAI_TEST_BACKEND = "hip"
Remove-Item Env:BONSAI_TEST_CUDA_VER -ErrorAction SilentlyContinue
$outHip = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun 2>&1 | Out-String)
Check $outHip "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-hip-radeon-x64.zip" "Win x64 HIP: binary asset"
Check $outHip "MTP_ENABLED=True" "Win x64 HIP: MTP auto-enabled"

# 3f. Windows x64 Vulkan
$env:BONSAI_TEST_BACKEND = "vulkan"
$outVk = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun -Mode instruct -Kv4 -NoVision -ContextSize 65536 2>&1 | Out-String)
Check $outVk "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-vulkan-x64.zip" "Win x64 Vulkan: binary asset"
Check $outVk "MODE=instruct" "Win Vulkan: instruct mode"
Check $outVk "KV4=True" "Win Vulkan: KV4 enabled"
Check $outVk "CTX_VALUE=65536" "Win Vulkan: explicit context 65536"
Check $outVk "MTP_ENABLED=False" "Win Vulkan: MTP off by default"

# 3g. Windows ARM64 CPU
$env:BONSAI_TEST_ARCH = "ARM64"
$env:BONSAI_TEST_BACKEND = "cpu"
$outArmCpu = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startPs1 -DryRun -Variant q2 2>&1 | Out-String)
Check $outArmCpu "PREBUILT_ASSET=llama-prism-b12178-03ec600-bin-win-cpu-arm64.zip" "Win ARM64 CPU: binary asset"
Check $outArmCpu "MODEL_FILE=Ternary-Bonsai-2.5-27B-Q2_0.gguf" "Win ARM64 CPU: q2 model file"
Check $outArmCpu "EFF_NGL=0" "Win ARM64 CPU: NGL=0"

Remove-Item Env:BONSAI_TEST_ARCH, Env:BONSAI_TEST_BACKEND, Env:BONSAI_TEST_CUDA_VER -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=============================="
Write-Host "  $pass passed / $fail failed"
Write-Host "=============================="
if ($fail -eq 0) { exit 0 } else { exit 1 }
