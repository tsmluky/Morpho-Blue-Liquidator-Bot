[CmdletBinding()]
param(
  [int]$SleepSec = 0,
  [switch]$AutoExec
)

$ErrorActionPreference="Stop"
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Repo

# Load env (exec off by default unless -AutoExec)
if ($AutoExec) {
  pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo "ops\env.ps1") -ExecOn | Out-Host
} else {
  pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo "ops\env.ps1") | Out-Host
}

function ExecBuilt() {
  $p = Join-Path $Repo "data\tx_plan.json"
  if (-not (Test-Path $p)) { return 0 }
  try { return [int]((Get-Content $p -Raw | ConvertFrom-Json).execBuilt) } catch { return 0 }
}

Write-Host "=== scan ==="
pnpm -s run scan | Out-Host

Write-Host "=== simulate ==="
pnpm -s run simulate | Out-Host

Write-Host "=== plan ==="
pnpm -s run plan | Out-Host

$eb = ExecBuilt
Write-Host ("execBuilt={0}" -f $eb)

if ($eb -gt 0) {
  Write-Host "=== dryrun orders ==="
  pnpm -s tsx .\scripts\dryrun_plan_orders.ts | Out-Host

  if ($AutoExec) {
    Write-Host "=== EXEC (REAL) ==="
    pnpm -s run exec | Out-Host
  } else {
    Write-Host "STOP: found EXEC plan. If dryrun shows [OK], run: pnpm -s run exec"
  }
} else {
  Write-Host "No EXEC built."
  if ($SleepSec -gt 0) { Start-Sleep -Seconds $SleepSec }
}
