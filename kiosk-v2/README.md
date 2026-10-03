# StockTool Kiosk (v2) — Part 1: Desktop App Skeleton

A standalone, offline-first kiosk app: Items, Tools, Projects, and
barcode scan/lookup — no admin features. Ships as a single Windows
`.exe` with an embedded local SQLite database. No installer, no admin
rights, no separate runtime.

## What's actually verified working (not just written)

Everything below was run and tested in a real sandbox before delivery:

- Full API test suite: login (badge + username), items list/search/adjust,
  tools list/checkout/checkin, projects list, barcode lookup + permission-
  gated registration (403 for `stock_user`, 201 for `admin`), status
  endpoint, and the 401 rejection of unauthenticated requests.
- The exact entry point (`main.py`) that gets bundled into the `.exe`
  was run directly and confirmed to start the server and serve the UI.
- **The watchdog's crash-recovery was proven, not assumed** — a test
  harness made the server crash on its first start, and confirmed the
  supervisor detected the dead thread and restarted it automatically. It
  was even stress-tested against a *second*, unrelated failure mode (a
  transient port conflict from another process) and still recovered.
- **PyInstaller packaging was run for real** against this exact codebase
  (producing a Linux binary here, since this sandbox is Linux — see
  below for why the real `.exe` needs a Windows build machine). The
  frozen binary was then run standalone, with no Python or venv on the
  PATH, and confirmed to self-initialize its local database from
  scratch and serve the full UI correctly.

## What's NOT in Part 1 (coming in later parts)

- Cloud sync (push/pull, conflict resolution) — schema is ready
  (`dirty`, `server_id`, `updated_at` on every table) but not wired up.
- Auto-update / version checking.
- Camera-based barcode scanning (the UI accepts any typed/scanned string
  today — a USB keyboard-wedge scanner works right now with zero extra
  code, since it just types into the input field; camera decoding is a
  frontend-only addition for a later part).
- System tray icon / fully chromeless window (current UI opens in the
  default browser — functional, but not a "native app" look yet).
- Windows Service auto-start-on-boot (deferred on purpose — the watchdog
  is what makes a plain user-run `.exe` crash-resilient without needing
  admin rights for a service install; Service registration is an
  additive *option* for later, not a requirement to be stable now).

## Local dev setup (Linux/Mac/WSL)

```bash
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
./venv/bin/python seed_dev_data.py   # optional: adds sample items/tools/projects/users
./venv/bin/python main.py
```

Then open http://127.0.0.1:8420/ui/ — or it opens automatically.

Demo logins (from `seed_dev_data.py`): badge code `ADMIN0001` (admin) or
`BOB000001` (stock_user), or just type the username `admin` / `floor_bob`.

## Building the real Windows `.exe`

PyInstaller does not cross-compile — it must run on the OS you're
targeting. On a Windows machine (or a Windows GitHub Actions runner):

```powershell
python -m venv venv
venv\Scripts\pip install -r requirements.txt
venv\Scripts\pyinstaller build.spec
```

Output: `dist\StockToolKiosk.exe` — a single file. Copy it anywhere and
run it; no installer needed. First run creates
`%LOCALAPPDATA%\StockToolKiosk\kiosk_local.db` automatically.

### Suggested CI (GitHub Actions, Windows runner) for later parts

```yaml
runs-on: windows-latest
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-python@v5
    with: { python-version: '3.12' }
  - run: pip install -r requirements.txt
  - run: pyinstaller build.spec
  - uses: actions/upload-artifact@v4
    with: { name: StockToolKiosk, path: dist/StockToolKiosk.exe }
```

## Project layout

```
kiosk-v2/
  main.py              entry point (what the .exe runs)
  watchdog.py           crash-resilience supervisor
  build.spec             PyInstaller packaging config
  requirements.txt
  seed_dev_data.py       dev-only sample data (not shipped)
  app/
    __init__.py          Flask app factory, local SQLite config
    models.py             Item, Tool, Project, Barcode, LocalUser, SyncLog
    auth.py                local session store + permission decorator
    routes_items.py        GET /api/items, POST /api/items/<id>/adjust
    routes_tools.py         GET /api/tools, checkout/checkin
    routes_projects.py       GET /api/projects (read-only, admin-managed)
    routes_barcode.py         POST /api/barcode/lookup, /register
    routes_auth.py             POST /api/auth/login, GET /api/auth/me
    routes_status.py            GET /api/status, /api/status/sync-log
    ui.py                        serves the single-page UI
    templates/index.html          the UI itself
```

## API quick reference (Part 1 surface — full OpenAPI docs land in Part 5)

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/status` | none | health check + row counts |
| POST | `/api/auth/login` | none | `{badge_code}` or `{username}` → token |
| GET | `/api/auth/me` | bearer | who am I |
| GET | `/api/items?q=` | none | search by name/SKU |
| POST | `/api/items/<id>/adjust` | none | `{delta: int}` |
| GET | `/api/tools` | none | optional `?status=` |
| POST | `/api/tools/<id>/checkout` | none | `{checked_out_by_name}` |
| POST | `/api/tools/<id>/checkin` | none | |
| GET | `/api/projects` | none | active projects only |
| POST | `/api/barcode/lookup` | none | `{code}` → entity |
| POST | `/api/barcode/register` | bearer, role admin/supervisor | `{code, entity_type, entity_id}` |

(Local-API auth is intentionally light — this API only ever binds to
`127.0.0.1`, nothing here is exposed to the network. The bearer-token
gate is for the barcode-registration permission check, not perimeter
security. Perimeter security is the outbound-only cloud sync connection,
covered in Part 3.)
