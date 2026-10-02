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
