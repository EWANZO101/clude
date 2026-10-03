#!/usr/bin/env bash
# Directly patches the known-broken line in reviews/index.html on the
# live server, in place, with no dependency on which zip you've got
# lying around locally. This sidesteps the "which version actually
# got copied" problem entirely.
#
# Usage:
#   APP_ROOT=/root/opslabs SERVICE_NAME=opslab-web ./patch-reviews-stars.sh

set -uo pipefail
APP_ROOT="${APP_ROOT:-/root/opslabs}"
SERVICE_NAME="${SERVICE_NAME:-opslab-web}"
FILE="$APP_ROOT/app/templates/reviews/index.html"
STAMP="$(date +%Y%m%d-%H%M%S)"

log()  { echo "[patch] $*"; }
fail() { echo "[patch] ERROR: $*" >&2; exit 1; }

[ -f "$FILE" ] || fail "File not found: $FILE"

log "Current content around the bug:"
grep -n "r\.stars\|avg" "$FILE" || true
echo

# ---------- Backup ----------
BACKUP="$FILE.bak-$STAMP"
cp -p "$FILE" "$BACKUP"
log "Backed up to $BACKUP"

# ---------- Patch 1: the star-row loop that crashes on string data ----------
if grep -q "i < r.stars" "$FILE"; then
  python3 - "$FILE" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()

old_block = '''        <div class="text-yellow-400 text-lg mb-3 leading-none">
          {% for i in range(5) %}{{ '★' if i < r.stars else '☆' }}{% endfor %}
        </div>'''
new_block = '''        <div class="text-yellow-400 text-lg mb-3 leading-none">{{ r.stars }}</div>'''

if old_block in src:
    src = src.replace(old_block, new_block)
    print("  Patched star-row block (exact match).")
else:
    # Fallback: regex-based patch in case whitespace differs slightly
    pattern = re.compile(
        r'<div class="text-yellow-400 text-lg mb-3 leading-none">\s*'
        r"\{% for i in range\(5\) %\}\{\{ '★' if i < r\.stars else '☆' \}\}\{% endfor %\}\s*"
        r'</div>',
        re.DOTALL,
    )
    src, n = pattern.subn('<div class="text-yellow-400 text-lg mb-3 leading-none">{{ r.stars }}</div>', src)
    if n:
        print(f"  Patched star-row block (regex match, {n} occurrence(s)).")
    else:
        print("  WARNING: could not find the expected block to patch — manual review needed.")
        sys.exit(1)

open(path, "w", encoding="utf-8").write(src)
PYEOF
  PATCH1_STATUS=$?
  [ "$PATCH1_STATUS" -eq 0 ] || fail "Python patch step failed — file left as backed-up original, nothing broken further."
else
  log "Star-row bug not found verbatim — either already fixed, or wording differs. Skipping patch 1."
fi

# ---------- Patch 2: defensively cast avg in case it's ever a string too ----------
if grep -q "i < avg|round" "$FILE"; then
  sed -i \
    -e "s/{% for i in range(5) %}{{ '★' if i < avg|round(0, 'floor')|int else '☆' }}{% endfor %}/{% set avg_i = (avg|float(0))|round(0, 'floor')|int %}{% for i in range(5) %}{{ '★' if i < avg_i else '☆' }}{% endfor %}/" \
    "$FILE"
  log "Patched avg star-row to cast to float defensively."
fi
if grep -q "format(avg)" "$FILE"; then
  sed -i "s/'%.1f'|format(avg)/'%.1f'|format(avg|float(0))/" "$FILE"
  log "Patched avg display to cast to float defensively."
fi

echo
log "After patch:"
grep -n "r\.stars\|avg" "$FILE"

# ---------- Validate Jinja syntax ----------
if python3 -c "import jinja2" >/dev/null 2>&1; then
  python3 - "$FILE" <<'PYEOF'
import sys
from jinja2 import Environment
path = sys.argv[1]
try:
    Environment().parse(open(path, encoding="utf-8").read())
    print("  Jinja syntax OK.")
except Exception as e:
    print(f"  JINJA SYNTAX ERROR: {e}")
    sys.exit(1)
PYEOF
  if [ $? -ne 0 ]; then
    log "Syntax check failed — restoring backup."
    cp -p "$BACKUP" "$FILE"
    fail "Restored original file from backup. No changes applied."
  fi
else
  log "jinja2 not importable here — skipping syntax validation (deploy.sh's preflight will still check .py files, but not this template)."
fi

# ---------- Restart and verify ----------
find "$APP_ROOT" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null
log "Restarting $SERVICE_NAME..."
sudo systemctl restart "$SERVICE_NAME" || fail "systemctl restart failed"
sleep 3

HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:5000/api/v1/health}"
BASE_URL="$(echo "$HEALTH_URL" | sed -E 's#/api/v1/health$##')"
CODE="$(curl -s -o /tmp/reviews_check.html -w '%{http_code}' -m 10 "$BASE_URL/reviews/" 2>/dev/null || echo 000)"
if [ "$CODE" = "200" ]; then
  log "SUCCESS: /reviews/ now returns 200."
elif [ "$CODE" = "000" ]; then
  log "Could not reach $BASE_URL/reviews/ — check the service is up: sudo systemctl status $SERVICE_NAME"
else
  log "*** /reviews/ returned HTTP $CODE. Response saved to /tmp/reviews_check.html."
  if grep -qi "TypeError\|Traceback" /tmp/reviews_check.html 2>/dev/null; then
    log "*** Still erroring — this points to a DIFFERENT process serving requests"
    log "*** than the one we just restarted (check: ps aux | grep gunicorn, or"
    log "*** multiple systemd units, or a reverse-proxy cache in front of this)."
  fi
fi

log ""
log "Backup of the pre-patch file kept at: $BACKUP"