#!/usr/bin/env bash
# Fully fixes the SnailyCAD Migration Platform database.
# Handles: missing migrations/ folder, missing tables, stale/empty db.sqlite,
# wrong CWD, missing instance dir. Safe to re-run.
#
# Usage: ./fix_db.sh          (run from anywhere, place this file in project root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "== Working in: $SCRIPT_DIR"

# --- venv ---------------------------------------------------------------
if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
    echo "== venv activated"
elif [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
    echo "== .venv activated"
else
    echo "!! No venv found (venv/ or .venv/) — using system python3."
fi

export FLASK_APP=run.py
export FLASK_ENV="${FLASK_ENV:-development}"

# --- keep dependencies in sync with requirements.txt --------------------
if [ -f "requirements.txt" ]; then
    echo "== Syncing dependencies (pip install -r requirements.txt)..."
    pip install -q -r requirements.txt
fi
flask check-deps || true

mkdir -p instance
echo "== instance/ directory ready"

# --- figure out the real sqlite path the app will use --------------------
DB_PATH="$(python3 -c "
import sys; sys.path.insert(0, '.')
from app.config import Config
uri = Config.SQLALCHEMY_DATABASE_URI
if uri.startswith('sqlite:///'):
    print(uri[len('sqlite:///'):])
else:
    print('')
")"

if [ -n "$DB_PATH" ]; then
    echo "== Resolved sqlite path: $DB_PATH"
else
    echo "== Non-sqlite DATABASE_URL detected — skipping sqlite-specific checks."
fi

# --- migrations folder ----------------------------------------------------
if [ ! -d "migrations" ]; then
    echo "== No migrations/ folder — initializing Alembic."
    flask db init
fi

# If migrations/ exists but has no version files, generate an initial one.
if [ -z "$(ls -A migrations/versions 2>/dev/null)" ]; then
    echo "== No migration versions found — generating initial migration."
    flask db migrate -m "initial schema" || true
fi

echo "== Running flask db upgrade..."
if ! flask db upgrade; then
    echo "!! flask db upgrade failed — falling back to db.create_all()."
    python3 -c "
import sys; sys.path.insert(0, '.')
from app import create_app
from app.extensions import db
app = create_app()
with app.app_context():
    db.create_all()
print('== db.create_all() fallback complete.')
"
fi

# --- verify the users table actually exists now --------------------------
echo "== Verifying schema..."
python3 -c "
import sys; sys.path.insert(0, '.')
from app import create_app
from app.extensions import db
from sqlalchemy import inspect

app = create_app()
with app.app_context():
    inspector = inspect(db.engine)
    tables = inspector.get_table_names()
    required = {'users', 'exports', 'import_jobs', 'audit_logs', 'settings'}
    missing = required - set(tables)
    if missing:
        print(f'!! Still missing tables: {missing}')
        print('== Forcing db.create_all() as a last resort.')
        db.create_all()
        tables = inspect(db.engine).get_table_names()
        missing = required - set(tables)
        if missing:
            raise SystemExit(f'FAILED — tables still missing after create_all(): {missing}')
    print(f'== OK — tables present: {sorted(tables)}')
"

echo ""
echo "== DB fix complete."
echo "== If you don't have an admin yet, run: flask create-admin"
