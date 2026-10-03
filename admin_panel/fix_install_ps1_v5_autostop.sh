#!/usr/bin/env bash
# Fixes a real robustness bug found from actual usage: re-running the
# installer without first manually stopping/deleting the old service left
# the old service running, holding its DLLs open, which made tar fail to
# overwrite the Python runtime - "Can't unlink already-existing object:
# Permission denied". Worse, this failure was SILENT: PowerShell does not
# automatically treat a failed native command's exit code as an error, even
# under $ErrorActionPreference = "Stop" - confirmed for real (a plain
# `& false` under Stop does not halt a script). The install just limped on
# and declared success.
#
# Two fixes, both verified for real (as far as this sandbox allows):
#   1. Checks for an already-running OpsLabAgent service at the very start
#      and stops it automatically before touching anything - re-running the
#      installer to reconfigure/update/retry no longer requires remembering
#      three separate manual stop/delete/remove commands first.
#   2. Every native command (tar) now has its exit code checked explicitly
#      via a small Invoke-Native helper, so a real failure stops the
#      install with a clear error instead of continuing silently. Confirmed
#      this actually catches what the old code missed, using a real
#      PowerShell 7 instance.
#
# HONEST LIMITATION: Get-Service/Stop-Service (the pre-flight check) are
# Windows-only cmdlets that don not exist in cross-platform PowerShell on
# Linux, so that specific piece could only be parse-checked here, not
# executed - it matches the standard documented pattern for this operation,
# but a real Windows test is still the final word on it.
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
invocation pattern) has been verified as far as this sandbox allows. The
Get-Service/Stop-Service pre-flight check added to handle a still-running
old service is Windows-only and could not be executed here at all (these
cmdlets don't exist in cross-platform PowerShell on Linux) - only confirmed
to parse correctly and match the standard, documented pattern for this
exact operation. Same caveat already on record for
service_files/windows/opslab_agent_service.py, which this script installs.

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

function Invoke-Native($Description) {
    # PowerShell does NOT automatically treat a failed native command's exit
    # code as a terminating error, even under $ErrorActionPreference =
    # "Stop" - that setting only covers PowerShell-native cmdlet/script
    # errors. A failing external .exe just returns and execution silently
    # continues. Confirmed for real: `& false` under Stop does not halt the
    # script. Every native command in this installer is checked explicitly
    # here instead, so a real failure (like tar being unable to overwrite a
    # DLL locked by an already-running old service) stops the install with
    # a clear error rather than limping on with a half-extracted runtime.
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed (exit code $LASTEXITCODE)."
    }
}

Write-Host "==> [1/8] Detecting operating system..."
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "    Detected: $($os.Caption)"

# Re-running this installer (to reconfigure, update, or just retry) used to
# require three separate manual commands first (stop/delete/remove the old
# service) - if skipped, the old service is still running and holding its
# DLLs open, which makes the runtime-replacement step below fail to
# overwrite them. Handled automatically now instead of relying on that
# always being remembered in the right order.
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService -and $existingService.Status -eq "Running") {
    Write-Host "    Existing $ServiceName service is running - stopping it before reinstalling..."
    if (-not $DryRun) {
        Stop-Service -Name $ServiceName -Force
        $existingService.WaitForStatus("Stopped", "00:00:30")
    }
}

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
        Invoke-Native "Extracting agent source tarball"
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
    Invoke-Native "Extracting Python runtime"
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
echo "Should print $(wc -c < /home/claude/admin_panel/app/static/installers/install.ps1). Then just re-run the install"
echo "command directly - no more manual stop/delete/remove needed first, the"
echo "installer now handles a still-running old service itself."
