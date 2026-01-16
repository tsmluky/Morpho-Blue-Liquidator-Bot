# ops/patch_plan_passmodel_optional.ps1
# Hace que passModel NO bloquee si la columna no existe o viene vacía.

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = Join-Path (Get-Location) "src\commands\plan.ts"
if (-not (Test-Path $target)) { throw "No existe: $target (ejecuta desde la raíz del repo)" }

$src = Get-Content -LiteralPath $target -Raw -Encoding UTF8

# Reemplaza: const passModel = (r["passModel"] ?? "0") === "1";
# Por lógica robusta:
$pattern = 'const\s+passModel\s*=\s*\(r\["passModel"\]\s*\?\?\s*"0"\)\s*===\s*"1";'
$replacement = @'
const passModelRaw = String(r["passModel"] ?? "").trim();
// Si la columna no existe o viene vacía, NO bloquear (neutral = true).
// Si existe, respeta 0/1.
const passModel = passModelRaw === "" ? true : passModelRaw === "1";
