#!/usr/bin/env bash
# Applies this update to an already-deployed Admin Panel: runs migrations,
# verifies the new installer files are actually present, and restarts the
# running service (systemd if you've set that up, otherwise tells you what
# to restart manually — this script doesn't guess at a process it can't see).
#
# Run this AFTER you've unzipped the new opslab-admin-panel zip over your
# existing /root/admin_panel (or wherever it lives) — this script does not
# fetch or unzip anything itself, it only applies/verifies what's already
# on disk.
#
# Usage (from inside the admin_panel directory):
#   ./update.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "==> Working in $HERE"

if [[ ! -d venv ]]; then
  echo "ERROR: no venv/ found here. Run this from inside your admin_panel directory"
  echo "       (the one containing run.py, config.py, app/)."
  exit 1
fi

echo "==> [1/5] Installing/updating Python dependencies..."
venv/bin/pip install --quiet -r requirements.txt

echo "==> [2/5] Running database migrations..."
if [[ ! -d migrations ]]; then
  echo "    No migrations/ yet — running first-time init."
  venv/bin/flask db init
  venv/bin/flask db migrate -m "initial schema"
else
  venv/bin/flask db migrate -m "sync schema" || echo "    (no schema changes detected — fine)"
fi
venv/bin/flask db upgrade

echo "==> [3/5] Verifying the installer files this update adds..."
MISSING=0
for f in app/static/installers/install.sh app/static/installers/install.ps1 app/static/installers/opslab-agent.tar.gz; do
  if [[ ! -s "$f" ]]; then
    echo "    MISSING or empty: $f"
    MISSING=1
  else
    echo "    OK: $f ($(du -h "$f" | cut -f1))"
  fi
done
if [[ $MISSING -eq 1 ]]; then
  echo ""
  echo "ERROR: one or more installer files are missing. Re-unzip the provided"
  echo "       opslab-admin-panel zip over this directory (it's not enough to"
  echo "       just run this script without the new files actually present)."
  exit 1
fi

echo "==> [4/5] Restarting the app..."
RESTARTED=0
# Try common service names — adjust SERVICE_NAME if yours differs.
for SERVICE_NAME in admin-panel admin_panel opslab-admin-panel; do
  if systemctl list-units --full -all 2>/dev/null | grep -q "${SERVICE_NAME}.service"; then
    systemctl restart "$SERVICE_NAME"
    echo "    Restarted systemd service: $SERVICE_NAME"
    RESTARTED=1
    break
  fi
done

if [[ $RESTARTED -eq 0 ]]; then
  echo "    No matching systemd service found — restart it however you're"
  echo "    currently running it (e.g. stop the existing 'python run.py' /"
  echo "    'flask run' process and start it again) before continuing."
fi

echo "==> [5/5] Verifying the new routes respond (once you've restarted)..."
BASE_URL="${1:-http://127.0.0.1:5000}"
echo "    Checking against $BASE_URL (pass a different URL as the first argument if needed)"
for path in /install.sh /install.ps1; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}${path}" 2>/dev/null)
  if [[ "$CODE" == "200" ]]; then
    echo "    OK  $path -> 200"
  else
    echo "    !!  $path -> ${CODE:-no response} (make sure the app has actually been restarted, then re-run: $0 $BASE_URL)"
  fi
done

echo ""
echo "Done. If both routes above show 200, the real curl|bash install command will now work."
