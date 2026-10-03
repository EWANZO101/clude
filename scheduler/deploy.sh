#!/usr/bin/env bash
# deploy.sh — run this every time you update the code. It does everything
# an update needs so nothing gets forgotten: install deps, rebuild CSS,
# run migrations, restart the service, then verify it's actually up.
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Overrides:
#   APP_DIR=/opt/scheduler SERVICE_NAME=my-service PORT=5076 ./deploy.sh

set -uo pipefail

APP_DIR="${APP_DIR:-/root/scheduler}"
SERVICE_NAME="${SERVICE_NAME:-scheduler}"
PORT="${PORT:-5076}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
die()  { fail "$1"; exit 1; }

cd "$APP_DIR" 2>/dev/null || die "APP_DIR '$APP_DIR' doesn't exist. Set it: APP_DIR=/path ./deploy.sh"
[ -f "run.py" ] || die "No run.py in $APP_DIR — wrong directory?"

bold "== 1. Python dependencies =="
if [ -x "$APP_DIR/.venv/bin/python" ]; then
  PY="$APP_DIR/.venv/bin/python"
elif [ -x "$APP_DIR/venv/bin/python" ]; then
  PY="$APP_DIR/venv/bin/python"
else
  PY="$(command -v python3)"
  warn "No venv found — using system Python ($PY)"
fi

if "$PY" -m pip install --quiet -r requirements.txt; then
  ok "Dependencies up to date ($PY)"
else
  die "pip install failed — see output above"
fi

bold "== 2. Frontend build =="
if [ -f "package.json" ]; then
  if command -v npm >/dev/null; then
    if npm install --silent && npm run build:css --silent; then
      ok "CSS rebuilt (app/static/css/main.css)"
    else
      die "CSS build failed — see output above. The app will still run but will look broken/unstyled until this succeeds."
    fi
  else
    fail "npm not found — can't rebuild CSS. Install Node.js, or the site will serve stale/broken styles."
    exit 1
  fi
else
  warn "No package.json found — skipping CSS build"
fi

bold "== 3. Database migrations =="
export FLASK_APP="${FLASK_APP:-run.py}"
if [ ! -d "migrations/versions" ] || [ -z "$(ls -A migrations/versions 2>/dev/null)" ]; then
  die "migrations/versions is missing or empty — this deploy didn't include the migrations folder."
fi
if "$PY" -m flask db upgrade; then
  ok "Migrations applied"
else
  die "flask db upgrade failed — see output above"
fi

bold "== 4. Restarting the service =="
RESTARTED=0
if command -v systemctl >/dev/null && systemctl list-units --full -all 2>/dev/null | grep -q "${SERVICE_NAME}.service"; then
  if systemctl restart "$SERVICE_NAME"; then
    ok "Restarted systemd service '$SERVICE_NAME'"
    RESTARTED=1
  else
    fail "systemctl restart failed — check: sudo journalctl -u $SERVICE_NAME -n 50"
    exit 1
  fi
else
  warn "No systemd service named '$SERVICE_NAME' found."
  echo "    Set one up once with the provided scheduler.service file so this step can be"
  echo "    automatic from now on. For today, restart gunicorn manually:"
  echo "      pkill -f gunicorn"
  echo "      cd $APP_DIR && $PY -m gunicorn -w 3 -b 0.0.0.0:$PORT run:app &"
fi

bold "== 5. Health check =="
sleep 2
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/auth/login" 2>/dev/null)
[ -z "$CODE" ] && CODE="000"
if [ "$CODE" = "200" ]; then
  ok "App responding on port $PORT (HTTP 200)"
else
  fail "App did NOT respond correctly on port $PORT (got HTTP $CODE)."
  if [ "$RESTARTED" = "1" ]; then
    echo "    Check logs: sudo journalctl -u $SERVICE_NAME -n 50 --no-pager"
  else
    echo "    Since it wasn't auto-restarted, this may just mean it's not running yet — start it and re-check."
  fi
  exit 1
fi

echo
bold "Deploy complete."
