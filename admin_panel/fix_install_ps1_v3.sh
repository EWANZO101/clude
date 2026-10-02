#!/usr/bin/env bash
# Fixes a real bug caught only by running the previous fix on actual Windows:
# the Python-detection check crashed the whole script when Windows' fake
# "python.exe" Store-alias stub writes to stderr / exits non-zero, because
# $ErrorActionPreference = "Stop" (set earlier in the script) turns that into
# a terminating error even inside `(...) 2>&1 | Out-String` - the capture
# never gets a chance to run. Now wrapped in try/catch, which reliably
# survives this regardless of the exact mechanism Windows uses for that stub.
# Verified with a real PowerShell 7 parser + 3 real logic tests (fake stub
# that throws, real python, no python at all) before being sent.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Rewriting app/static/installers/install.ps1"
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
# Get-Command alone is not enough: Windows ships a fake python.exe "app
# execution alias" under WindowsApps that resolves as a real command but
# just opens the Microsoft Store when actually run. Worse, invoking it can
# throw a terminating error under $ErrorActionPreference = "Stop" (already
# set above) rather than just printing to stderr and returning - wrapping
# in try/catch is the only reliable way to survive that regardless of the
# exact mechanism Windows uses for that specific stub.
$py = Get-Command python -ErrorAction SilentlyContinue
$pyVersionOutput = ""
if ($py) {
    try {
        $pyVersionOutput = (& python --version) 2>&1 | Out-String
    } catch {
        $pyVersionOutput = ""
    }
}
if (-not $py -or $pyVersionOutput -notmatch "Python \d") {
    throw "A real Python 3.10+ install was not found on PATH (Windows' built-in " +
          "'python' Store-alias stub does not count). Install Python from " +
          "https://www.python.org/downloads/windows/ (check 'Add python.exe to PATH' " +
          "during setup), then re-run this installer."
}
Write-Host "    Found: $($pyVersionOutput.Trim())"

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

    # Auto-restart on crash - the Windows equivalent of systemd's
    # Restart=always (spec Section 52: "Instance Agent crashes -> Operating
    # system service manager restarts it").
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
echo "Done. On the Windows machine, in ONE line (to avoid re-ordering issues):"
echo "    Remove-Item install.ps1 -ErrorAction SilentlyContinue; irm https://kiosksys.opslabsystems.cloud/install.ps1 -OutFile install.ps1; (Get-Item install.ps1).Length"
echo "Should print $(wc -c < /home/claude/admin_panel/app/static/installers/install.ps1). Then:"
echo "    .\\install.ps1 -Token <your-token> -AdminUrl https://kiosksys.opslabsystems.cloud"
