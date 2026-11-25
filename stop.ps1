# stop.ps1 — Stop the Ternary Bonsai 2.5 27B server started by start.ps1
$ErrorActionPreference = "Stop"

$baseDir = if ($env:BONSAI25_DIR) { $env:BONSAI25_DIR } else { Join-Path $HOME ".bonsai25" }
$pidFile = Join-Path $baseDir "llama-server.pid"

if (Test-Path $pidFile) {
    $pidVal = [int](Get-Content -Path $pidFile -Raw).Trim()
    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id $pidVal -Force
        Write-Host "[OK] Stopped llama-server (PID $pidVal)" -ForegroundColor Green
    } else {
        Write-Host "PID $pidVal not running (already stopped)."
    }
    Remove-Item -Path $pidFile -ErrorAction SilentlyContinue
} else {
    $procs = @(Get-Process -Name "llama-server" -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        foreach ($p in $procs) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Stopped llama-server (PID $($p.Id))" -ForegroundColor Green
        }
    } else {
        Write-Host "No running llama-server found (no PID file at $pidFile)."
    }
}
