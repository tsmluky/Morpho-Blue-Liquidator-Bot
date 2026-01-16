param(
  [int]$SleepSec = 6
)

$ErrorActionPreference="Stop"
Set-Location "$HOME\Desktop\morpho-liquidator-v0"

function Beep-One {
  try { [console]::Beep(900,120) } catch { Write-Host "`a" }
}
function Beep-Double {
  try {
    [console]::Beep(1100,140)
    Start-Sleep -Milliseconds 120
    [console]::Beep(1100,140)
  } catch {
    Write-Host "`a`a"
  }
}

function Run-Step([string]$name, [string]$cmd) {
  Write-Host "`n=== $name ==="
  $out = Invoke-Expression $cmd 2>&1 | Out-String
  $out | Out-Host
  return $out
}

function Get-ExecBuilt {
  $p = ".\data\tx_plan.json"
  if (-not (Test-Path $p)) { return 0 }
  try {
    $o = Get-Content $p -Raw | ConvertFrom-Json
    return [int]($o.execBuilt ?? 0)
  } catch { return 0 }
}

while ($true) {
  Run-Step "scan" "pnpm -s run scan" | Out-Null
  Run-Step "simulate" "pnpm -s run simulate" | Out-Null
  Run-Step "plan" "pnpm -s run plan" | Out-Null

  $execBuilt = Get-ExecBuilt
  if ($execBuilt -gt 0) {
    Write-Host ("execBuilt={0} (candidate tx plan found)" -f $execBuilt)
    Beep-One
  } else {
    Write-Host ("execBuilt={0}" -f $execBuilt)
  }

  $dryOut = Run-Step "dryrun" "pnpm -s tsx .\scripts\dryrun_plan_orders.ts"

  # Beep “cada vez que aparezca una transacción”:
  # - si el dryrun imprimió cualquier [OK]/[FAIL]/[SKIP_HEALTHY] significa que hubo item(s) para intentar.
  if ($dryOut -match "\[(OK|FAIL|SKIP_HEALTHY)\]") {
    Beep-One
  }

  # Si hay OK, ejecutamos automáticamente y hacemos beep doble si sale txHash o se escribe tx_exec.json
  if ($dryOut -match "\[OK\]") {
    Write-Host "`nFOUND [OK]. Broadcasting..."
    $execOut = Run-Step "exec" "pnpm -s run exec"

    $txFile = ".\data\tx_exec.json"
    $hasTxHashInStdout = ($execOut -match "txHash")
    $hasTxFile = (Test-Path $txFile)

    if ($hasTxHashInStdout -or $hasTxFile) {
      Beep-Double
      Write-Host "`nTX SENT. Check data/tx_exec.json (or explorer) for txHash."
    } else {
      Write-Host "`nExec ran but txHash not detected. Review output above."
    }

    break
  }

  Start-Sleep -Seconds $SleepSec
}
