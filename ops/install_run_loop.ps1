# ops/install_run_loop.ps1
# Crea/actualiza ops/run_loop.ps1 (loop scan->simulate->plan->dryrun->exec)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$opsDir = Join-Path $repoRoot "ops"
if (-not (Test-Path $opsDir)) { New-Item -ItemType Directory -Path $opsDir | Out-Null }

$target = Join-Path $opsDir "run_loop.ps1"

Set-Content -LiteralPath $target -Encoding UTF8 -Value @'
# ops/run_loop.ps1
# Loop operativo: scan -> simulate -> plan -> dryrun -> (exec si OK)
# Uso:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -SleepSec 15
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -SleepSec 15 -AutoExec
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -AllowExecNoModel

[CmdletBinding()]
param(
  [int]$SleepSec = 10,

  [string]$PlanMinProximity = "0.98",
  [string]$PlanMinExecProximity = "1.002",

  [int]$PlanMaxExecOrders = 25,
  [string]$MaxTxGasPriceWei = "0",

  [int]$DryrunMax = 25,

  [switch]$AllowExecNoModel,
  [switch]$AutoExec
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Env([string]$name) {
  $v = (Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue).Value
  if ([string]::IsNullOrWhiteSpace($v)) { throw "Missing required env var: $name" }
}

# Resolve repo root even if launched from elsewhere
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

# Tools
Get-Command pnpm -ErrorAction Stop | Out-Null

# Required for dryrun/exec
Require-Env "ARB_RPC_URL"
Require-Env "EXECUTOR_ADDR"
Require-Env "CALLER_ADDR"

# Planning knobs
$env:PLAN_MIN_PROXIMITY = $PlanMinProximity
$env:PLAN_MIN_EXEC_PROXIMITY = $PlanMinExecProximity
$env:PLAN_MAX_EXEC_ORDERS = "$PlanMaxExecOrders"

# Optional model override (only matters if plan.ts uses it)
$env:ALLOW_EXEC_NO_MODEL = $(if ($AllowExecNoModel.IsPresent) { "1" } else { "0" })

# Gas guardrail used by plan/exec
$env:MAX_TX_GAS_PRICE_WEI = $MaxTxGasPriceWei

# Dryrun knobs
$env:DRYRUN_MAX = "$DryrunMax"
$env:DRYRUN_STOP_ON_OK = "1"

# Exec enable flag used by exec.ts
$env:EXEC_ENABLED = $(if ($AutoExec.IsPresent) { "1" } else { "0" })

Write-Host "=== Morpho Liquidator Loop ==="
Write-Host "RepoRoot = $RepoRoot"
Write-Host "ARB_RPC_URL=$($env:ARB_RPC_URL)"
Write-Host "EXECUTOR_ADDR=$($env:EXECUTOR_ADDR)"
Write-Host "CALLER_ADDR=$($env:CALLER_ADDR)"
Write-Host "PLAN_MIN_PROXIMITY=$($env:PLAN_MIN_PROXIMITY)"
Write-Host "PLAN_MIN_EXEC_PROXIMITY=$($env:PLAN_MIN_EXEC_PROXIMITY)"
Write-Host "PLAN_MAX_EXEC_ORDERS=$($env:PLAN_MAX_EXEC_ORDERS)"
Write-Host "ALLOW_EXEC_NO_MODEL=$($env:ALLOW_EXEC_NO_MODEL)"
Write-Host "MAX_TX_GAS_PRICE_WEI=$($env:MAX_TX_GAS_PRICE_WEI)"
Write-Host "DRYRUN_MAX=$($env:DRYRUN_MAX)"
Write-Host "EXEC_ENABLED=$($env:EXEC_ENABLED) AutoExec=$($AutoExec.IsPresent)"
Write-Host "--------------------------------"

while ($true) {
  try {
    Write-Host "`n=== scan ==="
    pnpm -s run scan
    if ($LASTEXITCODE -ne 0) { throw "scan failed with code $LASTEXITCODE" }

    Write-Host "=== simulate ==="
    pnpm -s run simulate
    if ($LASTEXITCODE -ne 0) { throw "simulate failed with code $LASTEXITCODE" }

    Write-Host "=== plan ==="
    pnpm -s run plan
    if ($LASTEXITCODE -ne 0) { throw "plan failed with code $LASTEXITCODE" }

    Write-Host "=== dryrun orders ==="
    pnpm -s tsx .\scripts\dryrun_plan_orders.ts
    $code = $LASTEXITCODE

    if ($code -eq 0) {
      Write-Host "DRYRUN OK found."
      if ($AutoExec.IsPresent) {
        Write-Host "AutoExec enabled -> executing..."
        pnpm -s run exec
        if ($LASTEXITCODE -ne 0) {
          Write-Host "EXEC returned code $LASTEXITCODE (continuing loop)"
        }
      } else {
        Write-Host "AutoExec disabled -> NOT executing. Re-run with -AutoExec to execute."
      }
    }
    elseif ($code -eq 2) {
      Write-Host "Dryrun FAIL (real revert). Continuing..."
    }
    else {
      Write-Host "No OK in dryrun (only healthy/skips). Continuing..."
    }
  }
  catch {
    Write-Host "Loop error: $($_.Exception.Message)"
  }

  Start-Sleep -Seconds $SleepSec
}
