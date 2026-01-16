# ops/debug_passExec.ps1
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$csvPath = ".\data\opportunities.csv"
if (-not (Test-Path $csvPath)) { throw "Missing $csvPath (run: pnpm -s run scan ; pnpm -s run simulate)" }
$rows = Import-Csv $csvPath
if (-not $rows -or $rows.Count -eq 0) { throw "CSV vacío: $csvPath" }

function AsNum($s){ if($null -eq $s){ return [double]0 }; return [double]([string]$s) }
function Is1($s){ return ([string]$s).Trim() -eq "1" }

$minExec = [double]([string]($env:PLAN_MIN_EXEC_PROXIMITY ?? "1.002"))
Write-Host ("Rows={0}  PLAN_MIN_EXEC_PROXIMITY={1}" -f $rows.Count, $minExec)
Write-Host ""

$pExec = $rows | Where-Object { Is1 $_.passExec }
Write-Host ("passExec=1 rows: {0}" -f $pExec.Count)
if ($pExec.Count -gt 0) {
  $pExec | Sort-Object { AsNum $_.netProfitUsd } -Descending |
    Select-Object -First 20 ts,status,proximity,netProfitUsd,isQuoted,passQuoted,passExec,passModel,quoteMode,note,candidateId |
    Format-Table -AutoSize
}
Write-Host ""

$execReady = $rows | Where-Object { $_.status -eq "exec_ready" }
Write-Host ("exec_ready rows: {0}" -f $execReady.Count)
if ($execReady.Count -gt 0) {
  $execReady | Sort-Object { AsNum $_.netProfitUsd } -Descending |
    Select-Object -First 20 ts,proximity,netProfitUsd,isQuoted,passQuoted,passExec,passModel,quoteMode,note,candidateId |
    Format-Table -AutoSize
}
Write-Host ""

$noRoute = $rows | Where-Object { ([string]$_.quoteMode) -eq "no_route" }
Write-Host ("quoteMode=no_route rows: {0}" -f $noRoute.Count)
if ($noRoute.Count -gt 0) {
  $noRoute | Select-Object -First 10 ts,status,proximity,netProfitUsd,isQuoted,passExec,quoteMode,candidateId |
    Format-Table -AutoSize
}
