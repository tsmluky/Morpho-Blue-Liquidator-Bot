[CmdletBinding()]
param(
  [string]$Root = "$env:USERPROFILE\Desktop\morpho-liquidator-v0",
  [string]$OutDir = "$env:USERPROFILE\Desktop\_share",
  [string]$Name = "morpho-liquidator-v0",
  [switch]$IncludeData,   # si NO lo pasas, data/ se incluye igual; este flag queda para extenderlo
  [switch]$VerboseList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }

if (-not (Test-Path $Root)) { throw "Root not found: $Root" }

# Output folder
New-Dir $OutDir

# Stamp
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$zipPath = Join-Path $OutDir ("{0}_{1}.zip" -f $Name, $stamp)
$treePath = Join-Path $OutDir ("{0}_{1}_TREE.txt" -f $Name, $stamp)
$listPath = Join-Path $OutDir ("{0}_{1}_FILES.txt" -f $Name, $stamp)
$metaPath = Join-Path $OutDir ("{0}_{1}_MANIFEST.json" -f $Name, $stamp)

# Exclusion rules (directories + file patterns)
$excludeDirNames = @(
  "node_modules", ".git", ".next", "dist", "build", "out",
  ".turbo", ".cache", "coverage", ".pytest_cache",
  "artifacts", "cache", "tmp", ".venv", "venv",
  ".idea", ".vscode", ".DS_Store"
)

# Secrets / sensitive files (add more if needed)
$excludeFileRegex = @(
  '\.env(\..+)?$',            # .env, .env.local, etc
  '\.pem$', '\.key$', '\.p12$', '\.pfx$',
  'id_rsa$', 'id_ed25519$',
  'secrets?\.json$', 'credentials?\.json$',
  'private[-_]?key',          # catch-all
  'alchemy\.com\/v2\/',       # if you accidentally stored endpoint in plaintext somewhere
  'mnemonic', 'seed', 'api[_-]?key'
)

# Build file list
Write-Host "Scanning: $Root"
$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
  $full = $_.FullName
  $rel  = $full.Substring($Root.Length).TrimStart('\','/')

  # Skip excluded directories by segment match
  foreach ($d in $excludeDirNames) {
    if ($rel -match ("(^|[\\/]){0}([\\/]|$)" -f [regex]::Escape($d))) { return }
  }

  # Skip sensitive patterns by name/path heuristics
  foreach ($rx in $excludeFileRegex) {
    if ($rel -match $rx) { return }
  }

  # Skip huge common junk
  if ($rel -match '(^|[\\/])package-lock\.json$' -or $rel -match '(^|[\\/])yarn\.lock$') {
    # keep pnpm-lock.yaml usually; but you can keep these if you use them
    # return
  }

  $_
}

if (-not $files -or $files.Count -eq 0) { throw "No files selected after exclusions (check rules)." }

# TREE (Windows tree is directory-based; we run it from root)
Write-Host "Writing TREE: $treePath"
Push-Location $Root
try {
  # tree output can be large; /F includes files, /A ASCII
  cmd /c "tree /F /A" | Out-File -FilePath $treePath -Encoding UTF8
} finally {
  Pop-Location
}

# FILES inventory with sizes
Write-Host "Writing FILES inventory: $listPath"
$files |
  Sort-Object FullName |
  ForEach-Object {
    $rel = $_.FullName.Substring($Root.Length).TrimStart('\','/')
    "{0}`t{1}" -f $_.Length, $rel
  } | Out-File -FilePath $listPath -Encoding UTF8

# Manifest
$manifest = [ordered]@{
  name = $Name
  createdAt = (Get-Date).ToString("o")
  root = $Root
  zipPath = $zipPath
  counts = [ordered]@{
    files = $files.Count
    totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
  }
  exclusions = [ordered]@{
    dirs = $excludeDirNames
    fileRegex = $excludeFileRegex
  }
}
$manifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $metaPath -Encoding UTF8

# Create zip (staging copy to temp to preserve structure without excluded dirs)
$tmp = Join-Path $env:TEMP ("zipstage_{0}_{1}" -f $Name, $stamp)
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Dir $tmp

Write-Host "Staging files to: $tmp"
foreach ($f in $files) {
  $rel = $f.FullName.Substring($Root.Length).TrimStart('\','/')
  $dst = Join-Path $tmp $rel
  $dstDir = Split-Path -Parent $dst
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
  Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
}

# Also include the generated TREE/FILES/MANIFEST inside the zip root as _share_meta/
$metaDir = Join-Path $tmp "_share_meta"
New-Dir $metaDir
Copy-Item -LiteralPath $treePath -Destination (Join-Path $metaDir (Split-Path $treePath -Leaf)) -Force
Copy-Item -LiteralPath $listPath -Destination (Join-Path $metaDir (Split-Path $listPath -Leaf)) -Force
Copy-Item -LiteralPath $metaPath -Destination (Join-Path $metaDir (Split-Path $metaPath -Leaf)) -Force

Write-Host "Creating ZIP: $zipPath"
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

# Prefer .NET zip for speed/reliability
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($tmp, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# Cleanup staging
Remove-Item -Recurse -Force $tmp

# Summary
$zipInfo = Get-Item $zipPath
$mb = [Math]::Round($zipInfo.Length / 1MB, 2)

Write-Host ""
Write-Host "DONE"
Write-Host ("ZIP:  {0} ({1} MB)" -f $zipPath, $mb)
Write-Host ("TREE: {0}" -f $treePath)
Write-Host ("LIST: {0}" -f $listPath)
Write-Host ("MANI: {0}" -f $metaPath)

if ($VerboseList) {
  Write-Host ""
  Write-Host "First 50 files included:"
  $files | Select-Object -First 50 | ForEach-Object {
    $_.FullName.Substring($Root.Length).TrimStart('\','/')
  }
}
