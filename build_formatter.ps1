# ============================================================
#  build_formatter.ps1  -  builds lambda_function.zip for cheche-excel-formatter
#  Run from D:\Backed_up\Cheche\cheche-infrastructure
#
#  First run (-Init): creates requirements.txt and fonts\ in lambda\excel-formatter
#  from the live package captured in the latest snapshot, so the build reproduces
#  exactly what is running today.
#
#  Normal run: pip installs Linux (manylinux2014, Python 3.12) wheels, adds the
#  handler + fonts, zips to .\lambda_function.zip (git-ignored).
#  -FromLivePackage: skip pip and reuse the snapshot's dependencies instead.
# ============================================================
param([switch]$Init, [switch]$FromLivePackage)
$ErrorActionPreference = 'Stop'
$src   = Join-Path $PSScriptRoot 'lambda\excel-formatter'
$build = Join-Path $env:TEMP 'cheche_formatter_build'
$zip   = Join-Path $PSScriptRoot 'lambda_function.zip'

function LivePackage {
  $snap = Get-ChildItem D:\Backed_up\Cheche_Snapshots -Directory | Sort-Object Name | Select-Object -Last 1
  $p = Join-Path $snap.FullName 'lambda\cheche-excel-formatter\code'
  if (-not (Test-Path $p)) { throw "Live package not found at $p - run cheche_snapshot.ps1 first." }
  return $p
}

if (-not (Test-Path (Join-Path $src 'lambda_function.py'))) { throw "Missing $src\lambda_function.py" }

# ---- Init: requirements.txt + fonts from the live package ----
if ($Init) {
  $live = LivePackage
  $reqs = Get-ChildItem $live -Directory -Filter '*.dist-info' | ForEach-Object {
    $stem = $_.Name -replace '\.dist-info$',''
    $i = $stem.LastIndexOf('-'); "{0}=={1}" -f $stem.Substring(0,$i), $stem.Substring($i+1)
  } | Sort-Object
  $reqs | Set-Content (Join-Path $src 'requirements.txt') -Encoding ascii
  Write-Host "[init] requirements.txt:" -ForegroundColor Green; $reqs | ForEach-Object { "        $_" }
  if (Test-Path (Join-Path $live 'fonts')) {
    Copy-Item (Join-Path $live 'fonts') $src -Recurse -Force
    Write-Host "[init] fonts copied: $((Get-ChildItem (Join-Path $src 'fonts')).Name -join ', ')" -ForegroundColor Green
  } else { Write-Host "[init] WARNING: live package has no fonts folder" -ForegroundColor Yellow }
}

if (-not (Test-Path (Join-Path $src 'requirements.txt'))) { throw "No requirements.txt - run with -Init first." }

# ---- Build ----
if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory $build | Out-Null

$pipOk = $false
if (-not $FromLivePackage) {
  try { python -m pip --version *> $null; $pipOk = ($LASTEXITCODE -eq 0) } catch { $pipOk = $false }
}
if ($pipOk) {
  Write-Host "[build] installing Linux wheels with pip ..." -ForegroundColor Cyan
  python -m pip install -r (Join-Path $src 'requirements.txt') --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12 --implementation cp -t $build --quiet
  if ($LASTEXITCODE -ne 0) { throw "pip install failed - rerun with -FromLivePackage" }
} else {
  $live = LivePackage
  Write-Host "[build] using dependencies from the live package: $live" -ForegroundColor Yellow
  Get-ChildItem $live | Where-Object { $_.Name -notin @('lambda_function.py','fonts') } | Copy-Item -Destination $build -Recurse -Force
}

Copy-Item (Join-Path $src 'lambda_function.py') $build -Force
if (Test-Path (Join-Path $src 'fonts')) { Copy-Item (Join-Path $src 'fonts') $build -Recurse -Force }

# ---- Sanity checks ----
$checks = @{ 'handler' = 'lambda_function.py'; 'openpyxl' = 'openpyxl'; 'Pillow' = 'PIL'; 'font' = 'fonts\DejaVuSans.ttf' }
$bad = $checks.GetEnumerator() | Where-Object { -not (Test-Path (Join-Path $build $_.Value)) }
if ($bad) { throw "Build incomplete, missing: $(($bad | ForEach-Object { $_.Key }) -join ', ')" }
if (-not (Select-String -Path (Join-Path $build 'lambda_function.py') -Pattern '_reserve_download' -Quiet)) { throw "Handler is not the payment-gated version" }

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $build '*') -DestinationPath $zip
Write-Host ("[build] lambda_function.zip ready: {0:N1} MB, payment gate present, fonts present" -f ((Get-Item $zip).Length/1MB)) -ForegroundColor Green
