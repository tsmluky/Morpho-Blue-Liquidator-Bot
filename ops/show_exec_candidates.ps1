# ops/show_exec_candidates.ps1
# Muestra filas candidatas a EXEC desde data/opportunities.csv
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$csvPath = ".\data\opportunities.csv"
if (-not (Test-Path $csvPath)) { throw "Missing $csvPath (run: pnpm -s run scan ; pnpm -s run simulate)" }
$rows = Import-Csv $csvPath
if (-not $rows -or $rows.Count -eq 0) { throw "CSV vacío: $csvPath" }

$minExec = [double]([string]($env:PLAN_MIN_EXEC_PROXIMITY ?? "1.002"))

$execRows = $rows | Where-Object {
  ($_.status -eq "exec_ready") -or ([double]$_.proximity -ge $minExec)
}

Write-Host ("PLAN_MIN_EXEC_PROXIMITY={0}" -f $minExec)
Write-Host ("ExecCandidate rows: {0}" -f $execRows.Count)
Write-Host ""

if ($execRows.Count -gt 0) {
  $execRows | Sort-Object {[double]$_.netProfitUsd} -Descending |
    Select-Object -First 25 ts,status,proximity,netProfitUsd,isQuoted,passQuoted,passExec,passModel,quoteMode,uniPath,note,candidateId |
    Format-Table -AutoSize
} else {
  Write-Host "No exec candidates found in CSV given current threshold."
}
