#!/usr/bin/env bash
# StockTool Kiosk -- Ubuntu setup / disaster-recovery script.
#
# What this does:
#   1. Creates a Python venv and installs the app's dependencies
#      (skips pyinstaller -- that's only needed to build a Windows
#      .exe, not to run the app itself).
#   2. Restores a backup .db file into the data directory the app
#      expects on Linux: ~/StockToolKiosk/kiosk_local.db
#      (same fallback logic app/__init__.py's _local_data_dir() uses
#      on Windows when %ProgramData%/%LocalAppData% aren't set -- on
#      Linux neither exists, so it falls back to $HOME/StockToolKiosk).
#   3. Installs + starts a systemd service (Linux equivalent of the
#      NSSM Windows service) so it survives reboots/crashes on its own.
#
# Usage:
#   ./setup-ubuntu.sh /path/to/backup.db
#   (backup path is optional -- omit it to just set up a fresh, empty DB)
#
# Run this FROM the extracted project folder (the one with main.py in it).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/StockToolKiosk"
BACKUP_PATH="${1:-}"
SERVICE_NAME="stocktool-kiosk"
RUN_USER="$(whoami)"

echo "============================================================"
echo "  StockTool Kiosk -- Ubuntu setup"
echo "============================================================"
echo "  Project dir: $PROJECT_DIR"
echo "  Data dir:    $DATA_DIR"
echo

# --- 1. System packages ------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    echo "[1/5] Installing python3..."
    sudo apt update
    sudo apt install -y python3 python3-pip python3-venv
else
    echo "[1/5] python3 already installed: $(python3 --version)"
fi

# --- 2. Virtualenv + dependencies --------------------------------------
echo "[2/5] Setting up virtualenv and installing dependencies..."
cd "$PROJECT_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
# Skip pyinstaller -- only needed to build the Windows .exe, not to run
grep -v -i '^pyinstaller' requirements.txt > /tmp/requirements-linux.txt
pip install -r /tmp/requirements-linux.txt -q
deactivate
echo "    Done."

# --- 3. Data directory + backup restore --------------------------------
echo "[3/5] Setting up data directory..."
mkdir -p "$DATA_DIR"

if [ -n "$BACKUP_PATH" ]; then
    if [ ! -f "$BACKUP_PATH" ]; then
        echo "    ERROR: backup file not found at $BACKUP_PATH" >&2
        exit 1
    fi
    if [ -f "$DATA_DIR/kiosk_local.db" ]; then
        ts=$(date +%Y%m%d_%H%M%S)
        cp "$DATA_DIR/kiosk_local.db" "$DATA_DIR/kiosk_local.db.bak_$ts"
        echo "    Existing DB found -- backed it up to kiosk_local.db.bak_$ts first."
    fi
    cp "$BACKUP_PATH" "$DATA_DIR/kiosk_local.db"
    echo "    Restored backup: $BACKUP_PATH -> $DATA_DIR/kiosk_local.db"
else
    echo "    No backup path given -- a fresh, empty database will be created on first run."
fi

if [ -f "$PROJECT_DIR/license.txt" ] && [ ! -f "$DATA_DIR/license.txt" ]; then
    cp "$PROJECT_DIR/license.txt" "$DATA_DIR/license.txt"
    echo "    Copied license.txt into the data directory."
fi

# --- 4. systemd service --------------------------------------------------
echo "[4/5] Installing systemd service..."
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=StockTool Kiosk API
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/python3 $PROJECT_DIR/main.py --service
Restart=on-failure
RestartSec=3
StandardOutput=append:$DATA_DIR/service-stdout.log
StandardError=append:$DATA_DIR/service-stderr.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
echo "    Service installed and started."

# --- 5. Verify -----------------------------------------------------------
echo "[5/5] Verifying..."
sleep 3
PORT=$(python3 - <<PYEOF
import json, os
p = os.path.join(os.path.expanduser("~"), "StockToolKiosk", "settings.json")
try:
    print(json.load(open(p)).get("port", 8420))
except Exception:
    print(8420)
PYEOF
)
if curl -sf "http://127.0.0.1:${PORT}/api/status" > /dev/null 2>&1; then
    echo "    ✓ Kiosk API is responding on port $PORT."
else
    echo "    Could not confirm the API yet -- check logs:"
    echo "      sudo journalctl -u $SERVICE_NAME -n 50"
    echo "      cat $DATA_DIR/service-stderr.log"
fi

echo
echo "============================================================"
echo "  Done."
echo "  Kiosk UI:    http://127.0.0.1:${PORT}/ui/"
echo "  Admin Panel: http://127.0.0.1:8423/ui/admin"
echo
echo "  Service commands:"
echo "    sudo systemctl status  $SERVICE_NAME"
echo "    sudo systemctl restart $SERVICE_NAME"
echo "    sudo systemctl stop    $SERVICE_NAME"
echo "    sudo journalctl -u $SERVICE_NAME -f     # live logs"
echo "============================================================"
