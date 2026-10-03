<#
One-shot build script for StockTool Kiosk (Part 7 - cloud setup).
Run this in a PowerShell window (not pasted line-by-line elsewhere).

    powershell -ExecutionPolicy Bypass -File C:\StockTool\build-all.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "== 1. Checking Python ==" -ForegroundColor Cyan
$pyOk = $false
try {
    $pyVersion = & python --version 2>&1
    if ($LASTEXITCODE -eq 0 -and $pyVersion -match "Python 3") {
        Write-Host "Found: $pyVersion" -ForegroundColor Green
        $pyOk = $true
    }
} catch {}

if (-not $pyOk) {
    Write-Host ""
    Write-Host "Python is not installed / not on PATH." -ForegroundColor Red
    Write-Host "Go to https://www.python.org/downloads/ , download and run the installer," -ForegroundColor Yellow
    Write-Host "TICK 'Add python.exe to PATH' on the first screen, install it, then close" -ForegroundColor Yellow
    Write-Host "this window entirely and open a brand new PowerShell before re-running this script." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "== 2. Locating stocktool-kiosk-v2-part7-cloud-setup.zip ==" -ForegroundColor Cyan
$zip = Get-ChildItem -Path C:\,D:\ -Filter "stocktool-kiosk-v2-part7*.zip" -Recurse -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $zip) {
    Write-Host ""
    Write-Host "Could not find stocktool-kiosk-v2-part7-cloud-setup.zip anywhere on C:\ or D:\." -ForegroundColor Red
    Write-Host "Download it from the chat (the file Claude shared) and save it into your" -ForegroundColor Yellow
    Write-Host "Downloads folder on THIS machine, then re-run this script." -ForegroundColor Yellow
    exit 1
}
Write-Host "Found: $($zip.FullName)" -ForegroundColor Green

Write-Host ""
Write-Host "== 3. Extracting to C:\StockTool\kiosk-v2 ==" -ForegroundColor Cyan
$dest = "C:\StockTool\kiosk-v2"
New-Item -ItemType Directory -Force -Path "C:\StockTool" | Out-Null
if (Test-Path $dest) {
    Write-Host "Removing previous extraction at $dest" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $dest
}
Expand-Archive -Path $zip.FullName -DestinationPath "C:\StockTool"
# The zip contains a top-level 'kiosk-patched' folder — normalize its name.
if (Test-Path "C:\StockTool\kiosk-patched") {
    Rename-Item "C:\StockTool\kiosk-patched" "kiosk-v2"
}
if (-not (Test-Path "$dest\main.py")) {
    Write-Host "ERROR: extraction didn't produce $dest\main.py — check what actually unzipped:" -ForegroundColor Red
    Get-ChildItem "C:\StockTool" -Recurse -Depth 1
    exit 1
}
Write-Host "Extracted OK." -ForegroundColor Green

Write-Host ""
Write-Host "== 4. Creating venv + installing requirements ==" -ForegroundColor Cyan
Set-Location $dest
python -m venv venv
if (-not (Test-Path ".\venv\Scripts\pip.exe")) {
    Write-Host "ERROR: venv creation failed (no venv\Scripts\pip.exe)." -ForegroundColor Red
    exit 1
}
.\venv\Scripts\pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: pip install failed — see output above." -ForegroundColor Red
    exit 1
}
Write-Host "Dependencies installed." -ForegroundColor Green

Write-Host ""
Write-Host "== 5. Building (PyInstaller + WiX) ==" -ForegroundColor Cyan
Set-Location "$dest\installer"

# build.ps1's -NssmPath is mandatory -- calling it bare (as this script
# did before) leaves PowerShell sitting on a silent parameter prompt
# instead of running the build. Auto-download nssm.exe first if it's
# not already there, same as build-and-verify.bat's self-heal step,
# then always pass -NssmPath explicitly.
$nssmPath = "$dest\installer\nssm.exe"
if (-not (Test-Path $nssmPath)) {
    Write-Host "nssm.exe not found -- downloading it..." -ForegroundColor Yellow
    $nssmZip = Join-Path $env:TEMP "nssm.zip"
    $nssmExtract = Join-Path $env:TEMP "nssm-extract"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
    if (Test-Path $nssmExtract) { Remove-Item -Recurse -Force $nssmExtract }
    Expand-Archive -Path $nssmZip -DestinationPath $nssmExtract -Force
    $found = Get-ChildItem -Path $nssmExtract -Recurse -Filter "nssm.exe" |
             Where-Object { $_.FullName -match "win64" } | Select-Object -First 1
    if (-not $found) {
        Write-Host "ERROR: win64 nssm.exe not found in the downloaded archive." -ForegroundColor Red
        exit 1
    }
    Copy-Item -Path $found.FullName -Destination $nssmPath -Force
    Write-Host "nssm.exe installed at $nssmPath" -ForegroundColor Green
}

.\build.ps1 -NssmPath $nssmPath -Verify
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: build.ps1 exited with code $LASTEXITCODE — scroll up for the actual error." -ForegroundColor Red
    exit 1
}

Write-Host ""
if (Test-Path "$dest\dist\StockToolKiosk.msi") {
    Write-Host "DONE. New installer at: $dest\dist\StockToolKiosk.msi" -ForegroundColor Green
    Write-Host "Uninstall the old StockTool Kiosk first (Settings > Apps), then install this one." -ForegroundColor Yellow
} else {
    Write-Host "build.ps1 finished but dist\StockToolKiosk.msi wasn't found — check the output above for errors." -ForegroundColor Red
}