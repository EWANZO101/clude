#!/usr/bin/env bash
#
# Deploys the .env Editor module into an existing OpsLab Server Panel install.
#
# Usage:
#   ./deploy-envfiles.sh
#   ./deploy-envfiles.sh /path/to/server-panel
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP="$SCRIPT_DIR/envfiles-module.zip"

# Detect application directory
if [[ $# -ge 1 ]]; then
    APP_DIR="$1"
elif [[ -d "/root/server-panel" ]]; then
    APP_DIR="/root/server-panel"
elif [[ -d "/opt/server-panel" ]]; then
    APP_DIR="/opt/server-panel"
else
    echo "ERROR: Could not find the Server Panel installation."
    echo "Specify it manually:"
    echo "  ./deploy-envfiles.sh /path/to/server-panel"
    exit 1
fi

# Detect service
SERVICE=""

if systemctl list-unit-files | grep -q "^opslab-panel.service"; then
    SERVICE="opslab-panel"
elif systemctl list-unit-files | grep -q "^server-panel.service"; then
    SERVICE="server-panel"
fi

echo "Using application directory: $APP_DIR"

if [[ ! -d "$APP_DIR" ]]; then
    echo "ERROR: App directory not found: $APP_DIR"
    exit 1
fi

if [[ ! -f "$ZIP" ]]; then
    echo "ERROR: envfiles-module.zip not found."
    echo "Expected:"
    echo "  $ZIP"
    exit 1
fi

echo
echo "==> Creating backup..."

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$APP_DIR/backups/envfiles-deploy-$TS"

mkdir -p "$BACKUP_DIR"

FILES=(
    app.py
    models/role.py
    templates/base.html
)

for f in "${FILES[@]}"; do
    if [[ -f "$APP_DIR/$f" ]]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$f")"
        cp "$APP_DIR/$f" "$BACKUP_DIR/$f"
    fi
done

echo "Backup saved to:"
echo "  $BACKUP_DIR"

echo
echo "==> Extracting module..."

unzip -o "$ZIP" -d "$APP_DIR"

echo
echo "==> Restarting service..."

if [[ -n "$SERVICE" ]]; then
    systemctl restart "$SERVICE"

    echo
    systemctl --no-pager --full status "$SERVICE" | head -20
else
    echo "WARNING: No systemd service detected."
    echo "Restart your application manually."
fi

echo
echo "========================================"
echo "Deployment completed successfully."
echo "Application: $APP_DIR"
echo "Backup:      $BACKUP_DIR"
echo "========================================"