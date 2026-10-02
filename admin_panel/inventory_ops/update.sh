#!/usr/bin/env bash
# Builds a new inventory-ops release zip from the current source, backs up
# what's currently deployed, unpacks the new version in place, and restarts
# the systemd service — run manually (or from cron) on this machine. Never
# touches admin_panel's Agent/Instance/Release pipeline; see
# tools/build_inventory_ops_release.py and service_files/systemd/
# opslab-inventory-ops.service for why.
#
# Usage: ./update.sh <version>
set -euo pipefail

VERSION="${1:?Usage: ./update.sh <version>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="opslab-inventory-ops"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

RELEASES_DIR="$HERE/releases"
BACKUP_DIR="$HERE/backups/$TIMESTAMP"
ZIP_PATH="$RELEASES_DIR/${VERSION}.zip"

mkdir -p "$RELEASES_DIR" "$BACKUP_DIR"

echo "[update] building release zip for version $VERSION..."
python3 "$HERE/tools/build_inventory_ops_release.py" "$VERSION" "$ZIP_PATH"

echo "[update] backing up current run.py/app/requirements.txt to $BACKUP_DIR"
cp -a "$HERE/run.py" "$BACKUP_DIR/" 2>/dev/null || true
cp -a "$HERE/app" "$BACKUP_DIR/" 2>/dev/null || true
cp -a "$HERE/requirements.txt" "$BACKUP_DIR/" 2>/dev/null || true

if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  echo "[update] stopping $SERVICE..."
  sudo systemctl stop "$SERVICE"
  RESTART=1
else
  RESTART=0
fi

echo "[update] unpacking new version into place..."
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP_PATH" "$HERE"

if [ "$RESTART" = "1" ]; then
  echo "[update] restarting $SERVICE..."
  sudo systemctl start "$SERVICE"
fi

echo "[update] done — inventory-ops is now at version $VERSION (backup: $BACKUP_DIR)"
