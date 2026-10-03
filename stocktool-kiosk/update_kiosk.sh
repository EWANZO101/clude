#!/usr/bin/env bash
# update_kiosk.sh
#
# Updates the StockTool Kiosk Flask app running on the Ubuntu server
# (not the Windows .exe/.msi build). Extracts a source zip, backs up
# the live deployment, syncs in the new code (skipping Windows-only
# packaging cruft: installer/, dist/, vendor/, *.iss, *.wxs*, *.bat,
# *.exe, *.msi, build.spec/build.ps1), reinstalls requirements, and
# restarts the systemd service.
#
# Adjust APP_DIR / SERVICE_NAME / VENV_DIR below if they don't match
# your actual deployment.
#
# Usage:
#   ./update_kiosk.sh /path/to/kiosk-source.zip

set -euo pipefail

APP_DIR="/root/stocktool-kiosk"   # <-- adjust if different
SERVICE_NAME="stocktool-kiosk"   # <-- systemd unit name, adjust if different
VENV_DIR="$APP_DIR/venv"         # <-- adjust if your venv lives elsewhere

ZIP_FILE="${1:-}"
if [ -z "$ZIP_FILE" ] || [ ! -f "$ZIP_FILE" ]; then
    echo "Usage: $0 /path/to/kiosk-source.zip"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Run as root (systemctl + writing under $APP_DIR)."
    exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/opt/stocktool-kiosk-backups/$TS"

# Files/dirs that only matter for the Windows exe/msi build -- never
# touch these on the Linux deployment.
WIN_ONLY_EXCLUDES=(
    --exclude installer
    --exclude dist
    --exclude vendor
    --exclude "*.iss"
    --exclude "*.wxs*"
    --exclude "*.bat"
    --exclude "*.exe"
    --exclude "*.msi"
    --exclude "*.wixpdb"
    --exclude build.spec
    --exclude build.ps1
    --exclude nssm.exe
)

echo "== 1/5: Stopping $SERVICE_NAME =="
systemctl stop "$SERVICE_NAME" || echo "  (service wasn't running -- continuing)"

echo "== 2/5: Backing up current deployment to $BACKUP_DIR =="
mkdir -p "$BACKUP_DIR"
if [ -d "$APP_DIR" ]; then
    rsync -a --exclude venv --exclude __pycache__ --exclude instance --exclude data \
        "$APP_DIR"/ "$BACKUP_DIR"/
fi

echo "== 3/5: Extracting update =="
TMP_EXTRACT="$(mktemp -d)"
unzip -q "$ZIP_FILE" -d "$TMP_EXTRACT"

# The zip may contain a single top-level folder (e.g. "07/") -- find
# the dir that actually has main.py in it and sync from there.
SRC_DIR="$TMP_EXTRACT"
if [ ! -f "$SRC_DIR/main.py" ]; then
    FOUND="$(find "$TMP_EXTRACT" -maxdepth 3 -name main.py -not -path "*/dist/*" | head -n 1)"
    if [ -n "$FOUND" ]; then
        SRC_DIR="$(dirname "$FOUND")"
    else
        echo "ERROR: couldn't find main.py in the extracted zip."
        rm -rf "$TMP_EXTRACT"
        exit 1
    fi
fi

rsync -a --exclude venv --exclude __pycache__ --exclude instance --exclude data \
    --exclude ".git" "${WIN_ONLY_EXCLUDES[@]}" \
    "$SRC_DIR"/ "$APP_DIR"/
rm -rf "$TMP_EXTRACT"

echo "== 4/5: Installing/upgrading dependencies =="
if [ -x "$VENV_DIR/bin/pip" ]; then
    "$VENV_DIR/bin/pip" install -q -r "$APP_DIR/requirements.txt"
else
    echo "  No venv found at $VENV_DIR -- skipping (adjust VENV_DIR if wrong)."
fi

echo "== 5/5: Restarting $SERVICE_NAME =="
systemctl start "$SERVICE_NAME"
sleep 1
systemctl --no-pager status "$SERVICE_NAME" | head -n 5

echo
echo "Done. Previous deployment backed up at: $BACKUP_DIR"
