#!/usr/bin/env bash
# Removes the "Settings" sidebar link (which points at the unregistered
# settings.appearance endpoint) from base.html and restarts the panel
# service. Run as root on the VPS.
#
# Usage:
#   bash fix-settings-link.sh
#
# Safe to re-run: if the block was already removed, it does nothing.

set -euo pipefail

APP_DIR="/root/server-panel"
BASE_HTML="$APP_DIR/templates/base.html"
SERVICE_NAME="SERVERPANEL.service"

if [ ! -f "$BASE_HTML" ]; then
  echo "ERROR: $BASE_HTML not found. Edit APP_DIR in this script if your app lives elsewhere." >&2
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BASE_HTML.bak-$TIMESTAMP"
cp "$BASE_HTML" "$BACKUP"
echo "Backed up base.html -> $BACKUP"

python3 - "$BASE_HTML" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# Matches the <a> tag for the Settings link, from '<a class="nav-link
# {{ 'active' if request.blueprint == 'settings' }}"' through its closing </a>.
pattern = re.compile(
    r'[ \t]*<a class="nav-link \{\{ \'active\' if request\.blueprint == \'settings\' \}\}".*?</a>\n',
    re.DOTALL,
)

new_content, count = pattern.subn("", content)

if count == 0:
    print("No Settings link block found — nothing to remove (already clean, or file differs from expected).")
else:
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"Removed {count} Settings link block(s) from {path}")
PYEOF

echo "Restarting $SERVICE_NAME ..."
systemctl restart "$SERVICE_NAME"
sleep 2
systemctl --no-pager status "$SERVICE_NAME" | head -n 10

echo
echo "Done. If the panel is still failing, check: journalctl -u $SERVICE_NAME -n 50 --no-pager"
echo "To undo this change: cp $BACKUP $BASE_HTML && systemctl restart $SERVICE_NAME"
