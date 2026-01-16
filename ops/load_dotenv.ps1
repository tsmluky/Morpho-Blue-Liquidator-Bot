[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Path
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Path)) {
  throw "dotenv file not found: $Path"
}

Get-Content -LiteralPath $Path | ForEach-Object {
  $line = $_.Trim()
  if (-not $line) { return }
  if ($line.StartsWith("#")) { return }

  # Support "export KEY=VAL"
  if ($line.StartsWith("export ")) {
    $line = $line.Substring(7).Trim()
  }

  # split on first '='
  $idx = $line.IndexOf("=")
  if ($idx -lt 1) { return }

  $key = $line.Substring(0, $idx).Trim()
  $val = $line.Substring($idx + 1)

  if (-not $key) { return }

  $val = $val.Trim()

  # If value is quoted, keep everything inside quotes verbatim (except outer quotes)
  $isDoubleQuoted = $val.StartsWith('"')
  $isSingleQuoted = $val.StartsWith("'")

  if (($isDoubleQuoted -and $val.EndsWith('"')) -or ($isSingleQuoted -and $val.EndsWith("'"))) {
    $val = $val.Substring(1, $val.Length - 2)
  } else {
    # Strip inline comments for unquoted values: KEY=foo # comment
    # Keep anything before the first ' #' sequence.
    $commentIdx = $val.IndexOf(" #")
    if ($commentIdx -ge 0) {
      $val = $val.Substring(0, $commentIdx).Trim()
    }
  }

  Set-Item -Path ("Env:{0}" -f $key) -Value $val
}
