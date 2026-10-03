#!/bin/bash
# Full (re)install + restart for the platform.
# Run this from the project root (the folder containing run.py).
# Safe to re-run any time — it restarts the server cleanly rather than
# trying to hot-reload modules into a process that's already served a
# request (Flask doesn't support that; see loader.py's docstring).

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo "==> Project dir: $PROJECT_DIR"

# ---- 1. Activate venv ----
if [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
    echo "==> Activated .venv"
elif [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
    echo "==> Activated venv"
else
    echo "!! No .venv or venv found — continuing with system python. If this is wrong, ctrl-C and activate your venv first."
fi

# ---- 2. Stop any currently-running instance of this app ----
echo "==> Stopping any running instance..."

# Kill anything running run.py from this project
pkill -f "$PROJECT_DIR/run.py" 2>/dev/null && echo "   killed run.py process(es)" || echo "   no run.py process found"

# Kill anything bound to port 5000 (adjust PORT below if you use a different one)
PORT="${PORT:-5000}"
if command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" 2>/dev/null && echo "   freed port $PORT" || true
fi

# If you're running this under systemd instead, uncomment and set your unit name:
# sudo systemctl stop your-app.service

sleep 1

# ---- 3. Install/update dependencies ----
echo "==> Installing dependencies..."
pip install -r requirements.txt --quiet
echo "   done"

# ---- 4. Clear stale bytecode (avoids importing old .pyc after code changes) ----
echo "==> Clearing __pycache__..."
find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find . -name "*.pyc" -delete 2>/dev/null || true

# ---- 5. Database + module setup ----
export FLASK_APP=run.py

echo "==> Running flask init-db (safe — creates missing tables only, never drops data)..."
flask init-db

echo "==> Running flask seed-nav..."
flask seed-nav

echo "==> Running flask install-builtin-modules..."
flask install-builtin-modules

# ---- 6. Start the server fresh ----
echo "==> Starting server..."
mkdir -p logs
nohup python run.py > logs/server.out.log 2>&1 &
SERVER_PID=$!
disown 2>/dev/null || true

sleep 3

if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "==> Server started (PID $SERVER_PID). Logs: $PROJECT_DIR/logs/server.out.log"
else
    echo "!! Server did not stay running. Check logs/server.out.log:"
    tail -n 40 logs/server.out.log
    exit 1
fi

# ---- 7. Quick smoke check ----
echo "==> Checking http://localhost:${PORT}/signup ..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/signup" || echo "000")
if [ "$CODE" = "200" ]; then
    echo "==> OK: signup page responded 200."
else
    echo "!! signup page responded $CODE — check logs/server.out.log and logs/app.log"
fi

echo ""
echo "Done. Visit /modules/ in the app to confirm checklist, finance, merchant, and fuel all show 'enabled'."
echo "If you're actually running this behind gunicorn/systemd in production, this script started the dev"
echo "server (python run.py) as a foreground-safe background process — replace step 6 with your normal"
echo "'systemctl restart your-app' instead if that's how you deploy."
