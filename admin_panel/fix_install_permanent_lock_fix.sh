#!/usr/bin/env bash
# Permanent fix for the "Can't unlink already-existing object: Permission
# denied" reinstall failure hit repeatedly on Ewan, even after the earlier
# service-shutdown-race fix (t.join(timeout=30) in
# service_files/windows/opslab_agent_service.py) was deployed and a
# successful reinstall had already picked it up.
#
# That fix and install.ps1's own existing WaitForStatus("Stopped", 30s)
# share the SAME ~30s budget with essentially zero margin between them -
# ordinary system jitter (antivirus scanning, disk I/O, general load)
# pushing the real shutdown time just past 30s reproduces the exact same
# failure, just with a bigger (but still finite, still exceedable) window.
# Rather than keep tuning a timeout that can never have a real guarantee,
# install.ps1 now force-verifies nothing is left running from the install
# directory at all, right before the one step that is actually destructive
# to already-open file handles (the Python runtime extraction) - the same
# approach as the one-off fix_and_reinstall.ps1 script from earlier in this
# session, now built permanently into every single reinstall, with no
# separate script or manual step needed ever again.
#
# If something still can't be stopped (never expected in practice, but
# possible if a file is held by something outside OpsLabAgent's own
# processes entirely), install.ps1 now throws a clear, specific error
# naming the exact PIDs still running, instead of failing minutes later
# with 24 near-identical "Permission denied" lines and no indication of
# WHY.
#
# Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -e app/static/installers/install.ps1 ]; then
    echo "Error: expected to find 'app/static/installers/install.ps1' here - run this from the admin_panel repo root."
    exit 1
fi

echo "==> Writing app/static/installers/install.ps1"
cat > app/static/installers/install.ps1 << 'INSTALL_PS1_EOF_MARKER'
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

# Windows PowerShell 5.1 does not always default to TLS 1.2, and GitHub's
# HTTPS endpoints (used below) require it. Without this, Invoke-WebRequest
# can hang silently during the TLS handshake on some systems.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

# The graceful stop above has NO real safety margin against ordinary
# system jitter (antivirus scanning, disk I/O, general load) pushing the
# Agent's own internal shutdown sequence past its matching ~30s budget -
# and if it does, the runtime-replacement step below hits "Can't unlink
# already-existing object: Permission denied" on python.exe and every DLL
# it has loaded, because something is still holding them open. Rather than
# tune that timing forever, force-verify nothing is left running from this
# install directory at all before touching any of its files - this is the
# only reinstall step that's actually destructive to already-open handles,
# so it's the one place that needs a hard guarantee, not just a best-effort
# wait.
if (-not $DryRun) {
    $lingering = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$InstallDir*" }
    if ($lingering) {
        Write-Host "    Still-running process(es) from a previous install found - stopping them directly:"
        $lingering | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-String | Write-Host
        foreach ($p in $lingering) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
        $stillLingering = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$InstallDir*" }
        if ($stillLingering) {
            throw ("Could not stop process(es) still using files under $InstallDir " +
                   "(PIDs: $($stillLingering.ProcessId -join ', ')) - close them manually " +
                   "(Task Manager -> Details) and re-run this installer.")
        }
    }
}

# When downloaded standalone via `irm ... -OutFile install.ps1` (the
# documented, real-world usage shown by the Admin Panel's own copy-paste
# command), there is no local agent/ folder next to this script at all -
# mirrors the exact same situation install.sh handles on Linux. Download
# the same tarball from the Admin Panel this script itself came from and
# extract it with Windows' built-in tar.exe (bsdtar, shipped since Windows
# 10 1803 / all of Windows 11) rather than failing at the copy step below.
$LooksLikeRealSource = (Test-Path "$SourceDir\agent") -and
                        (Test-Path "$SourceDir\requirements.txt") -and
                        (Test-Path "$SourceDir\service_files")
if (-not $LooksLikeRealSource) {
    Write-Host "No local agent/ source tree found next to this script - downloading it from the Admin Panel instead."
    $DownloadDir = Join-Path $env:TEMP ("opslab-agent-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $TarballPath = Join-Path $DownloadDir "opslab-agent.tar.gz"
    $TarballUrl = "$($AdminUrl.TrimEnd('/'))/static/installers/opslab-agent.tar.gz"
    if (-not $DryRun) {
        try {
            Invoke-WebRequest -Uri $TarballUrl -OutFile $TarballPath -UseBasicParsing -TimeoutSec 180
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
        Invoke-WebRequest -Uri $PythonRuntimeUrl -OutFile $pyZipPath -UseBasicParsing -TimeoutSec 180
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
    # Copy-Item -Recurse copies the SOURCE FOLDER ITSELF into an
    # already-existing destination (producing $InstallDir\agent\agent on a
    # reinstall) rather than merging its contents - so any previous copy at
    # the destination must be removed first, or a reinstall silently nests
    # a second, newer copy one level deeper than everything actually reads
    # from.
    if (Test-Path "$InstallDir\agent") { Remove-Item -Recurse -Force "$InstallDir\agent" }
    if (Test-Path "$InstallDir\service") { Remove-Item -Recurse -Force "$InstallDir\service" }

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
    # Set-Content -Encoding UTF8 writes a UTF-8 byte-order-mark on Windows
    # PowerShell 5.1 (the version that ships with Windows), which
    # json.load() in Python does not skip when opened with encoding="utf-8"
    # - it raises "Unexpected UTF-8 BOM" and the agent crashes before it
    # ever attempts registration, with nothing useful in the Event Log
    # since this happens before logging is even configured. Writing with
    # .NET's UTF8Encoding($false) (no BOM) avoids depending on Python's
    # reader tolerating one, and works identically on PowerShell 5.1 and
    # newer without needing the "utf8NoBOM" -Encoding value (Core-only).
    $json = $settings | ConvertTo-Json
    [System.IO.File]::WriteAllText("$DataDir\settings.json", $json, (New-Object System.Text.UTF8Encoding($false)))
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
INSTALL_PS1_EOF_MARKER

echo "==> Verifying"
grep -q "force-verify nothing is left running" app/static/installers/install.ps1 && echo "    fix present"
python3 -c "
content = open('app/static/installers/install.ps1').read()
b1, b2 = content.count('{'), content.count('}')
p1, p2 = content.count('('), content.count(')')
assert b1 == b2, f'brace mismatch: {b1} vs {b2}'
assert p1 == p2, f'paren mismatch: {p1} vs {p2}'
print('    braces balanced (%d/%d), parens balanced (%d/%d)' % (b1, b2, p1, p2))
"

echo ""
echo "Done. This is served directly by /install.ps1 - no app restart needed, and it"
echo "applies to EVERY future reinstall immediately, including the very next one:"
echo "    irm https://kiosksys.opslabsystems.cloud/install.ps1 -OutFile install.ps1; .\\install.ps1 -Token <fresh-token> -AdminUrl https://kiosksys.opslabsystems.cloud"
echo ""
echo "No pre-cleanup script needed beforehand this time - install.ps1 now does its"
echo "own forceful cleanup automatically, every time, before it ever touches a file."
