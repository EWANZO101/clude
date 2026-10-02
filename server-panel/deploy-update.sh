#!/usr/bin/env bash
# Deploys the opslab-panel-redesign update to /root/server-panel/, tries to
# register the settings blueprint in app.py automatically, and restarts the
# service. If anything looks broken afterwards, it rolls everything back on
# its own so the panel doesn't stay down.
#
# Usage (run as root, ON the VPS):
#   bash deploy-update.sh /path/to/opslab-panel-redesign.zip
#   bash deploy-update.sh /path/to/opslab-panel-redesign        # already-unzipped folder also works
#
# What it touches in /root/server-panel/:
#   static/css/style.css
#   static/js/theme.js
#   templates/base.html
#   templates/settings/appearance.html
#   settings.py
#   app.py               (only a small insert, see below — skipped if it can't do it safely)

set -uo pipefail

APP_DIR="/root/server-panel"
SERVICE_NAME="SERVERPANEL.service"
SRC_ARG="${1:-}"

if [ -z "$SRC_ARG" ]; then
  echo "Usage: bash $(basename "$0") /path/to/opslab-panel-redesign.zip" >&2
  exit 1
fi

if [ ! -e "$SRC_ARG" ]; then
  echo "ERROR: $SRC_ARG not found." >&2
  exit 1
fi

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: $APP_DIR not found. Edit APP_DIR in this script if your app lives elsewhere." >&2
  exit 1
fi

# --- resolve source directory (unzip if a .zip was given) -----------------
WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [[ "$SRC_ARG" == *.zip ]]; then
  echo "Unzipping $SRC_ARG ..."
  unzip -q -o "$SRC_ARG" -d "$WORKDIR"
  SRC="$WORKDIR"
else
  SRC="$SRC_ARG"
fi

# Handle a zip that contains one wrapper folder (e.g. opslab-panel-redesign/...)
if [ ! -f "$SRC/templates/base.html" ]; then
  INNER=$(find "$SRC" -maxdepth 2 -name base.html -path "*/templates/*" | head -n1)
  if [ -n "$INNER" ]; then
    SRC=$(dirname "$(dirname "$INNER")")
  fi
fi

if [ ! -f "$SRC/templates/base.html" ]; then
  echo "ERROR: couldn't find templates/base.html inside $SRC_ARG — is this the right file?" >&2
  exit 1
fi

echo "Using update source: $SRC"

# --- backup everything we're about to touch --------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/server-panel-backups/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

for f in \
  "templates/base.html" \
  "templates/settings/appearance.html" \
  "static/css/style.css" \
  "static/js/theme.js" \
  "settings.py" \
  "app.py"
do
  if [ -f "$APP_DIR/$f" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp "$APP_DIR/$f" "$BACKUP_DIR/$f"
  fi
done
echo "Backed up current files -> $BACKUP_DIR"

restore_backup() {
  echo "Rolling back to $BACKUP_DIR ..."
  for f in \
    "templates/base.html" \
    "templates/settings/appearance.html" \
    "static/css/style.css" \
    "static/js/theme.js" \
    "settings.py" \
    "app.py"
  do
    if [ -f "$BACKUP_DIR/$f" ]; then
      cp "$BACKUP_DIR/$f" "$APP_DIR/$f"
    fi
  done
  systemctl restart "$SERVICE_NAME"
  echo "Rolled back and restarted $SERVICE_NAME. Panel should be back to its previous working state."
}

# --- copy in the new files --------------------------------------------------
mkdir -p "$APP_DIR/templates/settings" "$APP_DIR/static/js" "$APP_DIR/static/css"
cp "$SRC/templates/base.html" "$APP_DIR/templates/base.html"
cp "$SRC/templates/settings/appearance.html" "$APP_DIR/templates/settings/appearance.html"
cp "$SRC/static/css/style.css" "$APP_DIR/static/css/style.css"
cp "$SRC/static/js/theme.js" "$APP_DIR/static/js/theme.js"
cp "$SRC/settings.py" "$APP_DIR/settings.py"
echo "Copied updated files into $APP_DIR"

# --- try to auto-register the settings blueprint in app.py -----------------
PATCHED=0
if grep -q "settings_bp" "$APP_DIR/app.py" 2>/dev/null; then
  echo "app.py already references settings_bp — leaving it alone."
else
  python3 - "$APP_DIR/app.py" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# Learn the existing pattern from another blueprint, e.g.:
#   from systemctl import systemctl_bp
#   app.register_blueprint(systemctl_bp)
import_match = re.search(r'^from (\w+) import (\w+_bp)\s*$', content, re.MULTILINE)
register_match = re.search(r'^(\s*)app\.register_blueprint\((\w+_bp)(.*?)\)\s*$', content, re.MULTILINE)

if not import_match or not register_match:
    print("PATCH_SKIPPED: couldn't find an existing 'from X import X_bp' / "
          "'app.register_blueprint(X_bp)' pattern to copy. Leaving app.py untouched.")
    sys.exit(0)

indent = register_match.group(1)

new_import = "from settings import settings_bp"
new_register = f"{indent}app.register_blueprint(settings_bp)"

# Insert the import right after the matched import line.
import_line_end = import_match.end()
content = content[:import_line_end] + "\n" + new_import + content[import_line_end:]

# Re-find register_match position in the updated content and insert after it.
register_match2 = re.search(r'^(\s*)app\.register_blueprint\((\w+_bp)(.*?)\)\s*$', content, re.MULTILINE)
register_line_end = register_match2.end()
content = content[:register_line_end] + "\n" + new_register + content[register_line_end:]

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("PATCH_APPLIED: inserted 'from settings import settings_bp' and "
      "'app.register_blueprint(settings_bp)' into app.py")
PYEOF
  PY_STATUS=$?
  if [ $PY_STATUS -ne 0 ]; then
    echo "ERROR: patch script failed unexpectedly. Rolling back." >&2
    restore_backup
    exit 1
  fi
  PATCHED=1
fi

# --- validate app.py syntax before ever restarting --------------------------
if ! python3 -m py_compile "$APP_DIR/app.py"; then
  echo "ERROR: app.py failed to compile after patching. Rolling back." >&2
  restore_backup
  exit 1
fi

# --- restart and verify -----------------------------------------------------
echo "Restarting $SERVICE_NAME ..."
systemctl restart "$SERVICE_NAME"
sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "ERROR: $SERVICE_NAME is not active after restart. Rolling back." >&2
  restore_backup
  exit 1
fi

# Look for a fresh traceback in the last few seconds of logs.
if journalctl -u "$SERVICE_NAME" --since "10 seconds ago" --no-pager 2>/dev/null | grep -q "Traceback\|BuildError"; then
  echo "ERROR: errors found in the service log right after restart. Rolling back." >&2
  journalctl -u "$SERVICE_NAME" --since "10 seconds ago" --no-pager | tail -n 20
  restore_backup
  exit 1
fi

echo
echo "Deployed successfully."
if [ "$PATCHED" -eq 1 ]; then
  echo "app.py was auto-patched to register the settings blueprint."
else
  if ! grep -q "settings_bp" "$APP_DIR/app.py" 2>/dev/null; then
    echo "NOTE: app.py could NOT be auto-patched (no matching blueprint pattern found)."
    echo "Add these two lines yourself, near your other blueprints, then restart:"
    echo "    from settings import settings_bp"
    echo "    app.register_blueprint(settings_bp)"
  fi
fi
echo "Backup of previous files: $BACKUP_DIR"
echo "Manual rollback if needed later:"
echo "  cp -r $BACKUP_DIR/* $APP_DIR/ && systemctl restart $SERVICE_NAME"
