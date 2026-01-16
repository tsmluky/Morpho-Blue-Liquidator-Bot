[CmdletBinding()]
param(
  [int]$SleepSec = 20,
  [switch]$Once
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Beep-Once { [Console]::Beep(900, 120) }

function Read-JsonFile([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
  if (-not $raw) { return $null }
  return $raw | ConvertFrom-Json
}

$root = (Get-Location).Path
$planPath = Join-Path $root "data\tx_plan.json"
$logPath  = Join-Path $root "data\watch_plan_log.csv"

if (-not (Test-Path -LiteralPath (Split-Path $logPath))) {
  New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $logPath)) {
  "ts,execBuilt,execItems,execPass,watchItems,topNetUsd,topCandidateId" | Out-File -LiteralPath $logPath -Encoding UTF8
}

while ($true) {
  $ts = (Get-Date).ToString("s")

  try {
    pnpm -s run scan | Out-Host
    pnpm -s run simulate | Out-Host
    pnpm -s run plan | Out-Host

    $plan = Read-JsonFile $planPath
    if ($null -eq $plan) { throw "No pude leer $planPath" }

    $items = @($plan.items)
    $exec  = @($items | Where-Object { $_.action -eq "EXEC" })
    $execPass = @($exec | Where-Object { $_.pass -eq $true })

    $watch = @($items | Where-Object { $_.action -eq "WATCH" })

    $top = $null
    if ($execPass.Count -gt 0) {
      $top = $execPass | Sort-Object {[double]$_.netProfitUsd} -Descending | Select-Object -First 1
    } elseif ($exec.Count -gt 0) {
      $top = $exec | Sort-Object {[double]$_.netProfitUsd} -Descending | Select-Object -First 1
    } else {
      $top = $watch | Sort-Object {[double]$_.netProfitUsd} -Descending | Select-Object -First 1
    }

    $topNet = if ($top) { [double]$top.netProfitUsd } else { 0.0 }
    $topId  = if ($top) { $top.candidateId } else { "" }

    "$ts,$($plan.execBuilt),$($exec.Count),$($execPass.Count),$($watch.Count),$topNet,""$topId""" | Add-Content -LiteralPath $logPath -Encoding UTF8

    if ($execPass.Count -gt 0) {
      Write-Host "`n[ALERT] Hay EXEC pass=true ($($execPass.Count)). Corriendo dryrun del plan..." -ForegroundColor Green
      Beep-Once
      pnpm -s tsx .\scripts\dryrun_plan_orders.ts | Out-Host
      Beep-Once
    } else {
      Write-Host "`n[INFO] Sin EXEC pass=true. execBuilt=$($plan.execBuilt) execItems=$($exec.Count) watchItems=$($watch.Count) topNetUsd=$topNet" -ForegroundColor Cyan
    }

  } catch {
    Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
  }

  if ($Once) { break }
  Start-Sleep -Seconds $SleepSec
}
