#!/usr/bin/env bash
# fix_db.sh — resolves "sqlite3.OperationalError: no such table: users"
# by finding the app, running migrations against it, and verifying the fix.
#
# Usage:
#   chmod +x fix_db.sh
#   ./fix_db.sh
#
# Override any of these if your setup differs from the defaults:
#   APP_DIR=/opt/scheduler ./fix_db.sh
#   SERVICE_NAME=my-scheduler ./fix_db.sh

set -uo pipefail

APP_DIR="${APP_DIR:-/root/scheduler}"
SERVICE_NAME="${SERVICE_NAME:-scheduler}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

bold "== 1. Locating the app =="
if [ ! -d "$APP_DIR" ]; then
  fail "APP_DIR '$APP_DIR' doesn't exist. Set it explicitly: APP_DIR=/path/to/scheduler ./fix_db.sh"
  exit 1
fi
cd "$APP_DIR" || exit 1
ok "Using $APP_DIR"

if [ ! -f "run.py" ]; then
  fail "No run.py found in $APP_DIR — is this the right directory?"
  exit 1
fi

if [ ! -d "migrations/versions" ] || [ -z "$(ls -A migrations/versions 2>/dev/null)" ]; then
  fail "migrations/versions is missing or empty."
  echo "    This usually means the migrations folder wasn't copied/deployed along with the"
  echo "    rest of the app (e.g. excluded by .gitignore or a partial rsync/scp). Without it,"
  echo "    'flask db upgrade' has nothing to apply, and the tables can never get created."
  echo "    Re-deploy the full project including migrations/, then re-run this script."
  exit 1
fi
ok "migrations/versions found"

bold "== 2. Finding the right Python/Flask =="
PYTHON_BIN=""
if [ -x "$APP_DIR/.venv/bin/python" ]; then
  PYTHON_BIN="$APP_DIR/.venv/bin/python"
  ok "Using venv at .venv"
elif [ -x "$APP_DIR/venv/bin/python" ]; then
  PYTHON_BIN="$APP_DIR/venv/bin/python"
  ok "Using venv at venv"
else
  PYTHON_BIN="$(command -v python3)"
  warn "No .venv/venv found — falling back to system Python ($PYTHON_BIN)"
  warn "(your last error trace showed dist-packages, which matches this — that's fine as"
  warn " long as Flask/SQLAlchemy/Flask-Migrate are actually installed for this interpreter)"
fi

if ! "$PYTHON_BIN" -c "import flask_migrate" 2>/dev/null; then
  fail "Flask-Migrate isn't importable with $PYTHON_BIN."
  echo "    Install dependencies first, e.g.:"
  echo "      $PYTHON_BIN -m pip install -r requirements.txt"
  exit 1
fi
ok "Flask-Migrate is importable"

export FLASK_APP="${FLASK_APP:-run.py}"

bold "== 3. Checking configuration =="
if [ -f ".env" ]; then
  ok ".env found"
  if grep -q "^DATABASE_URL=.\+" .env; then
    DB_LINE=$(grep "^DATABASE_URL=" .env)
    warn "DATABASE_URL is set: $DB_LINE"
    warn "Migrations will run against THIS database, not the default SQLite file."
    warn "If that's a Postgres instance, make sure it's reachable right now."
  else
    ok "DATABASE_URL not set in .env — using the default SQLite file under instance/"
  fi
else
  warn "No .env file found — using defaults from config.py (SQLite under instance/)"
fi

mkdir -p instance

bold "== 4. Running migrations =="
if "$PYTHON_BIN" -m flask db upgrade; then
  ok "flask db upgrade completed"
else
  fail "flask db upgrade failed — see the error above."
  echo "    Common causes:"
  echo "      - DATABASE_URL points at a database that isn't reachable (check host/creds)"
  echo "      - The DB user lacks CREATE TABLE permission"
  echo "      - A previous partial migration left things in a broken state"
  echo "        (for SQLite only, and only if you're OK losing existing data, you can"
  echo "         delete instance/*.db and re-run this script for a clean slate)"
  exit 1
fi

bold "== 5. Verifying the fix =="
VERIFY=$("$PYTHON_BIN" - <<'PYEOF'
import sys
try:
    from run import app
    from app import db
    from sqlalchemy import inspect
    with app.app_context():
        tables = inspect(db.engine).get_table_names()
    if "users" in tables:
        print("OK:" + ",".join(sorted(tables)))
    else:
        print("MISSING:" + ",".join(sorted(tables)))
except Exception as e:
    print("ERROR:" + str(e))
    sys.exit(1)
PYEOF
)

if [[ "$VERIFY" == OK:* ]]; then
  ok "users table exists. All tables: ${VERIFY#OK:}"
else
  fail "users table still missing after migration. ${VERIFY}"
  echo "    This points at a mismatch between the DB the app connects to at runtime"
  echo "    and the DB this script just migrated — double check DATABASE_URL / FLASK_ENV"
  echo "    are identical in both contexts (e.g. systemd service EnvironmentFile vs your shell)."
  exit 1
fi

bold "== 6. Admin account =="
HAS_ADMIN=$("$PYTHON_BIN" - <<'PYEOF'
from run import app
from app.models.user import User
with app.app_context():
    print(User.query.count())
PYEOF
)
if [ "$HAS_ADMIN" = "0" ]; then
  warn "No admin user exists yet. Create one now with:"
  echo "      cd $APP_DIR && FLASK_APP=run.py $PYTHON_BIN -m flask create-admin"
  echo "    (this needs an interactive terminal for the password prompt, so it's not automated here)"
else
  ok "$HAS_ADMIN admin user(s) already exist — no action needed"
fi

bold "== 7. Restarting the app =="
if command -v systemctl >/dev/null && systemctl list-units --full -all | grep -q "${SERVICE_NAME}.service"; then
  if systemctl restart "$SERVICE_NAME"; then
    ok "Restarted systemd service '$SERVICE_NAME'"
  else
    fail "Found the service but restart failed — restart it manually and check its logs:"
    echo "      sudo systemctl status $SERVICE_NAME"
    echo "      sudo journalctl -u $SERVICE_NAME -n 50"
  fi
else
  warn "No systemd service named '$SERVICE_NAME' found."
  warn "If you run this with gunicorn/flask run manually, restart that process now."
  warn "(Override the service name with: SERVICE_NAME=your-service-name ./fix_db.sh)"
fi

echo
bold "Done. If you still see the error in your browser, hard-refresh and clear cookies for"
echo "the site — a stale session cookie referencing a user id from before the fix can also"
echo "trigger this same error message on the very next request."
