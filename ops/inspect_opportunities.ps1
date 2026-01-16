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
