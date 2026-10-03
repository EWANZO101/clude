#!/usr/bin/env bash
# Self-contained fix — writes every missing file directly, no zip/upload
# needed. Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Creating app/static/installers/"
mkdir -p app/static/installers

echo "==> Writing install.sh"
cat > app/static/installers/install.sh << 'SH_EOF_MARKER'
#!/usr/bin/env bash
# OpsLab Instance Agent — Ubuntu/Debian installer (spec Section 5).
#
# Run as root from inside the instance_agent/ source directory:
#   sudo ./install/install.sh --token <enrollment_token> --admin-url https://admin.opslabsystems.cloud
#
# Steps (spec Section 5's numbered list): detect OS, check requirements,
# install dependencies, copy the app into place, create directories/venv,
# create the service user, write initial settings, install + enable the
# systemd unit, start it, and health-check that registration succeeded.
set -euo pipefail

INSTALL_DIR="/opt/opslab-agent"
DATA_DIR="/etc/opslab-agent"
SERVICE_USER="opslab-agent"
SERVICE_NAME="opslab-agent"

ADMIN_URL=""
TOKEN=""
DRY_RUN=0

usage() {
  echo "Usage: $0 --token <enrollment_token> --admin-url <url> [--dry-run]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --admin-url) ADMIN_URL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$TOKEN" ]] && { echo "ERROR: --token is required (get one from the Admin Panel's instances page)"; usage; }
[[ -z "$ADMIN_URL" ]] && { echo "ERROR: --admin-url is required"; usage; }

if [[ $DRY_RUN -eq 0 && "$EUID" -ne 0 ]]; then
  echo "ERROR: must be run as root (sudo)."
  exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")/.." 2>/dev/null && pwd || echo "")"

if [[ ! -d "$SOURCE_DIR/agent" ]]; then
  echo "No local agent/ source tree found next to this script — downloading it from the Admin Panel instead."
  DOWNLOAD_DIR="$(mktemp -d)"
  trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
  TARBALL_URL="${ADMIN_URL%/}/static/installers/opslab-agent.tar.gz"
  if [[ $DRY_RUN -eq 0 ]]; then
    curl -fsSL "$TARBALL_URL" -o "$DOWNLOAD_DIR/opslab-agent.tar.gz" || {
      echo "ERROR: could not download agent source from $TARBALL_URL"
      exit 1
    }
    tar -xzf "$DOWNLOAD_DIR/opslab-agent.tar.gz" -C "$DOWNLOAD_DIR"
  else
    echo "    + curl -fsSL $TARBALL_URL -o .../opslab-agent.tar.gz && tar -xzf ..."
  fi
  SOURCE_DIR="$DOWNLOAD_DIR"
fi

echo "==> [1/9] Detecting operating system..."
if [[ ! -f /etc/os-release ]]; then
  echo "ERROR: /etc/os-release not found — this installer supports Ubuntu/Debian only."
  exit 1
fi
. /etc/os-release
case "$ID" in
  ubuntu) OS_NAME="ubuntu" ;;
  debian) OS_NAME="debian" ;;
  *)
    if [[ "${ID_LIKE:-}" == *debian* ]]; then
      OS_NAME="debian"
      echo "    ($ID is not Ubuntu/Debian but looks Debian-like — proceeding as debian)"
    else
      echo "ERROR: unsupported OS '$ID'. This installer supports Ubuntu/Debian only."
      exit 1
    fi
    ;;
esac
echo "    Detected: $OS_NAME ($PRETTY_NAME)"

echo "==> [2/9] Checking system requirements..."
for cmd in python3 systemctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found."
    exit 1
  fi
done
PYTHON_VERSION="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
echo "    python3 $PYTHON_VERSION found."

run() {
  echo "    + $*"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$@"
  fi
}

echo "==> [3/9] Installing dependencies (python3-venv)..."
if [[ $DRY_RUN -eq 0 ]]; then
  if ! apt-get update -qq; then
    echo "    WARNING: 'apt-get update' reported errors (see above) — continuing, since the"
    echo "    package we need may still be installable from repos that did update cleanly."
  fi
  apt-get install -y -qq python3-venv
else
  echo "    (dry-run: skipping apt-get)"
fi

echo "==> [4/9] Creating service user '$SERVICE_USER'..."
if [[ $DRY_RUN -eq 0 ]]; then
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  else
    echo "    User already exists — leaving as-is."
  fi
else
  echo "    (dry-run: skipping useradd)"
fi

echo "==> [5/9] Copying application to $INSTALL_DIR..."
run mkdir -p "$INSTALL_DIR"
if [[ $DRY_RUN -eq 0 ]]; then
  rsync -a --delete --exclude "settings.json" --exclude "__pycache__" \
    "$SOURCE_DIR"/agent "$SOURCE_DIR"/requirements.txt "$INSTALL_DIR"/
else
  echo "    + rsync -a $SOURCE_DIR/{agent,requirements.txt} $INSTALL_DIR/"
fi

echo "==> [6/9] Creating directories..."
for d in "$DATA_DIR" "$INSTALL_DIR/app" "$INSTALL_DIR/downloads" "$INSTALL_DIR/recovery"; do
  run mkdir -p "$d"
done

echo "==> [7/9] Setting up Python virtual environment..."
if [[ $DRY_RUN -eq 0 ]]; then
  python3 -m venv "$INSTALL_DIR/venv"
  "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
  "$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"
else
  echo "    + python3 -m venv $INSTALL_DIR/venv && pip install -r requirements.txt"
fi

echo "==> [8/9] Writing initial configuration..."
SETTINGS_JSON="$DATA_DIR/settings.json"
if [[ $DRY_RUN -eq 0 ]]; then
  cat > "$SETTINGS_JSON" <<JSON
{
  "admin_url": "$ADMIN_URL",
  "registration_token": "$TOKEN",
  "instance_id": null,
  "instance_secret": null,
  "heartbeat_interval_seconds": 60,
  "config_poll_interval_seconds": 30,
  "update_poll_interval_seconds": 60,
  "app_install_dir": "$INSTALL_DIR/app",
  "download_dir": "$INSTALL_DIR/downloads",
  "recovery_dir": "$INSTALL_DIR/recovery",
  "kiosk_config_path": "$DATA_DIR/kiosk_config.json"
}
JSON
  chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR" "$INSTALL_DIR"
  chmod 600 "$SETTINGS_JSON"
else
  echo "    + write $SETTINGS_JSON (admin_url=$ADMIN_URL, registration_token=<redacted>)"
fi

echo "==> [9/9] Installing and starting the systemd service..."
UNIT_SRC="$SOURCE_DIR/service_files/systemd/opslab-agent.service"
UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"
if [[ $DRY_RUN -eq 0 ]]; then
  sed "s#WorkingDirectory=.*#WorkingDirectory=$INSTALL_DIR#; s#ExecStart=.*#ExecStart=$INSTALL_DIR/venv/bin/python -m agent.main#" \
    "$UNIT_SRC" > "$UNIT_DST"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

  echo "==> Waiting for registration to complete..."
  for i in $(seq 1 15); do
    if grep -q '"instance_id": *"[^"]' "$SETTINGS_JSON" 2>/dev/null; then
      echo "    Registered successfully."
      break
    fi
    sleep 1
    if [[ $i -eq 15 ]]; then
      echo "    WARNING: registration not confirmed after 15s — check: journalctl -u $SERVICE_NAME -f"
    fi
  done

  systemctl status "$SERVICE_NAME" --no-pager || true
else
  echo "    + install unit -> $UNIT_DST, systemctl daemon-reload, enable, restart $SERVICE_NAME"
  echo "(dry-run complete — no system changes were made)"
fi

echo ""
echo "Done. Logs: journalctl -u $SERVICE_NAME -f"
SH_EOF_MARKER
chmod +x app/static/installers/install.sh
echo "    install.sh written ($(wc -c < app/static/installers/install.sh) bytes)"

echo "==> Writing install.ps1"
cat > app/static/installers/install.ps1 << 'PS1_EOF_MARKER'
#Requires -RunAsAdministrator
<#
OpsLab Instance Agent — Windows installer (spec Section 6's MSI-equivalent
steps), implemented as a PowerShell script rather than an actual .msi.

HONEST LIMITATION: this has NOT been run on a real Windows machine — this
build environment is Linux-only. It's written to mirror install.sh's real,
tested steps exactly (same directory layout, same settings.json shape, same
registration flow), and uses the standard, well-documented mechanisms for
each Windows equivalent (sc.exe for service registration/failure actions,
py -3 -m venv for the virtualenv), but needs a real Windows smoke test
before being trusted in production — same caveat already on record for
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
        Write-Host "    WARNING: registration not confirmed after 15s — check the Windows Event Log (Application) for OpsLabAgent."
    }
}

Write-Host ""
Write-Host "Done. Service name: $ServiceName (Services console, or 'sc.exe query $ServiceName')"
PS1_EOF_MARKER
echo "    install.ps1 written ($(wc -c < app/static/installers/install.ps1) bytes)"

echo "==> Writing opslab-agent.tar.gz (base64-decoded)"
base64 -d > app/static/installers/opslab-agent.tar.gz << 'B64_EOF_MARKER'
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
B64_EOF_MARKER
echo "    opslab-agent.tar.gz written ($(wc -c < app/static/installers/opslab-agent.tar.gz) bytes)"
tar -tzf app/static/installers/opslab-agent.tar.gz > /dev/null && echo "    tarball verified readable" || echo "    ERROR: tarball is corrupt!"

echo "==> Patching app/__init__.py to add the /install.sh and /install.ps1 routes"
python3 << 'PYEOF'
path = "app/__init__.py"
with open(path) as f:
    content = f.read()

if "install_sh" in content:
    print("    Routes already present — skipping patch.")
else:
    marker = "    return app"
    count = content.count(marker)
    if count != 1:
        raise SystemExit(
            f"    ERROR: expected exactly one '{marker}' line in {path}, found {count}. "
            f"Not patching automatically — paste app/__init__.py's content back for a manual fix."
        )
    routes = '''    @app.route("/install.sh")
    def install_sh():
        from flask import send_from_directory
        return send_from_directory(
            os.path.join(app.root_path, "static", "installers"), "install.sh",
            mimetype="text/x-sh",
        )

    @app.route("/install.ps1")
    def install_ps1():
        from flask import send_from_directory
        return send_from_directory(
            os.path.join(app.root_path, "static", "installers"), "install.ps1",
            mimetype="text/plain",
        )

    return app'''
    content = content.replace(marker, routes, 1)
    with open(path, "w") as f:
        f.write(content)
    print("    Patched successfully.")
PYEOF

echo "==> Verifying app/__init__.py imports 'os' (needed by the new routes)"
if ! grep -q "^import os" app/__init__.py; then
  sed -i '1i import os' app/__init__.py
  echo "    Added 'import os' at the top of app/__init__.py"
else
  echo "    'import os' already present."
fi

echo ""
echo "=== Files written. Now restart the app. ==="
echo "You're running it directly (python run.py), not as a systemd service, so:"
echo ""
echo "    pkill -f 'admin_panel/run.py'"
echo "    cd /root/admin_panel && source venv/bin/activate && nohup python run.py > /root/admin_panel/app.log 2>&1 &"
echo ""
echo "Then verify:"
echo "    curl -s -o /dev/null -w 'install.sh -> %{http_code}\\n' http://127.0.0.1:5000/install.sh"
echo "    curl -s -o /dev/null -w 'install.ps1 -> %{http_code}\\n' http://127.0.0.1:5000/install.ps1"
