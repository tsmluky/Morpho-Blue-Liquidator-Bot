param(
  [int]$SleepSec = 8,
  [int]$PostExecCooldownSec = 20
)

$ErrorActionPreference="Stop"

function BeepOnce {
  try { [console]::beep(900,180) } catch { Write-Host "`a" -NoNewline }
}

function BeepTwice {
  try {
    [console]::beep(900,180)
    Start-Sleep -Milliseconds 120
    [console]::beep(1200,220)
  } catch {
    Write-Host "`a`a" -NoNewline
  }
}

function Read-TopProximity {
  $p = ".\data\candidates.jsonl"
  if (-not (Test-Path $p)) { return $null }
  $top = $null
  Get-Content $p | ForEach-Object {
    try {
      $o = $_ | ConvertFrom-Json
      if ($null -ne $o.proximity) {
        $v = [double]$o.proximity
        if ($null -eq $top -or $v -gt $top) { $top = $v }
      }
    } catch {}
  }
  return $top
}

function Get-ExecBuilt {
  $p = ".\data\tx_plan.json"
  if (-not (Test-Path $p)) { return 0 }
  try {
    $o = Get-Content $p -Raw | ConvertFrom-Json
    return [int]($o.execBuilt ?? 0)
  } catch { return 0 }
}

function Get-TxExecMtime {
  $p = ".\data\tx_exec.json"
  if (-not (Test-Path $p)) { return $null }
  try { return (Get-Item $p).LastWriteTimeUtc } catch { return $null }
}

function Dryrun-HasOk {
  param([string]$DryrunOutput)
  return ($DryrunOutput -match "\[OK\]")
}

function Exec-HasTxHash {
  param([string]$ExecOutput)
  return ($ExecOutput -match "txHash" -or $ExecOutput -match "0x[a-fA-F0-9]{64}")
}

while ($true) {
  Write-Host "`n=== scan ==="
  pnpm -s run scan | Out-Host

  $top = Read-TopProximity
  if ($null -ne $top) {
    Write-Host ("topProximity={0:N6}" -f $top)
  }

  # Si no hay top > 1.0, no quemamos tiempo
  if ($null -eq $top -or $top -le 1.0) {
    Write-Host "No liquidables (topProximity <= 1.0). Sleeping..."
    Start-Sleep -Seconds $SleepSec
    continue
  }

  Write-Host "=== simulate ==="
  pnpm -s run simulate | Out-Host

  Write-Host "=== plan ==="
  pnpm -s run plan | Out-Host

  $execBuilt = Get-ExecBuilt
  Write-Host ("execBuilt={0}" -f $execBuilt)

  if ($execBuilt -le 0) {
    Start-Sleep -Seconds $SleepSec
    continue
  }

  Write-Host "=== dryrun orders ==="
  $dryrunOut = (pnpm -s tsx .\scripts\dryrun_plan_orders.ts | Out-String)
  $dryrunOut | Out-Host

  if (-not (Dryrun-HasOk -DryrunOutput $dryrunOut)) {
    # Evita beeps por SKIP_HEALTHY u otros
    Start-Sleep -Seconds $SleepSec
    continue
  }

  # OK encontrado -> beep simple
  BeepOnce
  Write-Host "OK found by dryrun. Executing REAL tx..."

  $beforeMtime = Get-TxExecMtime

  # Ejecuta en real
  $execOut = (pnpm -s run exec | Out-String)
  $execOut | Out-Host

  # Detecta éxito por stdout o por tx_exec.json actualizado
  $afterMtime = Get-TxExecMtime
  $txExecTouched = ($null -ne $afterMtime -and ($null -eq $beforeMtime -or $afterMtime -gt $beforeMtime))
  $hasTxHash = (Exec-HasTxHash -ExecOutput $execOut)

  if ($hasTxHash -or $txExecTouched) {
    BeepTwice
    Write-Host "EXEC broadcast detected. Continuing hunt after cooldown..."
    Start-Sleep -Seconds $PostExecCooldownSec
    continue
  } else {
    Write-Host "EXEC did not broadcast (no txHash / no tx_exec.json update). Continuing..."
    Start-Sleep -Seconds $SleepSec
    continue
  }
}
