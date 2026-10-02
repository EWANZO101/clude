#!/usr/bin/env bash
# Self-contained MSI build setup for the OpsLab Kiosk Agent.
#
# Unlike the earlier build_msi.sh, this script does NOT depend on any
# other file existing on this machine already - it creates its own
# msi_build/ workspace (generate_wxs.py + files/postinstall.ps1 +
# files/uninstall_service.ps1) via embedded heredocs, then stages the
# agent source straight from THIS repo's own layout
# (./agent, ./service_files/windows, ./requirements.txt - the layout
# your `find` output confirmed already exists here), builds with wixl,
# and self-validates.
#
# Run this from the admin_panel repo root:
#   bash build_msi_selfcontained.sh <version>
#
# Example:
#   bash build_msi_selfcontained.sh 0.1.1
#
# Requires wixl (install once with: apt-get install -y wixl wixl-data)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <version>"
    exit 1
fi
VERSION="$1"

if ! command -v wixl >/dev/null 2>&1; then
    echo "wixl not found - installing (msitools/wixl from the Ubuntu repos)..."
    apt-get update -qq
    apt-get install -y wixl wixl-data
fi

if ! command -v xmllint >/dev/null 2>&1; then
    apt-get install -y libxml2-utils
fi

echo "==> [1/6] Verifying this looks like the admin_panel repo root..."
for req in agent service_files/windows requirements.txt; do
    if [ ! -e "$req" ]; then
        echo "Error: expected to find '$req' here - run this from ~/admin_panel."
        exit 1
    fi
done
if [ ! -f "service_files/windows/opslab_agent_service.py" ]; then
    echo "Error: service_files/windows/opslab_agent_service.py not found."
    exit 1
fi
echo "    OK"

echo "==> [2/6] Creating msi_build/ workspace..."
mkdir -p msi_build/files/agent msi_build/files/service
cd msi_build

cat > files/postinstall.ps1 <<'PS_POSTINSTALL_EOF'
param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$AdminUrl
)

if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($AdminUrl)) {
    Write-Error "TOKEN and ADMINURL must both be non-empty. Example: msiexec /i kiosk-agent.msi TOKEN=`"...`" ADMINURL=`"https://...`" /qn"
    exit 1
}


# Runs as a deferred, elevated MSI custom action after the file table has
# already deployed agent\, service\, and requirements.txt under
# $PSScriptRoot (== INSTALLDIR). Unlike install.ps1, this script never has
# to guess where its own source files are - the MSI's own File table is
# the single source of truth for that, which eliminates the whole class of
# bugs the standalone install.ps1 hit (ambiguous $SourceDir resolution,
# reinstall folder-nesting). What's left here is genuinely new work only
# an installer can't do on its own: fetching the Python runtime, pip
# install, writing settings.json, and registering the Windows service.

$ErrorActionPreference = "Stop"
$InstallDir  = $PSScriptRoot
$DataDir     = "$env:ProgramData\OpsLabAgent"
$ServiceName = "OpsLabAgent"
$PythonDir   = "$InstallDir\python"
$PythonExe   = "$PythonDir\python.exe"

$PythonBuildRelease = "20260901"
$PythonBuildAsset   = "cpython-3.12.14+20260901-x86_64-pc-windows-msvc-install_only.tar.gz"
$PythonRuntimeUrl   = "https://github.com/astral-sh/python-build-standalone/releases/download/$PythonBuildRelease/$PythonBuildAsset"

$LogFile = "$env:TEMP\opslab_msi_postinstall.log"
function Log($msg) {
    $line = "$(Get-Date -Format o)  $msg"
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line } catch {}
}

function Invoke-Native($Description) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed (exit code $LASTEXITCODE)."
    }
}

Log "=== OpsLab Agent post-install starting (InstallDir=$InstallDir) ==="

try {
    if (-not (Test-Path $PythonExe)) {
        Log "Downloading self-contained Python runtime..."
        $pyZipPath = Join-Path $env:TEMP "opslab-python-runtime.tar.gz"
        Invoke-WebRequest -Uri $PythonRuntimeUrl -OutFile $pyZipPath -UseBasicParsing
        $tarExe = Get-Command tar -ErrorAction SilentlyContinue
        if (-not $tarExe) {
            throw "tar.exe not found on PATH (expected to ship with Windows 10 1803+/Windows 11)."
        }
        & tar -xzf $pyZipPath -C $InstallDir
        Invoke-Native "Extracting Python runtime"
        Remove-Item $pyZipPath -Force
        if (-not (Test-Path $PythonExe)) {
            throw "Python runtime extraction did not produce $PythonExe."
        }
    } else {
        Log "Python runtime already present (upgrade install) - skipping download."
    }
    $version = (& $PythonExe --version) 2>&1 | Out-String
    Log "Python runtime ready: $($version.Trim())"

    New-Item -ItemType Directory -Force -Path $DataDir              | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\app"     | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\downloads" | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\recovery"  | Out-Null

    Log "Installing Python dependencies..."
    & $PythonExe -m pip install --quiet --upgrade pip
    Invoke-Native "pip upgrade"
    & $PythonExe -m pip install --quiet -r "$InstallDir\requirements.txt"
    Invoke-Native "pip install -r requirements.txt"
    & $PythonExe -m pip install --quiet pywin32
    Invoke-Native "pip install pywin32"

    if (-not (Test-Path "$DataDir\settings.json")) {
        Log "Writing initial settings.json..."
        $settings = @{
            admin_url                     = $AdminUrl
            registration_token            = $Token
            instance_id                   = $null
            instance_secret               = $null
            heartbeat_interval_seconds    = 60
            config_poll_interval_seconds  = 30
            update_poll_interval_seconds  = 60
            app_install_dir   = "$InstallDir\app"
            download_dir      = "$InstallDir\downloads"
            recovery_dir      = "$InstallDir\recovery"
            kiosk_config_path = "$DataDir\kiosk_config.json"
        }
        # Written without a BOM (UTF8Encoding($false)) - the same fix
        # already applied to install.ps1, kept here so this installer
        # doesn't reintroduce that bug.
        $json = $settings | ConvertTo-Json
        [System.IO.File]::WriteAllText("$DataDir\settings.json", $json, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        Log "settings.json already exists - this is an upgrade, leaving existing registration in place."
    }

    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Log "Existing service found - stopping and removing before re-registering..."
        if ($existingService.Status -eq "Running") {
            Stop-Service -Name $ServiceName -Force
            $existingService.WaitForStatus("Stopped", "00:00:30")
        }
        & $PythonExe "$InstallDir\service\opslab_agent_service.py" remove
    }

    Log "Installing Windows service..."
    & $PythonExe "$InstallDir\service\opslab_agent_service.py" --startup auto install
    Invoke-Native "Service install"
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

    Log "Starting service..."
    & $PythonExe "$InstallDir\service\opslab_agent_service.py" start

    $registered = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        try {
            $content = Get-Content "$DataDir\settings.json" -Raw | ConvertFrom-Json
            if ($content.instance_id) { $registered = $true; break }
        } catch {}
    }
    if ($registered) {
        Log "Registered successfully."
    } else {
        Log "WARNING: registration not confirmed after 15s - check Windows Event Log (Application) for OpsLabAgent, or full log at $LogFile."
    }

    Log "=== Post-install complete ==="
    exit 0
} catch {
    Log "FATAL: $($_.Exception.Message)"
    Log ($_.ScriptStackTrace)
    exit 1
}

PS_POSTINSTALL_EOF

cat > files/uninstall_service.ps1 <<'PS_UNINSTALL_EOF'
$ErrorActionPreference = "SilentlyContinue"
$InstallDir  = $PSScriptRoot
$PythonExe   = "$InstallDir\python\python.exe"
$ServiceName = "OpsLabAgent"

$LogFile = "$env:TEMP\opslab_msi_uninstall.log"
function Log($msg) {
    $line = "$(Get-Date -Format o)  $msg"
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line } catch {}
}

Log "=== OpsLab Agent uninstall service-cleanup starting ==="

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq "Running") {
        Log "Stopping service..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        $svc.WaitForStatus("Stopped", "00:00:30")
    }
    if (Test-Path $PythonExe) {
        Log "Removing service registration via opslab_agent_service.py remove..."
        & $PythonExe "$InstallDir\service\opslab_agent_service.py" remove
    } else {
        Log "python.exe not found - falling back to sc.exe delete."
        sc.exe delete $ServiceName | Out-Null
    }
} else {
    Log "No existing service registration found - nothing to remove."
}

Log "=== Uninstall service-cleanup complete ==="
exit 0

PS_UNINSTALL_EOF

cat > generate_wxs.py <<'PY_GENWXS_EOF'
#!/usr/bin/env python3
"""
Generates product.wxs for the OpsLab Kiosk Agent MSI from the actual
staged file tree (files/agent, files/service, files/requirements.txt,
files/postinstall.ps1, files/uninstall_service.ps1) rather than by hand -
same reasoning as release/build_release.py for the kiosk app: hand-written
Component/GUID tables drift from what's actually on disk and that
mismatch is invisible until someone hits it.

Usage:
    python3 generate_wxs.py > product.wxs
    wixl -v product.wxs -o kiosk-agent-<version>.msi
"""
import uuid
from pathlib import Path

VERSION = "0.1.1"
# Fixed forever - this is what tells Windows Installer that future
# versions are upgrades of THIS product rather than unrelated software.
# Generated once, must never change.
UPGRADE_CODE = "{8F2C1A6E-4B3D-4E7A-9C1F-6A2B9D5E7C10}"
# Deterministic per-version Product Id (MSI requires PackageCode/ProductCode
# to differ per build; deriving from a fixed namespace + version keeps
# rebuilds of the SAME version reproducible rather than random each time).
NAMESPACE = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
PRODUCT_CODE = "{" + str(uuid.uuid5(NAMESPACE, f"opslab-kiosk-agent-{VERSION}")).upper() + "}"

FILES_DIR = Path(__file__).resolve().parent / "files"


def guid_for(rel_path: str) -> str:
    return "{" + str(uuid.uuid5(NAMESPACE, f"component-{rel_path}")).upper() + "}"


def file_id_for(rel_path: str) -> str:
    # MSI identifiers: letters/digits/underscore/period only, must not
    # start with a digit.
    safe = rel_path.replace("/", "_").replace("\\", "_").replace(".", "_").replace("-", "_")
    return "f_" + safe


def collect_files():
    """Returns list of (rel_path, abs_path) for everything that ships."""
    out = []
    for p in sorted((FILES_DIR / "agent").glob("*.py")):
        out.append((f"agent/{p.name}", p))
    for p in sorted((FILES_DIR / "service").glob("*.py")):
        out.append((f"service/{p.name}", p))
    out.append(("requirements.txt", FILES_DIR / "requirements.txt"))
    out.append(("postinstall.ps1", FILES_DIR / "postinstall.ps1"))
    out.append(("uninstall_service.ps1", FILES_DIR / "uninstall_service.ps1"))
    return out


def indent(n):
    return " " * n


def main():
    files = collect_files()
    for rel, abs_path in files:
        if not abs_path.is_file():
            raise SystemExit(f"Expected staged file missing: {abs_path}")

    components_xml = []
    component_refs = []
    for rel, abs_path in files:
        comp_id = "c_" + file_id_for(rel)[2:]
        fid = file_id_for(rel)
        comp_guid = guid_for(rel)
        # Sub-folder is expressed via the File's Name using a relative
        # path is not valid MSI - instead each file lives directly under
        # INSTALLDIR here for simplicity (flat layout for agent/service
        # subfolders is expressed via nested Directory elements below
        # instead). This function only emits the Component+File pair;
        # placement into the right Directory happens in build_directory_tree().
        components_xml.append((rel, comp_id, fid, comp_guid, abs_path))
        component_refs.append(comp_id)

    # Group files by their target subdirectory so we can nest <Directory>
    # elements correctly (agent/, service/, and INSTALLDIR root).
    by_dir = {"": [], "agent": [], "service": []}
    for rel, comp_id, fid, comp_guid, abs_path in components_xml:
        if "/" in rel:
            sub, _name = rel.split("/", 1)
        else:
            sub = ""
        by_dir[sub].append((rel, comp_id, fid, comp_guid, abs_path))

    def emit_components(entries, depth):
        lines = []
        for rel, comp_id, fid, comp_guid, abs_path in entries:
            name = Path(rel).name
            lines.append(f'{indent(depth)}<Component Id="{comp_id}" Guid="{comp_guid}">')
            lines.append(
                f'{indent(depth+2)}<File Id="{fid}" Name="{name}" '
                f'Source="{abs_path}" KeyPath="yes" />'
            )
            lines.append(f'{indent(depth)}</Component>')
        return "\n".join(lines)

    root_components = emit_components(by_dir[""], 10)
    agent_components = emit_components(by_dir["agent"], 12)
    service_components = emit_components(by_dir["service"], 12)

    wxs = f"""<?xml version="1.0" encoding="utf-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="{PRODUCT_CODE}"
           Name="OpsLab Kiosk Agent"
           Language="1033"
           Version="{VERSION}"
           Manufacturer="OpsLab Systems"
           UpgradeCode="{UPGRADE_CODE}">

    <Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine"
             Description="OpsLab Kiosk Agent {VERSION}"
             Comments="Registers this machine with the OpsLab Admin Panel and runs the Instance Agent as an auto-starting Windows service." />

    <!-- Real upgrades (not just reinstalls) are handled by MSI's own
         major-upgrade mechanism instead of hand-rolled folder cleanup -
         this is what eliminates the reinstall-nesting class of bug that
         install.ps1 hit, by construction rather than by extra checks. -->
    <MajorUpgrade DowngradeErrorMessage="A newer version of the OpsLab Kiosk Agent is already installed." />

    <Media Id="1" Cabinet="agent.cab" EmbedCab="yes" />

    <!-- TOKEN and ADMINURL are intentionally NOT pre-declared here with a
         Property element: wixl's underlying libmsi crashes when building
         a Property row with an empty Value="" (confirmed empirically -
         non-empty values and omitting the element both work fine). MSI
         itself doesn't require a public (all-caps) property to be
         pre-declared in order to accept it from the command line, e.g.
         msiexec /i kiosk-agent.msi TOKEN="..." ADMINURL="..." /qn - so
         this loses nothing except the (already-unavailable, see above)
         ability to add a launch-condition default/description for them. -->

    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="ProgramFilesFolder">
        <Directory Id="INSTALLDIR" Name="OpsLabAgent">
{root_components}
          <Directory Id="AGENTDIR" Name="agent">
{agent_components}
          </Directory>
          <Directory Id="SERVICEDIR" Name="service">
{service_components}
          </Directory>
        </Directory>
      </Directory>
    </Directory>

    <Feature Id="MainFeature" Title="OpsLab Kiosk Agent" Level="1">
{chr(10).join('      <ComponentRef Id="' + cid + '" />' for cid in component_refs)}
    </Feature>

    <!-- Deferred, elevated custom action running the post-install script
         that this MSI just deployed to INSTALLDIR. TOKEN/ADMINURL reach
         the deferred action via the standard MSI "property named the
         same as the CustomAction Id" CustomActionData mechanism, since
         deferred actions cannot read arbitrary session properties
         directly. -->
    <Property Id="POWERSHELLEXE" Value="[SystemFolder]WindowsPowerShell\\v1.0\\powershell.exe" />

    <CustomAction Id="SetRunPostInstall" Property="RunPostInstall"
                  Value="-NoProfile -ExecutionPolicy Bypass -File &quot;[INSTALLDIR]postinstall.ps1&quot; -Token &quot;[TOKEN]&quot; -AdminUrl &quot;[ADMINURL]&quot;" />
    <CustomAction Id="RunPostInstall" Property="POWERSHELLEXE"
                  ExeCommand="[CustomActionData]"
                  Execute="deferred" Impersonate="no" Return="check" />

    <CustomAction Id="RunUninstallService" Property="POWERSHELLEXE"
                  ExeCommand="-NoProfile -ExecutionPolicy Bypass -File &quot;[INSTALLDIR]uninstall_service.ps1&quot;"
                  Execute="deferred" Impersonate="no" Return="ignore" />

    <InstallExecuteSequence>
      <Custom Action="SetRunPostInstall" Before="RunPostInstall">NOT REMOVE</Custom>
      <Custom Action="RunPostInstall" After="InstallFiles">NOT REMOVE</Custom>
      <Custom Action="RunUninstallService" Before="RemoveFiles">REMOVE="ALL"</Custom>
    </InstallExecuteSequence>

  </Product>
</Wix>
"""
    print(wxs)


if __name__ == "__main__":
    main()

PY_GENWXS_EOF

echo "    Created generate_wxs.py, files/postinstall.ps1, files/uninstall_service.ps1"

echo "==> [3/6] Staging agent source from ../agent, ../service_files, ../requirements.txt..."
cp ../agent/*.py files/agent/
cp ../requirements.txt files/requirements.txt
cp ../service_files/windows/opslab_agent_service.py files/service/
echo "    Staged $(ls files/agent/*.py | wc -l) agent files"

echo "==> [4/6] Setting VERSION=$VERSION and generating product.wxs..."
sed -i "s/^VERSION = .*/VERSION = \"$VERSION\"/" generate_wxs.py
python3 generate_wxs.py > product.wxs
xmllint --noout product.wxs
echo "    OK"

echo "==> [5/6] Building MSI with wixl..."
OUT="kiosk-agent-$VERSION.msi"
rm -f "$OUT"
wixl -v product.wxs -o "$OUT"
if [ ! -f "$OUT" ]; then
    echo "Error: wixl did not produce $OUT"
    exit 1
fi
echo "    Built: $OUT ($(du -h "$OUT" | cut -f1))"

echo "==> [6/6] Self-validating..."
FILE_COUNT=$(msiinfo export "$OUT" File 2>/dev/null | tail -n +4 | grep -c .)
CA_COUNT=$(msiinfo export "$OUT" CustomAction 2>/dev/null | tail -n +4 | grep -c .)
echo "    Files: $FILE_COUNT   CustomActions: $CA_COUNT (expect 3)"

TMPDIR="$(mktemp -d)"
msiextract -C "$TMPDIR" "$OUT" >/dev/null 2>&1
MISMATCH=0
while IFS= read -r -d '' f; do
    rel="${f#files/}"
    extracted="$TMPDIR/Program Files/OpsLabAgent/$rel"
    if [ ! -f "$extracted" ] || ! cmp -s "$f" "$extracted"; then
        echo "    MISMATCH: $rel"
        MISMATCH=1
    fi
done < <(find files -type f -print0)
rm -rf "$TMPDIR"
if [ "$MISMATCH" -eq 0 ]; then
    echo "    All files round-trip byte-identical. Build looks good."
else
    echo "    FAILED round-trip check."
    exit 1
fi

echo ""
echo "Built: msi_build/$OUT"
echo ""
echo "To host it for download, copy it into the static installers folder:"
echo "  cp msi_build/$OUT app/static/installers/$OUT"
echo ""
echo "To test on a Windows machine:"
echo "  msiexec /i $OUT TOKEN=\"<token>\" ADMINURL=\"https://<admin-url>\" /l*v install.log"
