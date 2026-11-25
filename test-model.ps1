# test-model.ps1 - Quick live verification for a running Ternary Bonsai 2.5 27B server on Windows
# Tests health, model metadata, chat generation (+ tok/s + MTP draft stats), and native tool calling.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File test-model.ps1
#   powershell -ExecutionPolicy Bypass -File test-model.ps1 -Port 18081

param(
    [string]$HostAddr = "127.0.0.1",
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Load PORT from .env if present and not overridden
$envPath = Join-Path $PSScriptRoot ".env"
if ($Port -eq 0 -and -not $env:PORT -and (Test-Path $envPath)) {
    foreach ($rawLine in (Get-Content -Path $envPath -ErrorAction SilentlyContinue)) {
        if ($rawLine -match '^\s*PORT\s*=\s*(\d+)') {
            $Port = [int]$Matches[1]
            break
        }
    }
}
if ($Port -eq 0) {
    if ($env:PORT) { $Port = [int]$env:PORT } else { $Port = 8080 }
}
$baseUrl = "http://$HostAddr`:$Port"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Ternary Bonsai 2.5 27B - Live Model Test (Windows)" -ForegroundColor Cyan
Write-Host "  Endpoint: $baseUrl"
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Health check
try {
    $h = Invoke-WebRequest -Uri "$baseUrl/health" -TimeoutSec 5 -UseBasicParsing
    if ($h.StatusCode -ne 200) { throw "HTTP $($h.StatusCode)" }
    Write-Host "[OK] Health check passed (HTTP 200)" -ForegroundColor Green
} catch {
    Write-Host "[ERR] Server not ready at $baseUrl/health. Start it first with: powershell -ExecutionPolicy Bypass -File start.ps1" -ForegroundColor Red
    exit 1
}

# 2. Model metadata
$modelId = "bonsai-2.5"
$models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -TimeoutSec 10
if ($models.data -and $models.data.Count -gt 0) {
    $m = $models.data[0]
    if ($m.id) { $modelId = $m.id }
    Write-Host "[OK] Model:      $(Split-Path -Leaf $m.id)" -ForegroundColor Green
    if ($m.meta -and $m.meta.ftype) { Write-Host "     Packing:    $($m.meta.ftype)" }
    if ($m.meta -and $m.meta.n_ctx) { Write-Host "     Context:    $($m.meta.n_ctx) active / $($m.meta.n_ctx_train) max" }
    if ($m.architecture -and $m.architecture.input_modalities) { Write-Host "     Modalities: $($m.architecture.input_modalities -join ', ')" }
}

# 3. Chat completion + throughput + MTP stats
Write-Host ""
Write-Host "-- Test 1: Chat Completion & Throughput --"
$chatPayload = @{
    model = $modelId
    messages = @(
        @{ role = "system"; content = "You are a helpful assistant" },
        @{ role = "user"; content = "What is 17 + 25? Reply with just the number." }
    )
    max_tokens = 2048
    temperature = 0
} | ConvertTo-Json -Depth 6

$chatBytes = [System.Text.Encoding]::UTF8.GetBytes($chatPayload)
$chatRes = Invoke-RestMethod -Method Post -Uri "$baseUrl/v1/chat/completions" -ContentType "application/json; charset=utf-8" -Body $chatBytes -TimeoutSec 180
$msg = $chatRes.choices[0].message
$ans = if ($msg.content) { $msg.content.Trim() } else { "(still in reasoning trace - increase max_tokens)" }
Write-Host "[OK] Answer:     $ans" -ForegroundColor Green
if ($msg.reasoning_content) {
    Write-Host "     Thinking:   $($msg.reasoning_content.Length) chars (thinking mode active)"
}
if ($chatRes.timings) {
    $pp = [math]::Round($chatRes.timings.prompt_per_second, 1)
    $tg = [math]::Round($chatRes.timings.predicted_per_second, 1)
    Write-Host "     Speed:      $pp tok/s prefill / $tg tok/s decode"
    if ($chatRes.timings.draft_n -and $chatRes.timings.draft_n -gt 0) {
        $pct = [math]::Round(100.0 * $chatRes.timings.draft_n_accepted / $chatRes.timings.draft_n, 1)
        Write-Host "     MTP Draft:  $($chatRes.timings.draft_n_accepted)/$($chatRes.timings.draft_n) accepted ($pct%)"
    } else {
        Write-Host "     MTP Draft:  inactive (normal on CPU or non-MTP builds)"
    }
}

# 4. Native Agentic Tool Calling Test
Write-Host ""
Write-Host "-- Test 2: Native Agentic Tool Calling --"
$toolPayload = @{
    model = $modelId
    messages = @(
        @{ role = "system"; content = "You are a helpful assistant. Use the provided tools when appropriate." },
        @{ role = "user"; content = "Check the current weather in Helsinki in Celsius." }
    )
    tools = @(
        @{
            type = "function"
            function = @{
                name = "get_weather"
                description = "Get the current weather for a city."
                parameters = @{
                    type = "object"
                    properties = @{
                        city = @{ type = "string" }
                        unit = @{ type = "string"; enum = @("celsius", "fahrenheit") }
                    }
                    required = @("city")
                }
            }
        }
    )
    max_tokens = 2048
    temperature = 0
} | ConvertTo-Json -Depth 10

$toolBytes = [System.Text.Encoding]::UTF8.GetBytes($toolPayload)
$toolRes = Invoke-RestMethod -Method Post -Uri "$baseUrl/v1/chat/completions" -ContentType "application/json; charset=utf-8" -Body $toolBytes -TimeoutSec 180
$tMsg = $toolRes.choices[0].message
if ($tMsg.tool_calls -and $tMsg.tool_calls.Count -gt 0) {
    $fn = $tMsg.tool_calls[0].function
    Write-Host "[OK] Tool call:  $($fn.name)($($fn.arguments))" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Expected tool_calls, got text: $($tMsg.content)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "All live model checks passed!" -ForegroundColor Green
