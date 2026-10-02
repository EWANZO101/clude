#!/usr/bin/env bash
# Installs this Claude Multi-Account Manager project onto an Ubuntu box:
# system deps, venv, Tailwind build, systemd service, nginx reverse proxy.
# Run this script FROM INSIDE the project directory (where it lives on disk).
#
# Usage: sudo bash install.sh [install_dir] [domain] [port]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-/opt/claude-manager}"
DOMAIN="${2:-}"
PORT="${3:-5057}"
SERVICE_NAME="claude-manager"
APP_USER="claude-manager"

echo "==> Installing Claude Multi-Account Manager"
echo "    source: $SRC_DIR"
echo "    dir:    $INSTALL_DIR"
echo "    port:   $PORT"
echo "    domain: ${DOMAIN:-<none>}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip screen nginx sqlite3 curl openssl rsync

if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$APP_USER"
fi

mkdir -p "$INSTALL_DIR"
rsync -a --exclude 'venv' --exclude '.git' --exclude '.env' "$SRC_DIR"/ "$INSTALL_DIR"/
mkdir -p "$INSTALL_DIR"/{instance,logs,claude_homes}

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" >/dev/null

# --- .env with real secrets ---
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  SECRET_KEY="$(openssl rand -hex 32)"
  ADMIN_USER="admin"
  ADMIN_PASS="$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-16)"
  cat > "$INSTALL_DIR/.env" <<ENVEOF
SECRET_KEY=$SECRET_KEY
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
PORT=$PORT
DATABASE_URL=sqlite:///$INSTALL_DIR/instance/claude_manager.db
CLAUDE_HOMES_DIR=$INSTALL_DIR/claude_homes
LOG_DIR=$INSTALL_DIR/logs
ENVEOF
  echo "$ADMIN_USER" > /tmp/.claude_manager_admin_user
  echo "$ADMIN_PASS" > /tmp/.claude_manager_admin_pass
else
  echo "==> .env already exists, leaving it in place"
fi

# --- Tailwind build ---
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) TW_ARCH="linux-x64" ;;
  aarch64|arm64) TW_ARCH="linux-arm64" ;;
  *) TW_ARCH="linux-x64" ;;
esac
if [[ ! -x "$INSTALL_DIR/tailwindcss" ]]; then
  curl -sSL -o "$INSTALL_DIR/tailwindcss" \
    "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-${TW_ARCH}"
  chmod +x "$INSTALL_DIR/tailwindcss"
fi
"$INSTALL_DIR/tailwindcss" \
  -i "$INSTALL_DIR/app/static/css/input.css" \
  -o "$INSTALL_DIR/app/static/css/output.css" \
  --minify \
  --config "$INSTALL_DIR/tailwind.config.js"

# --- Init DB ---
( cd "$INSTALL_DIR/app" && "$INSTALL_DIR/venv/bin/python3" -c "from app import app, db; app.app_context().push(); db.create_all()" )

chown -R "$APP_USER":"$APP_USER" "$INSTALL_DIR"
chmod 600 "$INSTALL_DIR/.env"

# --- systemd ---
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=Claude Multi-Account Manager
After=network.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$INSTALL_DIR/app
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/gunicorn -w 2 -b 127.0.0.1:$PORT app:app
Restart=on-failure
RestartSec=3

# The app spawns long-lived \`screen\` sessions (each running a \`claude\` CLI
# instance) as children of a gunicorn worker. They fully daemonize, but stay
# in this unit's cgroup. Without this, systemd's default KillMode kills that
# whole cgroup on every stop/restart — silently killing every account's
# session (including ones mid-login) along with the web app.
KillMode=process

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# --- nginx ---
SERVER_NAME="${DOMAIN:-_}"
cat > "/etc/nginx/sites-available/${SERVICE_NAME}" <<NGEOF
server {
    listen 80;
    server_name $SERVER_NAME;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGEOF
ln -sf "/etc/nginx/sites-available/${SERVICE_NAME}" "/etc/nginx/sites-enabled/${SERVICE_NAME}"
nginx -t && systemctl reload nginx

echo ""
echo "============================================================"
echo " Claude Multi-Account Manager installed at $INSTALL_DIR"
echo "============================================================"
echo " URL:        http://${DOMAIN:-<server-ip>}/"
if [[ -f /tmp/.claude_manager_admin_user ]]; then
  echo " Admin user: $(cat /tmp/.claude_manager_admin_user)"
  echo " Admin pass: $(cat /tmp/.claude_manager_admin_pass)"
  rm -f /tmp/.claude_manager_admin_user /tmp/.claude_manager_admin_pass
fi
echo " Service:    systemctl {status|restart|stop} $SERVICE_NAME"
echo " Logs:       journalctl -u $SERVICE_NAME -f"
echo ""
echo " NOTE: install the 'claude' CLI for the '$APP_USER' user, then per"
echo " account either set an API key in the dashboard or run"
echo " 'CLAUDE_CONFIG_DIR=<account config dir> claude login' once as $APP_USER."
echo "============================================================"
