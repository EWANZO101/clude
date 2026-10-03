#!/usr/bin/env bash
# MotoGuard Recovery Network — installer
# Runs preflight checks, sets up a venv, installs deps, initialises the DB,
# runs an import smoke test, then launches via systemd (if available) or gunicorn.
set -euo pipefail

# ----------------------------------------------------------------------------
# Config (override via env: PORT=5060 APP_USER=motoguard ./install.sh)
# ----------------------------------------------------------------------------
APP_NAME="motoguard"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-5060}"
WORKERS="${WORKERS:-3}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="${SERVICE_NAME:-motoguard}"
APP_USER="${APP_USER:-$(id -un)}"
USE_SYSTEMD="${USE_SYSTEMD:-auto}"     # auto | yes | no
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://localhost:${PORT}}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; NC='\033[0m'
ok(){   echo -e "  ${GREEN}✔${NC} $1"; }
warn(){ echo -e "  ${YEL}!${NC} $1"; }
fail(){ echo -e "  ${RED}x${NC} $1"; exit 1; }
step(){ echo -e "\n${GREEN}==>${NC} $1"; }

# ----------------------------------------------------------------------------
step "1/7  Preflight checks"

command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "$PYTHON_BIN not found. Install Python 3.10+."
PYV=$("$PYTHON_BIN" -c 'import sys;print("%d.%d"%sys.version_info[:2])')
PYMAJ=$("$PYTHON_BIN" -c 'import sys;print(sys.version_info[0])')
PYMIN=$("$PYTHON_BIN" -c 'import sys;print(sys.version_info[1])')
if [ "$PYMAJ" -lt 3 ] || { [ "$PYMAJ" -eq 3 ] && [ "$PYMIN" -lt 10 ]; }; then
  fail "Python 3.10+ required (found $PYV)."
fi
ok "Python $PYV"

"$PYTHON_BIN" -m venv --help >/dev/null 2>&1 || fail "python venv module missing. apt install python3-venv"
ok "venv module present"

if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$" && \
    fail "Port ${PORT} already in use. Set PORT=xxxx and re-run." || ok "Port ${PORT} free"
elif command -v lsof >/dev/null 2>&1; then
  lsof -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1 && \
    fail "Port ${PORT} already in use." || ok "Port ${PORT} free"
else
  warn "Cannot verify port ${PORT} (no ss/lsof) — continuing"
fi

AVAIL_KB=$(df -Pk "$APP_DIR" | awk 'NR==2{print $4}')
[ "${AVAIL_KB:-0}" -gt 204800 ] && ok "Disk space OK" || warn "Low disk space (<200MB)"

[ -f "$APP_DIR/requirements.txt" ] || fail "requirements.txt missing — run from the unzipped folder."
[ -f "$APP_DIR/wsgi.py" ] || fail "wsgi.py missing — incomplete extraction?"
ok "Project files present"

# ----------------------------------------------------------------------------
step "2/7  Python virtual environment"
if [ ! -d "$APP_DIR/.venv" ]; then
  "$PYTHON_BIN" -m venv "$APP_DIR/.venv"
  ok "Created .venv"
else
  ok ".venv already exists"
fi
# shellcheck disable=SC1091
source "$APP_DIR/.venv/bin/activate"

# ----------------------------------------------------------------------------
step "3/7  Dependencies"
pip install --upgrade pip >/dev/null 2>&1 || true
pip install -r "$APP_DIR/requirements.txt"
ok "Dependencies installed"

# ----------------------------------------------------------------------------
step "4/7  Configuration"
ENV_FILE="$APP_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  SECRET=$("$PYTHON_BIN" -c 'import secrets;print(secrets.token_hex(32))')
  cat > "$ENV_FILE" <<ENVEOF
SECRET_KEY="${SECRET}"
PORT="${PORT}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL}"
ALERT_RADIUS_MILES="40"
# --- SMTP (optional; if blank, alert emails are logged to the service journal) ---
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""
SMTP_TLS="true"
MAIL_FROM="alerts@motoguard.local"
MAIL_SENDER_NAME="MotoGuard Recovery"
# --- Google Places location autocomplete (optional) ---
GOOGLE_MAPS_API_KEY=""
# --- DVSA MOT History API (optional; enables reg auto-fill on register) ---
MOT_CLIENT_ID=""
MOT_CLIENT_SECRET=""
MOT_API_KEY=""
MOT_TOKEN_URL=""
MOT_SCOPE="https://tapi.dvsa.gov.uk/.default"
MOT_API_BASE="https://history.mot.api.gov.uk"
ENVEOF
  ok "Wrote .env (generated SECRET_KEY)"
else
  ok ".env already exists (left untouched)"
fi
set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a

# ----------------------------------------------------------------------------
step "5/7  Database init + seed"
ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASSWORD="$ADMIN_PASSWORD" ADMIN_USERNAME="$ADMIN_USERNAME" \
  "$PYTHON_BIN" - <<PYEOF
from motoguard import create_app
from motoguard.seed import seed
seed(create_app())
PYEOF
ok "Database ready"
[ -n "$ADMIN_EMAIL" ] && ok "Admin user: $ADMIN_EMAIL" || warn "No ADMIN_EMAIL set — create an account and promote it later, or re-run with ADMIN_EMAIL/ADMIN_PASSWORD."

# ----------------------------------------------------------------------------
step "6/7  Smoke test"
"$PYTHON_BIN" - <<'PYEOF'
from motoguard import create_app
app = create_app()
c = app.test_client()
assert c.get('/').status_code in (200, 302), 'landing failed'
assert c.get('/auth/login').status_code == 200, 'login page failed'
assert c.get('/forum/').status_code == 200, 'forum failed'
assert c.get('/api/stolen.json').status_code == 200, 'api failed'
print('smoke test: all core routes respond')
PYEOF
ok "Smoke test passed"

# ----------------------------------------------------------------------------
step "7/7  Launch"
GUNICORN="$APP_DIR/.venv/bin/gunicorn"

launch_nohup(){
  warn "Launching with nohup gunicorn (no systemd)"
  cd "$APP_DIR"
  nohup "$GUNICORN" -w "$WORKERS" -b "0.0.0.0:${PORT}" wsgi:app \
    >"$APP_DIR/motoguard.log" 2>&1 &
  sleep 2
  ok "Started (PID $!). Logs: $APP_DIR/motoguard.log"
}

install_systemd(){
  local unit="/etc/systemd/system/${SERVICE_NAME}.service"
  sudo tee "$unit" >/dev/null <<UNITEOF
[Unit]
Description=MotoGuard Recovery Network
After=network.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${GUNICORN} -w ${WORKERS} -b 0.0.0.0:${PORT} wsgi:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  sudo systemctl restart "${SERVICE_NAME}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "systemd service '${SERVICE_NAME}' active"
  else
    warn "Service not active — falling back to nohup"
    launch_nohup
  fi
}

case "$USE_SYSTEMD" in
  no)  launch_nohup ;;
  yes) install_systemd ;;
  *)   if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
         install_systemd
       else
         launch_nohup
       fi ;;
esac

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN} MotoGuard is up:${NC} ${PUBLIC_BASE_URL}"
echo -e " Local:  http://localhost:${PORT}"
[ -n "$ADMIN_EMAIL" ] && echo -e " Admin login: ${ADMIN_EMAIL}"
echo -e " Service: sudo systemctl {status,restart,stop} ${SERVICE_NAME}"
echo -e " Config:  ${ENV_FILE}  (add SMTP creds to send real alert emails)"
echo -e "${GREEN}========================================${NC}"
