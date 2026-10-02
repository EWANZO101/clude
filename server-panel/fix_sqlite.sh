#!/bin/bash

set -e

APP_DIR="/root/server-panel"

echo "== Server Panel SQLite Repair =="

cd "$APP_DIR" || {
    echo "ERROR: Cannot find $APP_DIR"
    exit 1
}

echo "[1/5] Creating common Flask folders..."
mkdir -p instance
mkdir -p data
mkdir -p database

echo "[2/5] Fixing permissions..."
chown -R root:root "$APP_DIR"
chmod -R 755 "$APP_DIR"

# Make SQLite writable locations
chmod 777 instance data database 2>/dev/null || true

echo "[3/5] Searching for SQLite database files..."

find "$APP_DIR" -name "*.db" -o -name "*.sqlite" | while read DB
do
    echo "Fixing: $DB"
    touch "$DB"
    chown root:root "$DB"
    chmod 666 "$DB"
done

echo "[4/5] Checking Python environment..."

if [ -d "venv" ]; then
    echo "Virtual environment found."
else
    echo "WARNING: venv not found."
fi

echo "[5/5] Testing SQLite write..."

python3 - <<'PY'
import sqlite3

try:
    db = sqlite3.connect("instance/test_fix.db")
    db.execute("CREATE TABLE IF NOT EXISTS repair_test(id INTEGER)")
    db.close()
    print("SQLite OK")
except Exception as e:
    print("SQLite FAILED:", e)
    exit(1)
PY

rm -f instance/test_fix.db

echo ""
echo "Repair completed."
echo "Try starting the app:"
echo ""
echo "source venv/bin/activate"
echo "python app.py"
