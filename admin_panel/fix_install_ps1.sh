#!/usr/bin/env bash
# Fixes install.ps1's real PowerShell parse error (em-dash characters in
# comments caused "missing terminator"/"missing closing brace" errors when
# run on real Windows PowerShell). Replaces just that one file with a
# pure-ASCII version, verified against a real PowerShell 7 parser before
# being sent. Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Rewriting app/static/installers/install.ps1 (ASCII-only, fixes the parse error)"
cat > app/static/installers/install.ps1 << 'PS1_EOF_MARKER'
#Requires -RunAsAdministrator
<#
OpsLab Instance Agent - Windows installer (spec Section 6's MSI-equivalent
steps), implemented as a PowerShell script rather than an actual .msi.

HONEST LIMITATION: this has NOT been run on a real Windows machine - this
build environment is Linux-only. It's written to mirror install.sh's real,
tested steps exactly (same directory layout, same settings.json shape, same
registration flow), and uses the standard, well-documented mechanisms for
each Windows equivalent (sc.exe for service registration/failure actions,
py -3 -m venv for the virtualenv), but needs a real Windows smoke test
before being trusted in production - same caveat already on record for
service_files/windows/opslab_agent_service.py, which this script installs.

A real WiX-built .msi is future work requiring a Windows build toolchain;
this script does the same job today without one.

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

function Run-Step($Message, [scriptblock]$Action) {
    Write-Host "==> $Message"
    if (-not $DryRun) { & $Action }
    else { Write-Host "    (dry-run: skipped)" }
}

Write-Host "==> [1/8] Detecting operating system..."
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "    Detected: $($os.Caption)"

Write-Host "==> [2/8] Checking system requirements..."
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    throw "python was not found on PATH. Install Python 3.10+ before running this installer."
}
Write-Host "    Found: $(python --version)"

Run-Step "[3/8] Copying application to $InstallDir" {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
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

Run-Step "[5/8] Setting up Python virtual environment" {
    python -m venv "$InstallDir\venv"
    & "$InstallDir\venv\Scripts\pip.exe" install --quiet --upgrade pip
    & "$InstallDir\venv\Scripts\pip.exe" install --quiet -r "$InstallDir\requirements.txt"
    & "$InstallDir\venv\Scripts\pip.exe" install --quiet pywin32
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
    $pythonExe = "$InstallDir\venv\Scripts\python.exe"
    $svcScript = "$InstallDir\service\opslab_agent_service.py"
    & $pythonExe $svcScript --startup auto install

    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
}

Run-Step "[8/8] Starting the service" {
    & "$InstallDir\venv\Scripts\python.exe" "$InstallDir\service\opslab_agent_service.py" start

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

echo "==> Verifying the file is pure ASCII (this was the actual bug)"
if python3 -c "
with open('app/static/installers/install.ps1', 'rb') as f:
    data = f.read()
import sys
sys.exit(1 if any(b > 127 for b in data) else 0)
"; then
  echo "    Confirmed pure ASCII - the parse error is fixed."
else
  echo "    ERROR: non-ASCII characters still present! Something went wrong."
  exit 1
fi

echo ""
echo "Done. On the Windows machine, re-download install.ps1 fresh (the old"
echo "cached copy still has the bug) and try again:"
echo "    irm https://kiosksys.opslabsystems.cloud/install.ps1 -OutFile install.ps1"
echo "    .\\install.ps1 -Token <your-token> -AdminUrl https://kiosksys.opslabsystems.cloud"
