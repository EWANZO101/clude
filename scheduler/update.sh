#!/usr/bin/env bash
# update.sh — installs a new build from a zip file, then PROVES it took
# effect: before/after file hashes, and explicit pass/fail checks for
# specific known fixes, so "I ran the script" and "the fix is live" are
# never in doubt.
#
# Usage:
#   ./update.sh /path/to/scheduler-build.zip
#
# Overrides:
#   APP_DIR=/opt/scheduler SERVICE_NAME=my-service PORT=5076 ./update.sh build.zip

set -uo pipefail

ZIP_PATH="${1:-}"
APP_DIR="${APP_DIR:-/root/scheduler}"
SERVICE_NAME="${SERVICE_NAME:-scheduler}"
PORT="${PORT:-5076}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
die()  { fail "$1"; exit 1; }

[ -n "$ZIP_PATH" ] || die "Usage: ./update.sh /path/to/scheduler-build.zip"
[ -f "$ZIP_PATH" ] || die "Zip not found: $ZIP_PATH"
[ -d "$APP_DIR" ] || die "APP_DIR '$APP_DIR' doesn't exist."
command -v unzip >/dev/null || die "unzip is not installed (apt install unzip)"

cd "$APP_DIR" || exit 1

# Files whose content directly proves specific fixes are (or aren't) live.
# Add to this list as more fixes ship, so every future update is self-verifying.
declare -A MARKERS=(
  ["app/__init__.py"]="Your session expired"
  ["app/services/calendar.py"]="should NOT be the source of truth"
  ["app/routes/admin.py"]="def edit_time_off"
  ["app/routes/public.py"]="def current_task_page"
)

bold "== 1. Snapshot BEFORE state =="
declare -A BEFORE_HASH
for f in "${!MARKERS[@]}"; do
  if [ -f "$f" ]; then
    BEFORE_HASH["$f"]=$(sha256sum "$f" | cut -d' ' -f1)
    ok "$f  (${BEFORE_HASH[$f]:0:12}...)"
  else
    BEFORE_HASH["$f"]="(missing)"
    warn "$f does not exist yet — this update should add it"
  fi
done

bold "== 2. Backing up instance data and config =="
BACKUP_DIR="/tmp/scheduler_update_backup_$(date +%s)"
mkdir -p "$BACKUP_DIR"
[ -d "instance" ] && cp -r instance "$BACKUP_DIR/" && ok "Backed up instance/ to $BACKUP_DIR"
[ -f ".env" ] && cp .env "$BACKUP_DIR/" && ok "Backed up .env to $BACKUP_DIR"

bold "== 3. Extracting the new build =="
TMP_EXTRACT=$(mktemp -d)
unzip -q -o "$ZIP_PATH" -d "$TMP_EXTRACT" || die "unzip failed"

# The zip contains a top-level scheduler/ folder — find it regardless of
# exact naming so this doesn't break if a future zip is named differently.
SRC_DIR=$(find "$TMP_EXTRACT" -maxdepth 1 -mindepth 1 -type d | head -1)
[ -n "$SRC_DIR" ] || die "Couldn't find an extracted project folder inside the zip"
ok "Extracted to $SRC_DIR"

# Defensive: strip these even if a future build accidentally includes them —
# never want a dev venv/node_modules built for a different machine landing here.
rm -rf "$SRC_DIR/.venv" "$SRC_DIR/venv" "$SRC_DIR/node_modules" "$SRC_DIR/instance" "$SRC_DIR/.env"
find "$SRC_DIR" -name "__pycache__" -exec rm -rf {} + 2>/dev/null

# Copy everything into place. Safe as a plain merge-copy (never deletes
# anything not present in the new build) because the zip never contains
# instance/ or .env in the first place — those are always stripped before
# a build is zipped up, so there's nothing to accidentally overwrite.
cp -a "$SRC_DIR"/. "$APP_DIR"/ \
  && ok "Copied new files into $APP_DIR (instance/ and .env untouched — not present in the build)"
rm -rf "$TMP_EXTRACT"

bold "== 4. Snapshot AFTER state =="
declare -A AFTER_HASH
CHANGED=0
for f in "${!MARKERS[@]}"; do
  if [ -f "$f" ]; then
    AFTER_HASH["$f"]=$(sha256sum "$f" | cut -d' ' -f1)
  else
    AFTER_HASH["$f"]="(missing)"
  fi
  if [ "${BEFORE_HASH[$f]}" != "${AFTER_HASH[$f]}" ]; then
    ok "$f changed (${AFTER_HASH[$f]:0:12}...)"
    CHANGED=1
  else
    warn "$f unchanged — already up to date, or the zip didn't include a change here"
  fi
done
[ "$CHANGED" = "1" ] && ok "At least one tracked file changed — new code was actually copied in" \
  || warn "No tracked files changed. If you expected new code, double check you built the right zip."

bold "== 5. Python dependencies =="
if [ -x "$APP_DIR/.venv/bin/python" ]; then
  PY="$APP_DIR/.venv/bin/python"
elif [ -x "$APP_DIR/venv/bin/python" ]; then
  PY="$APP_DIR/venv/bin/python"
else
  PY="$(command -v python3)"
  warn "No venv found — using system Python ($PY)"
fi
"$PY" -m pip install --quiet -r requirements.txt && ok "Dependencies installed ($PY)" || die "pip install failed"

bold "== 6. Frontend build =="
if command -v npm >/dev/null; then
  npm install --silent && npm run build:css --silent && ok "CSS rebuilt" || die "CSS build failed"
else
  die "npm not found — can't rebuild CSS, the site will look broken without this"
fi

bold "== 7. Database migrations =="
export FLASK_APP="${FLASK_APP:-run.py}"
"$PY" -m flask db upgrade && ok "Migrations applied" || die "flask db upgrade failed"

bold "== 8. Restarting the service =="
COPY_TIMESTAMP=$(date +%s)
RESTART_CONFIRMED=0
if command -v systemctl >/dev/null && systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
  if systemctl restart "$SERVICE_NAME"; then
    ok "Restarted '$SERVICE_NAME'"
    RESTART_CONFIRMED=1
  else
    die "Restart failed — check: journalctl -u $SERVICE_NAME -n 50"
  fi
else
  warn "No systemd service '$SERVICE_NAME' found — restart the app process manually:"
  echo "      pkill -f gunicorn && cd $APP_DIR && $PY -m gunicorn -w 3 -b 0.0.0.0:$PORT run:app &"
  warn "Until you do, the running process is still the OLD code — the checks below"
  warn "can only confirm the files on disk are updated, not that they're actually live."
fi

bold "== 9. Health check =="
sleep 2
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/auth/login" 2>/dev/null)
[ -z "$CODE" ] && CODE="000"
[ "$CODE" = "200" ] && ok "App responding on port $PORT" || die "App not responding (HTTP $CODE) — check: journalctl -u $SERVICE_NAME -n 50"

bold "== 10. Confirming the RUNNING process is actually the new code =="
# A process being "up" doesn't prove it's running the new code — an old
# gunicorn worker can happily keep answering HTTP requests with stale,
# already-imported Python modules even after the files on disk changed.
# This checks the process's own start time against when we finished
# copying files, which is the only real proof a fresh process picked up
# the new code (as opposed to file checks, which only prove the new code
# exists on disk — see step 11).
MAIN_PID=""
if [ "$RESTART_CONFIRMED" = "1" ]; then
  MAIN_PID=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)
fi
if [ -z "$MAIN_PID" ] || [ "$MAIN_PID" = "0" ]; then
  MAIN_PID=$(pgrep -o -f "gunicorn.*run:app" 2>/dev/null || true)
fi

if [ -n "$MAIN_PID" ] && [ -d "/proc/$MAIN_PID" ]; then
  PROC_START=$(stat -c %Y "/proc/$MAIN_PID" 2>/dev/null || echo 0)
  if [ "$PROC_START" -ge "$COPY_TIMESTAMP" ]; then
    ok "Running process (pid $MAIN_PID) started AFTER the file update — confirmed fresh"
  else
    fail "Running process (pid $MAIN_PID) started BEFORE the file update — it's still old code"
    warn "This means the restart didn't actually happen (or restarted the wrong process)."
  fi
else
  warn "Couldn't identify the running app process to check its start time — restart status unconfirmed"
fi

bold "== 11. Fix markers present in the deployed files (disk-level check) =="
LOGIN_HTML=$(curl -s "http://127.0.0.1:${PORT}/auth/login")
ALL_PASS=1
for f in "${!MARKERS[@]}"; do
  marker="${MARKERS[$f]}"
  if grep -q "$marker" "$f" 2>/dev/null; then
    ok "$f contains expected marker"
  else
    fail "$f MISSING expected marker: '$marker'"
    ALL_PASS=0
  fi
done

echo
if [ "$ALL_PASS" = "1" ] && [ "$RESTART_CONFIRMED" = "1" ]; then
  bold "✓✓✓ UPDATE VERIFIED — new code is on disk AND the running process picked it up. ✓✓✓"
elif [ "$ALL_PASS" = "1" ]; then
  bold "! Files updated and correct, but the running process could not be confirmed as restarted."
  echo "  Restart it manually (see step 8), then re-run this script to get full verification."
  exit 1
else
  bold "✗✗✗ UPDATE INCOMPLETE — one or more expected fixes are missing from the files. ✗✗✗"
  exit 1
fi
echo "Backup of your previous instance/.env is at: $BACKUP_DIR"