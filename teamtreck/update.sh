#!/usr/bin/env bash
#
# update.sh - update/deploy TeamTreck
#
# Run this from the project root (where run.py lives) after pulling new
# code in, or after unzipping a newer phase zip over the top of an existing
# install. Handles: backing up the sqlite db, installing/updating deps,
# and restarting the app (systemd service if one exists, otherwise a
# plain background gunicorn/python process).
#
# Usage:
#   ./update.sh                 # normal update
#   ./update.sh --no-restart    # update deps/files only, don't restart
#
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

SERVICE_NAME="teamtreck"
DB_FILE="teamtreck.db"
BACKUP_DIR="backups"
VENV_DIR="venv"
PORT="${TEAMTRECK_PORT:-5050}"
NO_RESTART=false

for arg in "$@"; do
    case "$arg" in
        --no-restart) NO_RESTART=true ;;
    esac
done

echo "==> TeamTreck update starting in $APP_DIR"

# ---------- 1. Backup the database ----------
if [ -f "$DB_FILE" ]; then
    mkdir -p "$BACKUP_DIR"
    ts=$(date +%Y%m%d_%H%M%S)
    cp "$DB_FILE" "$BACKUP_DIR/teamtreck_${ts}.db"
    echo "==> Backed up $DB_FILE -> $BACKUP_DIR/teamtreck_${ts}.db"

    # keep only the 10 most recent backups
    ls -1t "$BACKUP_DIR"/teamtreck_*.db 2>/dev/null | tail -n +11 | xargs -r rm --
else
    echo "==> No existing $DB_FILE found, skipping backup (fresh install)"
fi

# ---------- 2. Set up / reuse virtualenv ----------
if [ ! -d "$VENV_DIR" ]; then
    echo "==> Creating virtualenv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "==> Installing/updating dependencies"
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

# gunicorn isn't in requirements.txt (dev server is fine for `python run.py`,
# but production should use gunicorn) - install it here if missing
pip install --quiet gunicorn

# ---------- 3. Restart ----------
if [ "$NO_RESTART" = true ]; then
    echo "==> --no-restart passed, skipping restart. Update complete."
    exit 0
fi

if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    echo "==> Restarting systemd service: $SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"
    sleep 2
    sudo systemctl status "$SERVICE_NAME" --no-pager -l | head -15
else
    echo "==> No systemd service named '$SERVICE_NAME' found."
    echo "==> Falling back to a plain background gunicorn process on port $PORT."
    echo "==> (To run this properly under systemd, see the sample unit file"
    echo "==>  printed below and save it as /etc/systemd/system/${SERVICE_NAME}.service)"

    # kill any existing plain-process instance we started previously
    pkill -f "gunicorn.*run:app.*:${PORT}" 2>/dev/null || true
    sleep 1

    nohup "$VENV_DIR/bin/gunicorn" -w 2 -b "0.0.0.0:${PORT}" run:app \
        > "${APP_DIR}/teamtreck.log" 2>&1 &
    disown

    sleep 2
    if curl -s -o /dev/null -w "" "http://localhost:${PORT}/auth/login"; then
        echo "==> App is up at http://localhost:${PORT}"
    else
        echo "==> WARNING: could not confirm the app responded. Check teamtreck.log"
    fi

    cat <<EOF

------------------------------------------------------------
Sample systemd unit (recommended for production use instead
of the background process above). Save as:
  /etc/systemd/system/${SERVICE_NAME}.service
then: sudo systemctl daemon-reload && sudo systemctl enable --now ${SERVICE_NAME}

[Unit]
Description=TeamTreck
After=network.target

[Service]
User=$(whoami)
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/${VENV_DIR}/bin/gunicorn -w 2 -b 0.0.0.0:${PORT} run:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
------------------------------------------------------------
EOF
fi

echo "==> Update complete."
