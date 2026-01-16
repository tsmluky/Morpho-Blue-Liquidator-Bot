# ops/run_loop.ps1
# Loop operativo: scan -> simulate -> plan -> dryrun -> (exec si OK)
# Uso:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -SleepSec 15
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -SleepSec 15 -AutoExec
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -AllowExecNoModel
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -PlanMinExecProximity "1.0001"

[CmdletBinding()]
param(
  [int]$SleepSec = 15,

  # Si NO se pasan, el script respetará Env:PLAN_MIN_PROXIMITY / Env:PLAN_MIN_EXEC_PROXIMITY
  [string]$PlanMinProximity = "0.98",
  [string]$PlanMinExecProximity = "1.002",
  [int]$PlanMaxExecOrders = 25,

  [string]$MaxTxGasPriceWei = "0",
  [int]$DryrunMax = 25,

  # Si se pasa, fuerza ALLOW_EXEC_NO_MODEL=1. Si NO se pasa, respeta el env existente.
  [switch]$AllowExecNoModel,

  # Si se pasa, EXEC_ENABLED=1
  [switch]$AutoExec
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Env([string]$name) {
  $v = (Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue).Value
  if ([string]::IsNullOrWhiteSpace($v)) { throw "Missing required env var: $name" }
}

function Set-EnvIfMissing([string]$name, [string]$value) {
  $cur = (Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue).Value
  if ([string]::IsNullOrWhiteSpace($cur)) {
    Set-Item -Path "Env:$name" -Value $value
  }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot
Get-Command pnpm -ErrorAction Stop | Out-Null

Require-Env "ARB_RPC_URL"
Require-Env "EXECUTOR_ADDR"
Require-Env "CALLER_ADDR"

# --- PLAN_* envs: respeta env, salvo override explícito por parámetro ---
if ($PSBoundParameters.ContainsKey("PlanMinProximity")) {
  Set-Item -Path "Env:PLAN_MIN_PROXIMITY" -Value $PlanMinProximity
} else {
  Set-EnvIfMissing "PLAN_MIN_PROXIMITY" $PlanMinProximity
}

if ($PSBoundParameters.ContainsKey("PlanMinExecProximity")) {
  Set-Item -Path "Env:PLAN_MIN_EXEC_PROXIMITY" -Value $PlanMinExecProximity
} else {
  Set-EnvIfMissing "PLAN_MIN_EXEC_PROXIMITY" $PlanMinExecProximity
}

if ($PSBoundParameters.ContainsKey("PlanMaxExecOrders")) {
  Set-Item -Path "Env:PLAN_MAX_EXEC_ORDERS" -Value "$PlanMaxExecOrders"
} else {
  Set-EnvIfMissing "PLAN_MAX_EXEC_ORDERS" "$PlanMaxExecOrders"
}

# Tú ya usas esto en plan.ts; que exista por defecto si no está
Set-EnvIfMissing "PLAN_MAX_OPP_AGE_SEC" "60"

Set-EnvIfMissing "HEALTHY_COOLDOWN_SEC" "900"
# AllowExecNoModel: solo fuerza 1 si pasas el switch; si no, respeta lo que haya
if ($AllowExecNoModel.IsPresent) {
  Set-Item -Path "Env:ALLOW_EXEC_NO_MODEL" -Value "1"
} else {
  Set-EnvIfMissing "ALLOW_EXEC_NO_MODEL" "0"
}

# Otros envs operativos
Set-Item -Path "Env:MAX_TX_GAS_PRICE_WEI" -Value $MaxTxGasPriceWei
Set-Item -Path "Env:DRYRUN_MAX" -Value "$DryrunMax"
Set-Item -Path "Env:DRYRUN_STOP_ON_OK" -Value "1"
Set-Item -Path "Env:EXEC_ENABLED" -Value $(if ($AutoExec.IsPresent) { "1" } else { "0" })

Write-Host "=== Morpho Liquidator Loop ==="
Write-Host "RepoRoot = $RepoRoot"
Write-Host "ARB_RPC_URL=$($env:ARB_RPC_URL)"
Write-Host "EXECUTOR_ADDR=$($env:EXECUTOR_ADDR)"
Write-Host "CALLER_ADDR=$($env:CALLER_ADDR)"
Write-Host "PLAN_MIN_PROXIMITY=$($env:PLAN_MIN_PROXIMITY)"
Write-Host "PLAN_MIN_EXEC_PROXIMITY=$($env:PLAN_MIN_EXEC_PROXIMITY)"
Write-Host "PLAN_MAX_EXEC_ORDERS=$($env:PLAN_MAX_EXEC_ORDERS)"
Write-Host "PLAN_MAX_OPP_AGE_SEC=$($env:PLAN_MAX_OPP_AGE_SEC)"
Write-Host "HEALTHY_COOLDOWN_SEC=$($env:HEALTHY_COOLDOWN_SEC)"
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
        if ($LASTEXITCODE -ne 0) { Write-Host "EXEC returned code $LASTEXITCODE (continuing loop)" }
      } else {
        Write-Host "AutoExec disabled -> NOT executing. Re-run with -AutoExec to execute."
      }
    } elseif ($code -eq 2) {
      Write-Host "Dryrun FAIL (real revert). Continuing..."
    } else {
      Write-Host "No OK in dryrun (only healthy/skips). Continuing..."
    }
  } catch {
    Write-Host "Loop error: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds $SleepSec
}

