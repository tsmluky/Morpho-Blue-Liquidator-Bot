#!/usr/bin/env pwsh
# ops/fix_all.ps1
# Parchea plan.ts + instala inspect_opportunities + instala run_loop

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Assert-RepoRoot {
  if (-not (Test-Path ".\package.json")) { throw "Ejecuta desde la raíz del repo (donde está package.json)." }
  if (-not (Test-Path ".\src\commands\plan.ts")) { throw "No existe .\src\commands\plan.ts en este directorio." }
  if (-not (Test-Path ".\data")) { New-Item -ItemType Directory -Force .\data | Out-Null }
}

function Patch-PlanTs {
  $target = Resolve-Path ".\src\commands\plan.ts"
  $src = Get-Content -LiteralPath $target -Raw -Encoding UTF8
  $changed = 0

  # 1) isQuoted: preferir columna isQuoted si existe (fallback passQuoted)
  $patIsQuoted = 'const\s+isQuoted\s*=\s*\(r\["passQuoted"\]\s*\?\?\s*"0"\)\s*===\s*"1"\s*;'
  if ([regex]::IsMatch($src, $patIsQuoted, "IgnoreCase")) {
    $repIsQuoted = 'const isQuoted = String(r["isQuoted"] ?? r["passQuoted"] ?? "0").trim() === "1";'
    $src = [regex]::Replace($src, $patIsQuoted, $repIsQuoted, "IgnoreCase")
    $changed++
  } elseif ($src -match 'const\s+isQuoted\s*=\s*String\(r\["isQuoted"\]' ) {
    # ya parcheado
  } else {
    Write-Warning "No encontré patrón de isQuoted esperado en plan.ts. No lo toqué."
  }

  # 2) passModel opcional: si falta columna o viene vacía => neutral=true
  $patPassModel = 'const\s+passModel\s*=\s*\(r\["passModel"\]\s*\?\?\s*"0"\)\s*===\s*"1"\s*;'
  if ([regex]::IsMatch($src, $patPassModel, "IgnoreCase")) {
    $repPassModel = @(
      'const passModelRaw = String(r["passModel"] ?? "").trim();',
      '// Si la columna no existe o viene vacía, no bloquear (neutral=true).',
      '// Si existe, respeta 0/1.',
      'const passModel = passModelRaw === "" ? true : passModelRaw === "1";'
    ) -join "`n"
    $src = [regex]::Replace($src, $patPassModel, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $repPassModel }, "IgnoreCase")
    $changed++
  } elseif ($src -match 'passModelRaw' ) {
    # ya parcheado
  } else {
    Write-Warning "No encontré patrón de passModel esperado en plan.ts. No lo toqué."
  }

  if ($changed -gt 0) {
    Set-Content -LiteralPath $target -Value $src -Encoding UTF8
    Write-Host "OK: plan.ts parcheado ($changed cambios) => $target"
  } else {
    Write-Host "OK: plan.ts sin cambios (ya estaba o no matcheó patrones)."
  }
}

function Install-InspectOps {
  $p = Resolve-Path ".\ops" 
  $target = Join-Path $p "inspect_opportunities.ps1"
  $content = @'
# ops/inspect_opportunities.ps1
# Inspecciona data/opportunities.csv y explica por qué no hay EXEC en tx_plan.json
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$csvPath = ".\data\opportunities.csv"
if (-not (Test-Path $csvPath)) { throw "Missing $csvPath (corre: pnpm -s run scan ; pnpm -s run simulate)" }

$rows = Import-Csv $csvPath
if (-not $rows -or $rows.Count -eq 0) { throw "CSV vacío: $csvPath" }

$cols = $rows[0].PSObject.Properties.Name
Write-Host "Rows: $($rows.Count)"
Write-Host "Columns: $($cols -join ', ')"
Write-Host ""

function Count-True([string]$col) {
  return ($rows | Where-Object { ("" + $_.$col).Trim() -eq "1" }).Count
}

function Max-Num([string]$col) {
  return ($rows | ForEach-Object {
    $v = $null
    try { $v = [double]($_.$col) } catch { $v = $null }
    $v
  } | Where-Object { $_ -ne $null } | Measure-Object -Maximum).Maximum
}

$maxProx = Max-Num "proximity"
$maxNet  = Max-Num "netProfitUsd"
Write-Host ("max proximity: {0}" -f $maxProx)
Write-Host ("max netProfitUsd: {0}" -f $maxNet)
Write-Host ""

foreach ($c in @("status","isQuoted","passQuoted","passExec","passModel")) {
  if ($cols -contains $c) {
    if ($c -in @("status")) {
      $g = $rows | Group-Object -Property $c | Sort-Object Count -Descending
      Write-Host "status distribution:"
      $g | Select-Object -First 10 Name,Count | Format-Table -AutoSize
      Write-Host ""
    } else {
      Write-Host ("{0}=1 count: {1}" -f $c, (Count-True $c))
    }
  } else {
    Write-Host ("{0}: (missing column)" -f $c)
  }
}
Write-Host ""

Write-Host "Top 12 by netProfitUsd:"
$rows | Sort-Object {[double]$_.netProfitUsd} -Descending |
  Select-Object -First 12 ts,candidateId,status,proximity,isQuoted,passQuoted,passExec,passModel,netProfitUsd,quoteMode,uniPath,note |
  Format-Table -AutoSize

Write-Host ""
Write-Host "Top 12 by proximity:"
$rows | Sort-Object {[double]$_.proximity} -Descending |
  Select-Object -First 12 ts,candidateId,status,proximity,isQuoted,passQuoted,passExec,passModel,netProfitUsd,quoteMode,uniPath,note |
  Format-Table -AutoSize

Write-Host ""
Write-Host "Now run:"
Write-Host "  pnpm -s run plan"
Write-Host "  Get-Content .\data\tx_plan.json -TotalCount 40"
'@
  Set-Content -LiteralPath $target -Encoding UTF8 -Value $content
  Write-Host "OK: instalado $target"
}

function Install-RunLoop {
  $p = Resolve-Path ".\ops"
  $target = Join-Path $p "run_loop.ps1"
  $content = @'
# ops/run_loop.ps1
# Loop operativo: scan -> simulate -> plan -> dryrun -> (exec si OK)
# Uso:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -SleepSec 15
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -SleepSec 15 -AutoExec
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\run_loop.ps1 -AllowExecNoModel

[CmdletBinding()]
param(
  [int]$SleepSec = 15,
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

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot
Get-Command pnpm -ErrorAction Stop | Out-Null

Require-Env "ARB_RPC_URL"
Require-Env "EXECUTOR_ADDR"
Require-Env "CALLER_ADDR"

$env:PLAN_MIN_PROXIMITY      = $PlanMinProximity
$env:PLAN_MIN_EXEC_PROXIMITY = $PlanMinExecProximity
$env:PLAN_MAX_EXEC_ORDERS    = "$PlanMaxExecOrders"
$env:ALLOW_EXEC_NO_MODEL     = $(if ($AllowExecNoModel.IsPresent) { "1" } else { "0" })
$env:MAX_TX_GAS_PRICE_WEI    = $MaxTxGasPriceWei
$env:DRYRUN_MAX              = "$DryrunMax"
$env:DRYRUN_STOP_ON_OK       = "1"
$env:EXEC_ENABLED            = $(if ($AutoExec.IsPresent) { "1" } else { "0" })

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
'@
  Set-Content -LiteralPath $target -Encoding UTF8 -Value $content
  Write-Host "OK: instalado $target"
}

Assert-RepoRoot
Patch-PlanTs
Install-InspectOps
Install-RunLoop
Write-Host ""
Write-Host "OK: fix_all completado."
Write-Host "Siguiente:"
Write-Host "  pnpm -s run plan"
Write-Host "  pwsh -NoProfile -ExecutionPolicy Bypass -File .\ops\inspect_opportunities.ps1"
Write-Host "  pnpm -s tsx .\scripts\dryrun_plan_orders.ts"
