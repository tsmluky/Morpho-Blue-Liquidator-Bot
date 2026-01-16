# ops/fix_plan_and_tools.ps1
# Parchea plan.ts + instala tools de inspección de opportunities.csv

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Assert-RepoRoot {
  if (-not (Test-Path ".\package.json")) { throw "Ejecuta esto desde la raíz del repo (donde está package.json)." }
  if (-not (Test-Path ".\src\commands\plan.ts")) { throw "No existe .\src\commands\plan.ts en este directorio." }
  if (-not (Test-Path ".\data")) { New-Item -ItemType Directory -Force .\data | Out-Null }
}

function Patch-PlanTs {
  $target = Resolve-Path ".\src\commands\plan.ts"
  $src = Get-Content -LiteralPath $target -Raw -Encoding UTF8

  $changed = 0

  # 1) isQuoted: hoy está leyendo passQuoted por error. Queremos preferir isQuoted si existe.
  $patIsQuoted = 'const\s+isQuoted\s*=\s*\(r\["passQuoted"\]\s*\?\?\s*"0"\)\s*===\s*"1"\s*;'
  if ($src -match $patIsQuoted) {
    $repIsQuoted = 'const isQuoted = String(r["isQuoted"] ?? r["passQuoted"] ?? "0").trim() === "1";'
    $src = [regex]::Replace($src, $patIsQuoted, $repIsQuoted, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $changed++
  }

  # 2) passModel opcional: si la col no existe o viene vacía, NO bloquear (neutral = true)
  $patPassModel = 'const\s+passModel\s*=\s*\(r\["passModel"\]\s*\?\?\s*"0"\)\s*===\s*"1"\s*;'
  if ($src -match $patPassModel) {
    $repPassModel = @'
const passModelRaw = String(r["passModel"] ?? "").trim();
// Si la columna no existe o viene vacía, no bloquear (neutral=true).
// Si existe, respeta 0/1.
const passModel = passModelRaw === "" ? true : passModelRaw === "1";
