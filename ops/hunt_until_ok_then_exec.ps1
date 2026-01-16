param(
  [int]$SleepSec = 6
)

$ErrorActionPreference="Stop"
Set-Location "$HOME\Desktop\morpho-liquidator-v0"

function Beep-Alarm {
  try {
    1..5 | ForEach-Object { [console]::Beep(1100,150); Start-Sleep -Milliseconds 80 }
  } catch {
    # fallback si Beep no funciona en tu host
    Write-Host "`a`a`a"
  }
}

function Run-Step([string]$name, [string]$cmd) {
  Write-Host "`n=== $name ==="
  $out = Invoke-Expression $cmd 2>&1 | Out-String
  $out | Out-Host
  return $out
}

while ($true) {
  Run-Step "scan" "pnpm -s run scan" | Out-Null
  Run-Step "simulate" "pnpm -s run simulate" | Out-Null
  Run-Step "plan" "pnpm -s run plan" | Out-Null
  $dryOut = Run-Step "dryrun" "pnpm -s tsx .\scripts\dryrun_plan_orders.ts"

  if ($dryOut -match "\[OK\]") {
    Write-Host "`nFOUND OK DRYRUN. EXECUTING NOW..."
    Beep-Alarm
    Run-Step "exec" "pnpm -s run exec" | Out-Null
    Beep-Alarm
    break
  }

  if ($dryOut -match "position is healthy") {
    Write-Host "`nCandidate flipped healthy. Continue hunting..."
  } else {
    Write-Host "`nNo OK yet. Continue hunting..."
  }

  Start-Sleep -Seconds $SleepSec
}
