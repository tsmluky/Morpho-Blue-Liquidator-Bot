[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExecutorAddr,
  [int]$SleepSec = 15,
  [switch]$AutoExec
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Beep-N([int]$n, [int]$freq=900, [int]$ms=250) {
  for ($i=0; $i -lt $n; $i++) { [Console]::Beep($freq, $ms); Start-Sleep -Milliseconds 80 }
}

function Load-DotEnv {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
  $dotenv = Join-Path $repoRoot ".env"
  $loader = Join-Path $PSScriptRoot "load_dotenv.ps1"

  if (Test-Path $dotenv) {
    if (-not (Test-Path $loader)) {
      throw "Missing dotenv loader: $loader (create ops/load_dotenv.ps1)"
    }
    . $loader -Path $dotenv
  }
}

function Assert-RpcOk {
  if (-not $env:ARB_RPC_URL) { throw "Missing env ARB_RPC_URL" }
  if ($env:ARB_RPC_URL -match '\<TU_KEY\>|\(tu RPC\)|\(|\)|\<|\>') {
    throw "ARB_RPC_URL parece placeholder o contiene caracteres inválidos: '$env:ARB_RPC_URL'"
  }
  if ($env:ARB_RPC_URL -notmatch '^https?://') { throw "ARB_RPC_URL debe empezar por http(s)://" }

  $probe = @{ jsonrpc="2.0"; id=1; method="eth_chainId"; params=@() } | ConvertTo-Json -Compress
  try {
    $r = Invoke-RestMethod -Method Post -Uri $env:ARB_RPC_URL -ContentType "application/json" -Body $probe -TimeoutSec 15
  } catch {
    throw "RPC probe failed: $($_.Exception.Message)"
  }
  if (-not $r.result) {
    $raw = ($r | ConvertTo-Json -Depth 6 -Compress)
    throw "RPC probe returned non-JSONRPC or missing result: $raw"
  }
}

function AgeSec([string]$iso) {
  try {
    $dt = [DateTimeOffset]::Parse($iso)
    $now = [DateTimeOffset]::UtcNow
    $age = ($now - $dt).TotalSeconds
    if ($age -lt 0) { return 0 }
    return [Math]::Round($age, 1)
  } catch {
    return $null
  }
}

function Read-JsonSafe([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try {
    return (Get-Content $path -Raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Run-Step([string]$name, [scriptblock]$block) {
  Write-Host ("`n== {0} ==" -f $name)
  & $block
  if ($LASTEXITCODE -ne 0) { throw "Step failed: $name (exit=$LASTEXITCODE)" }
}

# Ensure we run from repo root (so .\data paths work)
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

# Load .env into $env:* for this PowerShell process
Load-DotEnv

while ($true) {
  try {
    Assert-RpcOk

    Run-Step "scan"      { pnpm -s run scan }
    Run-Step "simulate"  { pnpm -s run simulate }
    Run-Step "plan"      { pnpm -s run plan }
    Run-Step "preflight" { pnpm -s run preflight }

    $plan = Read-JsonSafe ".\data\tx_plan.json"
    $sim  = Read-JsonSafe ".\data\tx_sim.json"
    $hot  = Read-JsonSafe ".\data\hot_queue.json"

    $top = $null
    if ($plan -and $plan.items) {
      $top = $plan.items | Select-Object -First 1
    }

    $planAge = if ($plan -and $plan.generatedAt) { AgeSec $plan.generatedAt } else { $null }
    $simAge  = if ($sim -and $sim.generatedAt)  { AgeSec $sim.generatedAt }  else { $null }
    $hotAge  = if ($hot -and $hot.generatedAt)  { AgeSec $hot.generatedAt }  else { $null }

    $execCount  = if ($plan -and $plan.execCount -ne $null) { [int]$plan.execCount } else { 0 }
    $watchCount = if ($plan -and $plan.watchCount -ne $null) { [int]$plan.watchCount } else { 0 }

    $topProx = if ($top -and $top.proximity -ne $null) { [double]$top.proximity } else { [double]::NaN }
    $topNet  = if ($top -and $top.netProfitUsd -ne $null) { [double]$top.netProfitUsd } else { [double]::NaN }
    $topAct  = if ($top -and $top.action) { [string]$top.action } else { "N/A" }

    $utcNow = (Get-Date).ToUniversalTime().ToString("s")

    Write-Host ("UTC {0} | exec={1} watch={2} | topProx={3} topNet={4} action={5} | age(plan)={6}s age(sim)={7}s age(hot)={8}s" -f `
      $utcNow,
      $execCount,
      $watchCount,
      ($(if ([double]::IsNaN($topProx)) { "N/A" } else { "{0:N6}" -f $topProx })),
      ($(if ([double]::IsNaN($topNet))  { "N/A" } else { "{0:N2}" -f $topNet })),
      $topAct,
      ($(if ($planAge -eq $null) { "N/A" } else { $planAge })),
      ($(if ($simAge  -eq $null) { "N/A" } else { $simAge })),
      ($(if ($hotAge  -eq $null) { "N/A" } else { $hotAge }))
    )

    if ($execCount -gt 0) {
      Write-Host "EXEC DETECTADO (plan). Validando con dryrun on-chain..."
      $out = & pnpm -s tsx .\scripts\dryrun_exec_all.ts $ExecutorAddr 2>&1 | Out-String

      $dryrunOk = $out -match "SIMULATION:\s+OK"
      if ($dryrunOk) {
        Write-Host "DRYRUN OK: al menos 1 EXEC candidate es liquidable on-chain."
        Beep-N 3 1100 350

        if ($AutoExec -and ($env:EXEC_ENABLED -eq "1")) {
          Write-Host "AUTOEXEC ARMADO: EXEC_ENABLED=1 y -AutoExec => enviando tx..."
          Beep-N 2 1400 180
          Run-Step "exec" { pnpm -s run exec }
          Beep-N 4 1600 120
        } else {
          Write-Host "No ejecuto (seguro): para ejecutar, pon EXEC_ENABLED=1 en .env y corre con -AutoExec."
        }
      } else {
        Write-Host "DRYRUN NO OK: probablemente 'position is healthy' u otro revert. NO ejecutes."
        Beep-N 1 700 180
      }
    }

  } catch {
    Write-Host "`n[watch_dryrun] ERROR: $($_.Exception.Message)"
    Beep-N 2 500 200
  }

  Start-Sleep -Seconds $SleepSec
}
