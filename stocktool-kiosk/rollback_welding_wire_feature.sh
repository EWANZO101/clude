#!/usr/bin/env bash
#
# rollback_welding_wire_feature.sh -- fully reverts the Welding Wire
# feature (all 3 deploys: base feature, custom fields, bulk add) back
# to the original pristine code, using the backups each deploy script
# made of itself before writing anything.
#
# What this restores (from .welding_wire_deploy_backup_* -- the FIRST
# deploy's backup, since that's the one holding the pre-feature
# originals):
#   app/admin_models.py
#   app/routes_admin_panel.py
#   app/codes.py
#   app/templates/admin_panel.html
#
# What this removes:
#   app/templates/welding_wire_print.html (didn't exist before the
#   feature -- no backup has it because there was nothing to back up)
#
# What this does NOT touch:
#   Any welding_wire_batches rows / generated barcodes already created
#   through the feature. That's real data -- this script only reverts
#   CODE, it doesn't delete data. It disables the "Welding Wire"
#   sidebar entry (not deletes it) so the page just won't render once
#   the JS that built it is gone, but the underlying batches/barcodes
#   stay in the database untouched. See the end of this script's
#   output for how to fully purge that data too, if you actually want
#   that as a separate, deliberate step.
#
# Usage (run from inside ~/stocktool-kiosk, or pass the path):
#   ./rollback_welding_wire_feature.sh
#   ./rollback_welding_wire_feature.sh /root/stocktool-kiosk

set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"
cd "$TARGET_DIR"

# The FIRST deploy's backup dir is the one with pre-feature originals.
# Its name is exactly ".welding_wire_deploy_backup_<timestamp>" -- the
# _cf_ and _bulk_ variants from the later two deploys are deliberately
# a different prefix so this glob can't accidentally match them.
BACKUP_DIR=$(ls -d .welding_wire_deploy_backup_* 2>/dev/null | sort | head -n1 || true)

if [[ -z "$BACKUP_DIR" ]]; then
  echo "Couldn't find a .welding_wire_deploy_backup_* directory in $TARGET_DIR." >&2
  echo "That's the backup the FIRST welding-wire deploy script made -- without it" >&2
  echo "there's nothing to restore from. Check you're in the right directory." >&2
  exit 1
fi

echo "Restoring from $BACKUP_DIR ..."

for rel in app/admin_models.py app/routes_admin_panel.py app/codes.py app/templates/admin_panel.html; do
  if [[ -f "$BACKUP_DIR/$rel" ]]; then
    cp "$BACKUP_DIR/$rel" "$rel"
    echo "Restored $rel"
  else
    echo "WARNING: $BACKUP_DIR/$rel not found -- left $rel as-is." >&2
  fi
done

if [[ -f app/templates/welding_wire_print.html ]]; then
  rm app/templates/welding_wire_print.html
  echo "Removed app/templates/welding_wire_print.html (new file, no backup needed)"
fi

# Disable (not delete) the "welding-wire" sidebar entry in the DB, so
# it stops showing once the JS/routes that power it are gone. Real
# batch/barcode data is left completely alone.
VENV_PY="$TARGET_DIR/venv/bin/python3"
if [[ ! -x "$VENV_PY" ]]; then VENV_PY="python3"; fi

"$VENV_PY" - <<'PYEOF'
import sys
sys.path.insert(0, ".")
try:
    from app import create_app
    app = create_app()
    with app.app_context():
        from app.models import db
        from app.admin_models import AdminPage
        page = AdminPage.query.filter_by(key="welding-wire").first()
        if page and page.is_enabled:
            page.is_enabled = False
            db.session.commit()
            print("Disabled the 'welding-wire' sidebar entry (data untouched).")
        elif page:
            print("'welding-wire' sidebar entry was already disabled.")
        else:
            print("No 'welding-wire' sidebar entry found in the DB -- nothing to disable.")
except Exception as e:
    print(f"Couldn't reach the DB to disable the sidebar entry (non-fatal): {e}")
PYEOF

echo "Wrote all files."

PID=$(pgrep -f "python3 .*main\.py --service" | head -n1 || true)
if [[ -n "$PID" ]]; then
  echo "Found running kiosk process (PID $PID). Restarting it..."
  kill "$PID"
  sleep 2
  ( cd "$TARGET_DIR" && nohup "$VENV_PY" main.py --service > service.log 2>&1 & )
  sleep 3
  echo "Restarted. Checking /api/status ..."
  curl -sS http://127.0.0.1:8420/api/status && echo "" || echo "Couldn't reach /api/status -- check service.log"
else
  echo "No running 'main.py --service' process found -- start the app yourself so this takes effect."
fi

echo ""
echo "Done. Code is back to pre-welding-wire. The sidebar entry is disabled."
echo ""
echo "Any real welding_wire_batches / barcodes you created are still in the"
echo "database, just no longer reachable through the UI. If you want those"
echo "fully deleted too, run this (separate, deliberate step -- not run"
echo "automatically by this script):"
echo ""
echo "  $VENV_PY - <<'PYEOF'"
echo "  import sys; sys.path.insert(0, '.')"
echo "  from app import create_app"
echo "  app = create_app()"
echo "  with app.app_context():"
echo "      from app.models import db, Barcode"
echo "      from app.admin_models import WeldingWireBatch, CustomFieldDef, AdminPage"
echo "      Barcode.query.filter_by(entity_type='welding_wire_batch').delete()"
echo "      WeldingWireBatch.query.delete()"
echo "      CustomFieldDef.query.filter_by(entity_type='wire').delete()"
echo "      AdminPage.query.filter_by(key='welding-wire').delete()"
echo "      db.session.commit()"
echo "      print('Welding wire data fully purged.')"
echo "  PYEOF"
