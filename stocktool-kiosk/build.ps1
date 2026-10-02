<#
.SYNOPSIS
    Builds a new StockTool Kiosk release: the .exe (PyInstaller) and the
    .msi installer (WiX), with checksums and an optional end-to-end
    verification pass.

.DESCRIPTION
    Run this on a WINDOWS machine with Python and the WiX Toolset (the
    modern "wix.exe build" CLI - v4/v5/v6+, not the old v3
    candle.exe/light.exe pair, which Product.wxs no longer targets)
    installed. This cannot be run from Linux/macOS - PyInstaller does
    not cross-compile, and the WiX toolchain is Windows-only.

    Steps:
      1. Check prerequisites (wix.exe on PATH, nssm.exe, the WiX UI
         extension - adding it automatically if missing)
      2. (Optional) bump version.py
      3. pip install -r requirements.txt into a clean venv
      4. pyinstaller build.spec --clean  ->  dist\StockToolKiosk.exe
      5. wix.exe build Product.wxs      ->  installer\StockToolKiosk.msi
      6. Write checksums.txt with both files' SHA-256
      7. (Optional, -Verify) stop any running instance, launch the fresh
         exe, and confirm it actually serves the kiosk UI at
         http://127.0.0.1:<port>/ui/ before declaring success
      8. (Optional, -Publish) publish the built .exe as a new release via
         scripts\publish_release.py, which is what makes every already-
         paired kiosk self-update (see sync_loop.py / updater.py) - no
         separate "push" step needed beyond that

.PARAMETER Version
    New version string (e.g. "2.2.0"). If omitted, uses whatever is
    already in version.py.

.PARAMETER NssmPath
    Path to nssm.exe (download from https://nssm.cc/download - not
    redistributed in this repo). Required to build the MSI.

.PARAMETER Verify
    After building, stop any running StockToolKiosk.exe, launch the
    freshly built one, and check that it actually serves the kiosk UI
    (looks for known markers in the /ui/ page's HTML) before reporting
    success. Leaves the fresh instance running on success.

.PARAMETER Publish
    If set, also publishes the built .exe as a new release via
    scripts\publish_release.py. Needs -ApiBase, -AdminUser, -AdminPass,
    and -DownloadUrl (wherever you're hosting the .exe for kiosks to
    download from - this script does not upload it anywhere itself).

.EXAMPLE
    .\build.ps1 -Version 2.2.0 -NssmPath C:\tools\nssm.exe -Verify

.EXAMPLE
    .\build.ps1 -NssmPath C:\tools\nssm.exe -Publish `
        -ApiBase https://api.opslabsystems.cloud `
        -AdminUser admin -AdminPass "..." `
        -DownloadUrl https://cdn.opslabsystems.cloud/StockToolKiosk.exe
#>
param(
    [string]$Version,
    [Parameter(Mandatory=$true)][string]$NssmPath,
    [switch]$Verify,
    [switch]$Publish,
    [string]$ApiBase,
    [string]$AdminUser,
    [string]$AdminPass,
    [string]$DownloadUrl,
    [string]$ReleaseNotes = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallerDir = Join-Path $Root "installer"

function Write-Step($msg) { Write-Host "" ; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  OK: $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "  WARNING: $msg" -ForegroundColor Yellow }

# --- 0. Prerequisites -----------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Test-Path $NssmPath)) {
    throw "nssm.exe not found at $NssmPath - download it from https://nssm.cc/download first."
}
Write-Ok "nssm.exe found at $NssmPath"

$wix = Get-Command wix.exe -ErrorAction SilentlyContinue
if (-not $wix) {
    throw "wix.exe not found on PATH. Install the WiX Toolset CLI (dotnet tool install --global wix, " +
          "or see https://wixtoolset.org/) and re-open this shell so PATH picks it up."
}
$wixVersion = (& wix.exe --version) 2>$null
Write-Ok "wix.exe found ($wixVersion)"

$extensions = (& wix.exe extension list --global) 2>$null
if (-not ($extensions -match "WixToolset\.UI\.wixext")) {
    Write-Warn2 "WixToolset.UI.wixext not found - installing it now"
    $extAddOutput = (& wix.exe extension add WixToolset.UI.wixext --global) 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($extAddOutput | Out-String)
        throw "Could not install WixToolset.UI.wixext (see output above)."
    }
}
Write-Ok "WixToolset.UI.wixext available"

# --- 1. Version bump --------------------------------------------------------
if ($Version) {
    Write-Step "Bumping version.py to $Version"
    $versionFile = Join-Path $Root "version.py"
    (Get-Content $versionFile) -replace '__version__ = ".*"', "__version__ = `"$Version`"" |
        Set-Content $versionFile
}
$Version = (Select-String -Path (Join-Path $Root "version.py") -Pattern '__version__ = "(.*)"').Matches[0].Groups[1].Value
Write-Host "Building version $Version"

# --- 2. Python environment ---------------------------------------------------
Write-Step "Setting up build venv"
$venv = Join-Path $Root ".build-venv"
if (-not (Test-Path $venv)) {
    python -m venv $venv
}
$py = Join-Path $venv "Scripts\python.exe"
& $py -m pip install --upgrade pip | Out-Null
& $py -m pip install -r (Join-Path $Root "requirements.txt") | Out-Null
& $py -m pip show pyinstaller | Out-Null
if ($LASTEXITCODE -ne 0) { & $py -m pip install pyinstaller | Out-Null }

# --- 3. Stop anything currently running, so file locks don't block the build
#
# NOTE: if StockToolKioskAPI is installed as an NSSM service (see
# SetupWizard.ps1), NSSM is configured with "AppExit Default Restart"
# (3s restart delay) - killing just the process isn't enough, since
# NSSM will relaunch it a few seconds later and can still hold the
# exe/dll files locked. Stop the *service* first, then fall back to
# killing the bare process. Either way this is best-effort cleanup and
# must never abort the build - if it's still locked, PyInstaller will
# surface a clear file-in-use error later anyway.
Write-Step "Stopping any running StockToolKiosk.exe"
$svc = Get-Service -Name "StockToolKioskAPI" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne "Stopped") {
    try {
        & $NssmPath stop StockToolKioskAPI | Out-Null
        Write-Ok "Stopped the StockToolKioskAPI service"
    } catch {
        Write-Host "  WARNING: couldn't stop the StockToolKioskAPI service ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host "  Re-run this script from an elevated (Run as Administrator) PowerShell to stop it." -ForegroundColor Yellow
    }
}
try {
    Get-Process StockToolKiosk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
} catch {
    Write-Host "  WARNING: couldn't stop a running StockToolKiosk.exe ($($_.Exception.Message))." -ForegroundColor Yellow
    Write-Host "  It's likely still running under the service/a higher-privilege account." -ForegroundColor Yellow
    Write-Host "  If PyInstaller fails below with a locked file, stop it manually (elevated: 'nssm stop StockToolKioskAPI') and re-run." -ForegroundColor Yellow
}
Start-Sleep -Seconds 1

# --- 4. PyInstaller -----------------------------------------------------------
Write-Step "Running PyInstaller (build.spec)"
Push-Location $Root
& $py -m PyInstaller build.spec --clean --noconfirm
$pyinstallerExit = $LASTEXITCODE
Pop-Location
if ($pyinstallerExit -ne 0) { throw "PyInstaller failed (exit $pyinstallerExit)." }

$exePath = Join-Path $Root "dist\StockToolKiosk.exe"
if (-not (Test-Path $exePath)) { throw "PyInstaller did not produce $exePath" }
Write-Ok "$exePath ($((Get-Item $exePath).Length) bytes)"

# --- 5. WiX MSI -----------------------------------------------------------------
Write-Step "Building MSI (wix.exe build)"
Push-Location $InstallerDir
& wix.exe build "Product.wxs" `
    -arch x64 `
    -ext WixToolset.UI.wixext `
    -d "ProductVersion=$Version" `
    -d "NssmSrc=$NssmPath" `
    -o "StockToolKiosk.msi"
$wixExit = $LASTEXITCODE
Pop-Location
if ($wixExit -ne 0) { throw "wix.exe build failed (exit $wixExit) - scroll up for the WiX error." }

$msiPath = Join-Path $InstallerDir "StockToolKiosk.msi"
if (-not (Test-Path $msiPath)) { throw "WiX did not produce $msiPath" }
Write-Ok "$msiPath ($((Get-Item $msiPath).Length) bytes)"

# --- 6. Checksums -----------------------------------------------------------------
Write-Step "Computing checksums"
$exeHash = (Get-FileHash $exePath -Algorithm SHA256).Hash.ToLower()
$msiHash = (Get-FileHash $msiPath -Algorithm SHA256).Hash.ToLower()

$checksumsPath = Join-Path $Root "dist\checksums.txt"
$checksumLines = @(
    "StockTool Kiosk $Version",
    "$exeHash  StockToolKiosk.exe",
    "$msiHash  StockToolKiosk.msi"
)
$checksumLines | Set-Content $checksumsPath

Write-Host ""
Write-Host "Build complete:" -ForegroundColor Green
Write-Host "  exe: $exePath"
Write-Host "  msi: $msiPath"
Write-Host "  exe sha256: $exeHash"
Write-Host "  msi sha256: $msiHash"
Write-Host "  (also written to $checksumsPath)"

# --- 7. Verify (optional) -----------------------------------------------------
if ($Verify) {
    Write-Step "Verifying the built exe actually serves the kiosk UI"

    $svc = Get-Service -Name "StockToolKioskAPI" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Stopped") {
        try {
            & $NssmPath stop StockToolKioskAPI | Out-Null
        } catch {
            Write-Host "  WARNING: couldn't stop the StockToolKioskAPI service ($($_.Exception.Message))." -ForegroundColor Yellow
        }
    }
    try {
        Get-Process StockToolKiosk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
    } catch {
        Write-Host "  WARNING: couldn't stop a running StockToolKiosk.exe ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host "  It's likely still running as a service. Verification below may fail if it holds the port." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 1

    $proc = Start-Process -FilePath $exePath -PassThru
    Write-Host "  Waiting for startup (a fresh onefile exe can take a while to extract on its first run)..."

    $settingsPath = Join-Path $env:PROGRAMDATA "StockToolKiosk\settings.json"
    $port = 8420
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.port) { $port = $settings.port }
        } catch { }
    }
    $uiUrl = "http://127.0.0.1:$port/ui/"

    # 60s, not 20s: onefile PyInstaller exes unpack themselves to a fresh
    # %TEMP%\_MEIxxxxxx on every launch, and antivirus real-time scanning
    # of a brand-new unsigned exe (even one built locally, not downloaded)
    # can add real time to that on a first run.
    $html = $null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            Write-Warn2 "The exe exited on its own (exit code $($proc.ExitCode)) before it ever answered $uiUrl -- this is a real crash, not just a slow start."
            break
        }
        try {
            $html = (Invoke-WebRequest -Uri $uiUrl -UseBasicParsing -TimeoutSec 5).Content
            break
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    if (-not $html) {
        if (-not $proc.HasExited) {
            Write-Warn2 "Could not reach $uiUrl within 60s, but the process (PID $($proc.Id)) is still running -- it may just be slow to finish starting. Check manually, or check %PROGRAMDATA%\StockToolKiosk\service.log."
        } else {
            Write-Warn2 "Could not reach $uiUrl -- the exe exited before it started serving HTTP requests. Check %PROGRAMDATA%\StockToolKiosk\service.log for the actual error, or run it directly in a console to see the traceback."
        }
    } else {
        $checks = @{
            "Scan flow"     = ($html -match "Scan in order")
            "Low Stock tab" = ($html -match 'tab-lowstock')
            "Audit tab"     = ($html -match 'tab-audit')
        }
        $allOk = $true
        foreach ($name in $checks.Keys) {
            if ($checks[$name]) { Write-Ok $name } else { Write-Warn2 "$name marker not found in the response"; $allOk = $false }
        }
        if ($allOk) {
            Write-Ok "Kiosk UI verified at $uiUrl"
        } else {
            Write-Warn2 "Some expected page markers were missing - the build may still be fine (e.g. if the UI genuinely changed), but double-check manually."
        }
    }
}

# --- 8. Publish (optional) ---------------------------------------------------
if ($Publish) {
    if (-not $ApiBase -or -not $AdminUser -or -not $AdminPass -or -not $DownloadUrl) {
        throw "-Publish requires -ApiBase, -AdminUser, -AdminPass, and -DownloadUrl"
    }
    Write-Step "Publishing release $Version to $ApiBase"
    & $py (Join-Path $Root "scripts\publish_release.py") `
        --api-base $ApiBase --username $AdminUser --password $AdminPass `
        --version $Version --exe-path $exePath --download-url $DownloadUrl `
        --release-notes $ReleaseNotes
}
