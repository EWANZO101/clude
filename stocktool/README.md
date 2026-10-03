# StockTool Kiosk

Shared-device, badge-scan-to-login companion to **stocktool-admin**. Runs as
its own Flask process, but shares the same SQLite database file directly —
no HTTP call to stocktool-admin happens for normal operation.

## How the "shared DB" wiring works

`config.py` adds `ADMIN_APP_PATH` (default: `../stocktool`, i.e. a sibling
directory) to `sys.path`, and `kiosk/__init__.py` then does:

```python
from app.extensions import db
```

— importing stocktool-admin's actual `db` object and, through it, its
actual model classes (`User`, `Item`, `Barcode`, ...). There is no second
set of model definitions to keep in sync by hand: if stocktool-admin's
schema changes, the kiosk picks it up automatically the next time it
restarts, because it's importing the same code, not a copy of it.

`SQLALCHEMY_DATABASE_URI` defaults to stocktool-admin's own default DB path
(`<ADMIN_APP_PATH>/instance/stocktool.db`) so both apps point at the exact
same file with zero extra configuration in the common case (deployed side
by side on the same VPS). Override `DATABASE_URL` if that's ever not true.

**Two separate OS processes writing to one SQLite file**: stocktool-admin's
`app/extensions.py` sets `PRAGMA journal_mode=WAL` and a busy timeout on
every connection in this codebase, which the kiosk inherits automatically
since it imports that exact file. Make sure stocktool-admin is upgraded to
the Phase 0 version (or later) before running the kiosk — that's where this
pragma was added.

## Deploying alongside stocktool-admin

```
/opt/stocktool/          ← stocktool-admin (must exist here, or set ADMIN_APP_PATH)
/opt/stocktool-kiosk/     ← this app
```

```bash
cd /opt/stocktool-kiosk
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Required
export SECRET_KEY="something-random"
export KIOSK_NAME="kiosk-1"          # shows up in the audit log's device column
export PORT=5050                     # stocktool-admin already uses 5000

# Only needed if not deployed as siblings under the layout above
# export ADMIN_APP_PATH=/opt/stocktool
# export DATABASE_URL=sqlite:////opt/stocktool/instance/stocktool.db

python run.py
```

No `init_db.py` step here — the kiosk never creates tables or the first
admin account; stocktool-admin already owns that. Just make sure
stocktool-admin has been migrated to Phase 0 (`python scripts/migrate_phase0.py`
in that codebase) so the `barcodes` table has the `user_id` column kiosk
badge-login depends on, and every user has a badge barcode.

## What's implemented (Phase 1)

- Idle screen ("Scan Your Badge") with an always-focused input that a
  USB/Bluetooth keyboard-wedge scanner types straight into, or that staff
  can type into manually as a fallback.
- Badge scan → dashboard showing "Welcome, {name}".
- Scanning a different badge while someone's logged in switches user
  instantly — no manual logout step.
- Scanning an item barcode from the dashboard opens a touch keypad to enter
  a quantity, then removes that much stock in one action
  (`POST /api/quick-remove`, which always subtracts — never adds).
- 60s inactivity (configurable via `IDLE_TIMEOUT_SECONDS`) auto-returns to
  the idle screen; any scan, tap, or keypress resets the timer, and it also
  restarts fresh right after a completed stock action.
- Scanning a tool or project barcode identifies it but doesn't offer an
  action yet (no kiosk-side checkout/checkin or project stock flow in this
  phase — everything for those still happens on the admin panel).

## Not yet implemented

- Phase 2 (mobile phone as a backup scanner, paired via QR code) — held
  back on purpose per your last message, build on top of this once Phase
  0/1 have been running for a bit.
- Phase 3 (filterable audit log reporting in the admin panel).
