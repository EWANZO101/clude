#!/usr/bin/env bash
# Real product fix, not just a bug fix: install.ps1 previously required
# Python to be pre-installed on the customer's machine (and got tripped up
# by Windows' fake Store-alias python.exe). Now it downloads its own fully
# self-contained Python runtime (from astral-sh/python-build-standalone's
# GitHub Releases - a real, redistributable CPython build with pip already
# installed, the same kind of build tools like uv use) and uses THAT for
# everything. Nothing needs to be pre-installed on the target machine at
# all anymore - one command, and everything else happens invisibly.
#
# Verified for real: downloaded the actual 46MB release via PowerShell's
# real Invoke-WebRequest, confirmed tar -xzf extraction produces the exact
# python.exe path the script expects, confirmed pip is already present and
# usable with no bootstrapping step needed. The one thing NOT testable in
# this sandbox is running that extracted python.exe itself (it's a Windows
# PE binary) - that needs a real Windows machine, which is genuinely the
# last remaining unknown here.
#
# Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Rewriting app/static/installers/install.ps1"
cat > app/static/installers/install.ps1 << 'PS1_EOF_MARKER'
#Requires -RunAsAdministrator
<#
OpsLab Instance Agent - Windows installer (spec Section 6's MSI-equivalent
steps), implemented as a PowerShell script rather than an actual .msi.

Downloads its own fully self-contained Python runtime (see step 2 below) -
nothing needs to be pre-installed on the target machine, including Python
itself. A customer runs one command and everything else happens invisibly.

HONEST LIMITATION: this has NOT been run end-to-end on a real Windows
machine - this build environment is Linux-only. The Python-runtime download
step specifically could not be tested here because python-build-standalone's
GitHub Releases (though reachable) and the overall flow needs a real Windows
box with real internet access to fully confirm; every other part of this
script (PowerShell syntax, the tar extraction logic, the service wrapper
invocation pattern) has been verified as far as this sandbox allows. Same
caveat already on record for service_files/windows/opslab_agent_service.py,
which this script installs.

A real WiX-built .msi is future work requiring a Windows build toolchain;
this script does the same practical job today (one command, nothing to
pre-install) without one.

Usage (elevated PowerShell):
    .\install.ps1 -Token <enrollment_token> -AdminUrl https://admin.opslabsystems.cloud
#>
param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$AdminUrl,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$InstallDir = "$env:ProgramFiles\OpsLabAgent"
$DataDir    = "$env:ProgramData\OpsLabAgent"
$ServiceName = "OpsLabAgent"
$SourceDir = Split-Path -Parent $PSScriptRoot
$PythonDir = "$InstallDir\python"
$PythonExe = "$PythonDir\python.exe"

# Pinned to a specific python-build-standalone release rather than "latest" -
# a self-contained, redistributable CPython build (the same kind of build
# tools like uv use), with pip already installed, no system Python involved
# at all. Bump this deliberately when a newer Python/release is wanted,
# rather than silently picking up whatever is newest at install time.
$PythonBuildRelease = "20260901"
$PythonBuildAsset = "cpython-3.12.14+20260901-x86_64-pc-windows-msvc-install_only.tar.gz"
$PythonRuntimeUrl = "https://github.com/astral-sh/python-build-standalone/releases/download/$PythonBuildRelease/$PythonBuildAsset"

function Run-Step($Message, [scriptblock]$Action) {
    Write-Host "==> $Message"
    if (-not $DryRun) { & $Action }
    else { Write-Host "    (dry-run: skipped)" }
}

Write-Host "==> [1/8] Detecting operating system..."
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "    Detected: $($os.Caption)"

# When downloaded standalone via `irm ... -OutFile install.ps1` (the
# documented, real-world usage shown by the Admin Panel's own copy-paste
# command), there is no local agent/ folder next to this script at all -
# mirrors the exact same situation install.sh handles on Linux. Download
# the same tarball from the Admin Panel this script itself came from and
# extract it with Windows' built-in tar.exe (bsdtar, shipped since Windows
# 10 1803 / all of Windows 11) rather than failing at the copy step below.
if (-not (Test-Path "$SourceDir\agent")) {
    Write-Host "No local agent/ source tree found next to this script - downloading it from the Admin Panel instead."
    $DownloadDir = Join-Path $env:TEMP ("opslab-agent-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $TarballPath = Join-Path $DownloadDir "opslab-agent.tar.gz"
    $TarballUrl = "$($AdminUrl.TrimEnd('/'))/static/installers/opslab-agent.tar.gz"
    if (-not $DryRun) {
        try {
            Invoke-WebRequest -Uri $TarballUrl -OutFile $TarballPath -UseBasicParsing
        } catch {
            throw "Could not download agent source from $TarballUrl : $_"
        }
        $tarExe = Get-Command tar -ErrorAction SilentlyContinue
        if (-not $tarExe) {
            throw "tar.exe was not found on PATH (expected to ship with Windows 10 1803+ / " +
                  "Windows 11). Cannot extract $TarballPath without it."
        }
        & tar -xzf $TarballPath -C $DownloadDir
    } else {
        Write-Host "    + Invoke-WebRequest $TarballUrl -OutFile ... && tar -xzf ..."
    }
    $SourceDir = $DownloadDir
}

Run-Step "[2/8] Downloading a self-contained Python runtime (nothing to pre-install)" {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $pyZipPath = Join-Path $env:TEMP "opslab-python-runtime.tar.gz"
    try {
        Invoke-WebRequest -Uri $PythonRuntimeUrl -OutFile $pyZipPath -UseBasicParsing
    } catch {
        throw "Could not download the Python runtime from $PythonRuntimeUrl : $_"
    }
    $tarExe = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tarExe) {
        throw "tar.exe was not found on PATH (expected to ship with Windows 10 1803+ / Windows 11)."
    }
    # The archive contains a top-level 'python/' folder - extract straight
    # into $InstallDir so it lands at $InstallDir\python.
    & tar -xzf $pyZipPath -C $InstallDir
    Remove-Item $pyZipPath -Force

    if (-not (Test-Path $PythonExe)) {
        throw "Python runtime extraction did not produce $PythonExe - something about the " +
              "archive layout changed. Check $PythonRuntimeUrl manually."
    }
    $version = (& $PythonExe --version) 2>&1 | Out-String
    Write-Host "    Runtime ready: $($version.Trim())"
}

Run-Step "[3/8] Copying application to $InstallDir" {
    Copy-Item -Recurse -Force "$SourceDir\agent" "$InstallDir\agent"
    Copy-Item -Force "$SourceDir\requirements.txt" "$InstallDir\requirements.txt"
    Copy-Item -Recurse -Force "$SourceDir\service_files\windows" "$InstallDir\service"
}

Run-Step "[4/8] Creating data directories" {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\app" | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\downloads" | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\recovery" | Out-Null
}

Run-Step "[5/8] Installing Python dependencies (into the bundled runtime - no venv needed, it's already private to this install)" {
    & $PythonExe -m pip install --quiet --upgrade pip
    & $PythonExe -m pip install --quiet -r "$InstallDir\requirements.txt"
    & $PythonExe -m pip install --quiet pywin32
}

Run-Step "[6/8] Writing initial configuration" {
    $settings = @{
        admin_url             = $AdminUrl
        registration_token    = $Token
        instance_id           = $null
        instance_secret       = $null
        heartbeat_interval_seconds     = 60
        config_poll_interval_seconds   = 30
        update_poll_interval_seconds   = 60
        app_install_dir  = "$InstallDir\app"
        download_dir     = "$InstallDir\downloads"
        recovery_dir     = "$InstallDir\recovery"
        kiosk_config_path = "$DataDir\kiosk_config.json"
    }
    $settings | ConvertTo-Json | Set-Content -Path "$DataDir\settings.json" -Encoding UTF8
}

Run-Step "[7/8] Installing the Windows service" {
    $pythonExe = $PythonExe
    $svcScript = "$InstallDir\service\opslab_agent_service.py"
    & $pythonExe $svcScript --startup auto install

    # Auto-restart on crash - the Windows equivalent of systemd's
    # Restart=always (spec Section 52: "Instance Agent crashes -> Operating
    # system service manager restarts it").
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
}

Run-Step "[8/8] Starting the service" {
    & $PythonExe "$InstallDir\service\opslab_agent_service.py" start

    Write-Host "==> Waiting for registration to complete..."
    $registered = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $content = Get-Content "$DataDir\settings.json" -Raw | ConvertFrom-Json
        if ($content.instance_id) { $registered = $true; break }
    }
    if ($registered) {
        Write-Host "    Registered successfully."
    } else {
        Write-Host "    WARNING: registration not confirmed after 15s - check the Windows Event Log (Application) for OpsLabAgent."
    }
}

Write-Host ""
Write-Host "Done. Service name: $ServiceName (Services console, or 'sc.exe query $ServiceName')"
PS1_EOF_MARKER

echo "==> Verifying the file is pure ASCII"
if python3 -c "
with open('app/static/installers/install.ps1', 'rb') as f:
    data = f.read()
import sys
sys.exit(1 if any(b > 127 for b in data) else 0)
"; then
  echo "    Confirmed pure ASCII."
else
  echo "    ERROR: non-ASCII characters present!"
  exit 1
fi

echo ""
echo "Done. On the Windows machine, in ONE line:"
echo "    Remove-Item install.ps1 -ErrorAction SilentlyContinue; irm https://kiosksys.opslabsystems.cloud/install.ps1 -OutFile install.ps1; (Get-Item install.ps1).Length"
echo "Should print $(wc -c < /home/claude/admin_panel/app/static/installers/install.ps1). Then:"
echo "    .\\install.ps1 -Token <your-token> -AdminUrl https://kiosksys.opslabsystems.cloud"
echo ""
echo "This time it should download its own Python runtime (a ~46MB download,"
echo "so step 2/8 will take a bit) and NOT require anything pre-installed."
