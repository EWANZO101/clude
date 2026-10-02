# StockTool Kiosk (v2) — Part 6: Camera Barcode Scanning + MSI Installer

An offline-first kiosk app: Items, Tools, Projects, and barcode
scan/lookup, backed by an embedded local SQLite database.

Two ways to run it:

- **Standalone `.exe`** (Part 1-5 behavior, unchanged): copy
  `StockToolKiosk.exe` anywhere and run it — no installer, no admin
  rights, no separate runtime. Good for a single kiosk terminal.
- **`.msi` installer** (this update — see `installer/`): installs the
  same exe as a persistent, auto-starting Windows Service
  (`StockToolKioskAPI`), and runs a Setup Wizard that lets an admin
  choose how that service is reachable — local-only, via a Cloudflare
  Tunnel, or directly on the machine's public IP. This is the option
  to use when you want the admin API always running in the background
  (not just while a kiosk terminal has the exe open), and/or reachable
  from outside the machine. Building and installing the `.msi` does
  require admin rights, because it registers a Windows Service, a
  firewall rule (Public mode), and optionally the Cloudflared service
  (Tunnel mode).

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

## What Part 6 adds

- **Camera-based barcode/QR scanning** on the Scan tab, using the
  browser's native `BarcodeDetector` API — no external library, no CDN
  fetch, so it stays fully offline-capable. "Use Camera" button opens a
  live video preview; detected codes are debounced (2.5s) and piped
  through the exact same `/api/barcode/lookup` call the manual-typed
  and USB-scanner paths already use, so backend behavior is unchanged.
  Falls back to a plain message on browsers without `BarcodeDetector`
  support — USB and manual-type entry keep working either way. The
  camera is released automatically when leaving the Scan tab.
- **Fixed a broken entry point**: `main.py` imported from a
  `kiosk_supervisor` module that doesn't exist, and `watchdog.py` had
  been overwritten with a duplicate copy of `main.py`'s own content —
  so the `Supervisor` class it's supposed to define was missing
  entirely and the `.exe` could not start. Rewrote `watchdog.py` with
  the actual crash-recovery `Supervisor` (run the Flask app, catch any
  exception, log it, back off, and restart, giving up after 10
  consecutive failures) and fixed the import in `main.py`. Verified
  both the normal path (server starts, `/ui/` serves, camera-scan code
  present) and the crash-recovery path (forced a crash on first start,
  confirmed automatic restart and recovery) in a real sandbox run.

## What's NOT in Part 1 (coming in later parts)

- Cloud sync (push/pull, conflict resolution) — schema is ready
  (`dirty`, `server_id`, `updated_at` on every table), `sync_loop.py`
  exists, but nothing sets `app.config["SYNC_ENGINE"]` yet, so it
  currently runs offline-only (logged, not silent). A `SyncEngine`
  class needs to be built and wired into `create_app()` — that's a
  bigger piece than Part 6's scope, flagging it so it doesn't get
  missed rather than working around it.
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

## Building the `.msi` installer

Also Windows-only, and built on top of the `.exe` above. From
`installer\`:

```powershell
.\build.ps1
```

This runs PyInstaller, then WiX (`dotnet tool install --global wix` if
you don't have it yet — no WiX extensions needed, see the comment at
the top of `installer\Product.wxs` for why), producing
`dist\StockToolKiosk.msi`. See `installer\Product.wxs` for what it
installs and `installer\SetupWizard.ps1` for the exposure-mode
configuration logic — both are commented in detail.

**What happens when someone installs the .msi:**

1. `StockToolKiosk.exe` and the setup/uninstall scripts are copied to
   `Program Files\StockTool Kiosk\`, using Windows' own default
   install UI (no custom Welcome/License screens — an earlier attempt
   at a fully custom install experience via the WiX UI extension hit
   repeated errors that weren't practical to resolve without a real
   WiX toolchain to test against, so this trades that polish for
   something that reliably builds).
2. Start Menu shortcuts are created: **StockTool Kiosk** (opens the UI
   in a browser, same as running the exe directly) and **StockTool
   Kiosk Setup** (runs the configuration wizard).
3. Right after installing, click **StockTool Kiosk Setup** in the
   Start Menu once. That opens the wizard, which now handles account
   setup too -- there's no signup/user-management screen anywhere in
   the app itself (by design; see `app/auth.py`), so this is the only
   way to get a working login:
   - **Admin Account** -- a username (defaults to `admin`) and an
     optional badge code. On Save, this calls a new
     `StockToolKiosk.exe --create-user` mode (see `main.py`) that
     creates or updates a `LocalUser` row directly via the app's own
     SQLAlchemy models -- not hand-written SQL, so it can never drift
     out of sync with `models.py`. Idempotent: re-running the wizard
     later (e.g. just to change exposure mode) updates the same
     account rather than erroring or creating a duplicate. It also
     retries briefly on a transient "database is locked" error, since
     on a re-run the Windows service is usually already running and
     holding the same SQLite file open.
   - **How should the API be reachable**:
     - **Local only** — binds `127.0.0.1`. Default, safest.
     - **Cloudflare Tunnel** — still binds `127.0.0.1`; the wizard
       downloads `cloudflared` and runs `cloudflared service install
       <token>`, which registers Cloudflare's own connector service.
       The tunnel itself (hostname, routing) must already exist in
       your Cloudflare Zero Trust dashboard — the wizard only installs
       the local connector with the token you paste in.
     - **Public IP** — binds `0.0.0.0` on the chosen port and opens
       that port in Windows Firewall.
4. Saving in the wizard creates/updates the admin account first (while
   nothing else is likely touching the DB yet on a first install), then
   registers `StockToolKiosk.exe --service` as a Windows service
   (`StockToolKioskAPI`, via a bundled-on-first-run copy of NSSM) set
   to auto-start, so the API/admin UI stays up in the background
   regardless of who's logged in.

There's still no way to create *items* or *tools* through the UI or
wizard — only accounts. That's a real gap in the app itself (no
`POST /api/items` to create one, only `/adjust` on an existing row —
same for tools), not something the installer works around. Items/tools
are meant to come from the not-yet-built cloud sync engine
(`sync_loop.py`, Part 3). Until that exists, seeding sample inventory
still needs a manual step (see the note further down / ask if you want
that turned into a wizard feature too).

## Cloud pairing and backups (stocktoolsetup.opslabsystems.cloud)

Right after a fresh install, the MSI automatically runs
`StockToolKiosk.exe --cloud-setup` (see `app/cloud_setup.py`), which:

1. Generates an 8-character setup code and registers it with
   `https://stocktoolsetup.opslabsystems.cloud`.
2. Opens the user's browser to that site with the code pre-filled.
3. On that site, the user creates the kiosk's admin account (username,
   optional badge code) and a separate password-protected login for the
   site itself (used only to view/download this kiosk's backups later --
   the kiosk's own local login stays passwordless, unchanged).
4. Once submitted, the kiosk (still polling in the background) picks it
   up, creates the local admin account the same way `--create-user`
   always has, and saves a long-lived installation token to
   `settings.json`.
5. From then on, `backup_loop.py` runs alongside the embedded server and
   pushes the local `kiosk_local.db` file to that site every 6 hours
   automatically. Trigger one immediately with
   `POST http://127.0.0.1:<port>/api/backup/trigger`.

This is all outbound-only (the kiosk calls out to the cloud; nothing new
listens for inbound connections), so it doesn't change the bind-mode
security model above at all. If the setup code times out (20 minutes) or
the browser window gets closed, just run **StockTool Kiosk Setup** ->
`StockToolKiosk.exe --cloud-setup` again, or from an elevated prompt:
`StockToolKiosk.exe --cloud-setup`.

Re-running the **StockTool Kiosk Setup** shortcut later lets you switch
modes (e.g. Local → Tunnel) or update the admin account without
reinstalling; it just rewrites `settings.json` and re-registers
whichever services that mode needs.

**Where things live once installed:**
- App + scripts: `Program Files\StockTool Kiosk\`
- Database + settings.json + service.log: `%ProgramData%\StockToolKiosk\`
  (was `%LOCALAPPDATA%` in the no-installer exe workflow — moved to
  ProgramData because a machine-wide service needs a location every
  session, including no session at all, can read/write — see
  `app/__init__.py`)

### ⚠️ Before enabling Tunnel or Public mode

`/api/auth/login` accepts a bare username or badge code with **no
password** (see `app/routes_auth.py` — by design, since user/password
management was meant to live in a future cloud admin app, not here),
and most `/api/items` and `/api/tools` routes have **no auth at all**.
That's a reasonable trust model on `127.0.0.1`-only where physical
possession of the kiosk is the access control. It stops being
reasonable the moment the API is reachable from the internet: anyone
who finds the tunnel hostname or public IP can read and modify
inventory, and anyone who knows or guesses a username gets a valid
admin session token.

The Setup Wizard shows this warning and requires an explicit
confirmation checkbox before it will enable either mode, but it does
**not** add authentication on your behalf. Recommended before going
further than Local mode:
- **Tunnel mode**: turn on [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)
  on the tunnel's public hostname. Free, configured entirely in the
  Cloudflare dashboard, adds a real login in front of this app with no
  code changes.
- **Public mode**: at minimum, restrict the port to known source IPs
  at your network firewall/router, in addition to the Windows Firewall
  rule the wizard creates (which only controls inbound-to-this-machine,
  not who's allowed to reach it upstream).
- Either way, consider whether this app's current auth is sufficient
  for your actual threat model before relying on it as the only gate —
  happy to help add real password-based auth to `routes_auth.py` if
  that'd be useful for your case.

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
    settings.py             settings.json (bind_mode/port) load/save
    routes_items.py        GET /api/items, POST /api/items/<id>/adjust
    routes_tools.py         GET /api/tools, checkout/checkin
    routes_projects.py       GET /api/projects (read-only, admin-managed)
    routes_barcode.py         POST /api/barcode/lookup, /register
    routes_auth.py             POST /api/auth/login, GET /api/auth/me
    routes_status.py            GET /api/status, /api/status/sync-log
    ui.py                        serves the single-page UI
    templates/index.html          the UI itself
  installer/
    Product.wxs               WiX v5 source for the .msi
    SetupWizard.ps1            exposure-mode config GUI (run post-install)
    UninstallCleanup.ps1        service/tunnel/firewall teardown on uninstall
    build.ps1                    one-command PyInstaller + WiX build
    assets/
      logo-icon.png                 header badge image in the wizard
      logo.ico                       wizard window/taskbar icon
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

(Local-API auth is intentionally light — this API was designed to only
ever bind to `127.0.0.1`. The `.msi` installer's Setup Wizard can now
optionally expose it beyond that machine via Cloudflare Tunnel or a
public IP — see "Before enabling Tunnel or Public mode" above before
using either. The bearer-token gate is for the barcode-registration
permission check, not perimeter security.)
