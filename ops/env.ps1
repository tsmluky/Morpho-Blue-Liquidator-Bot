[CmdletBinding()]
param(
  [string]$RpcUrl = "",
  [switch]$ExecOn
)

$ErrorActionPreference="Stop"

# Move to repo root (one level above /ops)
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Repo

function Set-EnvIfEmpty([string]$Name, [string]$Value) {
  if ([string]::IsNullOrWhiteSpace($env:$Name)) { $env:$Name = $Value }
}

function Load-DotEnvFile([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  Get-Content $Path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) { return }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { return }
    $k = $line.Substring(0,$idx).Trim()
    $v = $line.Substring($idx+1).Trim()
    # strip optional quotes
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
      $v = $v.Substring(1, $v.Length-2)
    }
    if ($k) { $env:$k = $v }
  }
}

function Assert-Url([string]$Name) {
  $v = ($env:$Name ?? "").Trim()
  try {
    $u = [Uri]$v
    if ($u.Scheme -notin @("http","https")) { throw "bad scheme" }
  } catch {
    throw "Invalid $Name. Must be http(s) URL. Got: '$v'"
  }
}

function Assert-Addr([string]$Name) {
  $v = ($env:$Name ?? "").Trim()
  if ($v -notmatch '^0x[a-fA-F0-9]{40}$') { throw "Invalid $Name address: '$v'" }
}

# Load local env if present
Load-DotEnvFile (Join-Path $Repo ".env.local")

# Allow override from param
if ($RpcUrl) { $env:ARB_RPC_URL = $RpcUrl }

# Defaults (only if empty)
Set-EnvIfEmpty "MORPHO_ADDR" "0x6c247b1F6182318877311737BaC0844bAa518F5e"
Set-EnvIfEmpty "ALLOW_EXEC_NO_MODEL" "1"
Set-EnvIfEmpty "ALLOW_EXEC_WITH_DEGRADED_PRICING" "1"
Set-EnvIfEmpty "MAX_MARKETS" "250"
Set-EnvIfEmpty "HOT_QUEUE" "300"
Set-EnvIfEmpty "PLAN_MAX_OPP_AGE_SEC" "120"
Set-EnvIfEmpty "PLAN_MIN_PROXIMITY" "1.0000"
Set-EnvIfEmpty "ETH_PRICE_MAX_AGE_SEC" "600"
Set-EnvIfEmpty "ETH_USD_MAX_AGE_SEC" "600"
Set-EnvIfEmpty "EXEC_ENABLED" ($(if($ExecOn){ "1" } else { "0" }))

# Validate required bits
Assert-Url "ARB_RPC_URL"
Assert-Addr "MORPHO_ADDR"
if ($env:EXEC_ENABLED -eq "1") {
  Assert-Addr "EXECUTOR_ADDR"
}

# Nice summary
Write-Host ""
Write-Host "ENV READY @ $Repo"
Write-Host ("ARB_RPC_URL={0}" -f $env:ARB_RPC_URL)
Write-Host ("MORPHO_ADDR={0}" -f $env:MORPHO_ADDR)
Write-Host ("CALLER_ADDR={0}" -f ($env:CALLER_ADDR ?? ""))
Write-Host ("EXECUTOR_ADDR={0}" -f ($env:EXECUTOR_ADDR ?? ""))
Write-Host ("EXEC_ENABLED={0}" -f $env:EXEC_ENABLED)
Write-Host ("MAX_MARKETS={0} HOT_QUEUE={1}" -f $env:MAX_MARKETS, $env:HOT_QUEUE)
Write-Host ("PLAN_MAX_OPP_AGE_SEC={0} PLAN_MIN_PROXIMITY={1}" -f $env:PLAN_MAX_OPP_AGE_SEC, $env:PLAN_MIN_PROXIMITY)
Write-Host ("ETH_PRICE_MAX_AGE_SEC={0} ETH_USD_MAX_AGE_SEC={1}" -f $env:ETH_PRICE_MAX_AGE_SEC, $env:ETH_USD_MAX_AGE_SEC)
Write-Host ""
