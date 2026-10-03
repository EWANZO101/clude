# SnailyCAD Migration Platform

## Part 6 — Real email delivery (this drop)
- `app/email.py` — SMTP sender (plain `smtplib`, no Flask-Mail dependency)
  used for account verification and password reset emails. Reads
  host/port/TLS/credentials from `.env` (`MAIL_*`), with the admin
  Settings page's "mail from" address taking priority over the `.env`
  default if it's been changed there
- Registration and "forgot password" now send real emails when
  `MAIL_SERVER` is configured; if it's not configured (your current
  setup), it falls back to showing the link directly in the flash
  message exactly like before — nothing breaks either way
- Fixed an account-enumeration leak while wiring this up: password reset
  now always shows the same generic "if that email exists…" message
  regardless of whether the account exists (previously a real account
  got the link shown immediately, giving away that the address was
  registered)
- Admin's "generate reset link" now actually emails the user directly,
  and still shows the link in the flash for support purposes
- Verified for real, not mocked: stood up a live local SMTP server,
  registered `example@example.com` through the actual HTTP form, confirmed
  a real verification email arrived with the right subject/body/link,
  did the same for password reset, then extracted the link from the
  received email, submitted a new password through it, and logged in
  with the new password to confirm the whole loop actually works

To turn this on for real: set `MAIL_SERVER`, `MAIL_PORT`, `MAIL_USERNAME`,
`MAIL_PASSWORD`, `MAIL_USE_TLS`, and `MAIL_DEFAULT_SENDER` in `.env` (any
SMTP provider — Postmark, SES, a Gmail app password, your own Postfix,
etc.), or set the "mail from" address in `/admin/settings`.

## Part 5 — Security hardening + deployment (this drop)
- Security headers on every response: `X-Content-Type-Options`,
  `X-Frame-Options: DENY`, `Referrer-Policy`, `Permissions-Policy`, a
  `Content-Security-Policy` scoped to the actual CDN sources the UI uses
  (Tailwind CDN + cdnjs for Flowbite), and HSTS in production
- Session hardening: sessions are now permanent with a 12h lifetime
  (`PERMANENT_SESSION_LIFETIME`), on top of the existing `HttpOnly`/
  `SameSite=Lax` cookies and `Secure` cookies in production
- Rate limiting extended to registration and password-reset requests
  (5/min each, on top of the existing 10/min on login and the new 10/min
  on 2FA setup) — verified for real: 6th request in a minute returns 429
- `flask cleanup` — new CLI command that deletes expired temporary
  accounts (and their export files) and marks completed exports past the
  admin-configured retention window as expired. Respects the
  "cleanup enabled" toggle in `/admin/settings`. Tested against seeded
  data: correctly removed an expired temp user + its export file, expired
  a 40-day-old export, and left a same-day export untouched
- `deploy/` — everything needed to run this for real, matching how
  swift1 itself is set up (systemd + Nginx):
  - `gunicorn_conf.py` — sized for long-running export/import requests
    (30 min timeout, not the usual 30s)
  - `snailycad-migrate.service` — systemd unit for the app
  - `snailycad-migrate-cleanup.service` + `.timer` — runs `flask cleanup`
    hourly via systemd timer instead of cron
  - `nginx.conf.example` — reverse proxy with `client_max_body_size 4G`
    and matching long timeouts for big database dumps; syntax-checked
    with `nginx -t`
  - `serve_windows.py` — Waitress entrypoint for Windows deployments,
    with a note on wrapping it with NSSM to run as an actual Windows
    service
  - `deploy.sh` — one-shot Linux setup: venv, deps, `.env` with a
    generated `SECRET_KEY`, migrations, installs + enables the systemd
    units, optionally installs the Nginx site and prompts for a domain

## Part 4.5 — Remote SSH source/target (this drop)
- New `app/transport.py`: a `LocalTransport` / `SSHTransport` abstraction
  that both the export and import engines now run through, so every file
  read, database dump/restore, and permission fix can happen either on
  this server or on a remote host — same code path either way
- **SSH only, password auth only** — no key-based auth anywhere, matching
  how this platform's own infra is run. `look_for_keys`/`allow_agent` are
  disabled so a keypair is never touched or required
- **RDP is intentionally not used for the data pull** — it's a graphical
  remote-desktop protocol with no scriptable way to transfer files or run
  commands. Instead, point the exporter/importer at the target's SSH
  service (OpenSSH Server — built into modern Windows 10/11/Server and
  virtually every Linux distro) and it collects/restores files, runs
  `pg_dump`/`psql` remotely, and pulls/pushes SQLite files over SFTP
- `/exports/new` and `/imports/new` both gained a Source/Target selector
  (Local vs Remote over SSH) with host/port/username/password/remote-OS
  fields; remote OS choice controls path-joining (`/` vs `\`) and where
  temp dump files land (`/tmp` vs `C:\Windows\Temp`)
- Verified for real, not just unit-tested: stood up a live local OpenSSH
  server, then ran full round trips over actual SSH/SFTP —
  remote file export, remote-to-remote file restore, and a remote SQLite
  database export + restore (including the pre-overwrite `.bak` backup) —
  all confirmed byte-exact, plus the exact HTTP form flow a user would
  submit (upload → SSH export → download → re-upload → SSH import)
- Found and fixed a template bug along the way: `manifest.items` in Jinja
  was resolving to Python's dict `.items()` method instead of the
  `"items"` key, which only surfaced once a real export was rendered on
  the detail page — switched to `manifest['items']`

## Part 4 — Admin dashboard (this drop)
- `flask create-admin` — CLI command to bootstrap or promote the first admin
- `/admin/` — overview: user/export/import counts, active sessions (24h),
  exports storage usage + host disk free space, recent audit activity
- `/admin/users` — search, view, edit role/suspension, force-logout (kills
  live sessions immediately, verified with a real mid-session test),
  generate password reset links, delete (also removes their export files)
- `/admin/exports` — filter by status, view/download/delete any user's
  export, "clean up expired" button that expires exports past the
  configured retention window
- `/admin/imports` — view all import jobs across users
- `/admin/audit-logs` — paginated, newest first
- `/admin/settings` — export retention days, temp account lifetime,
  cleanup toggle, mail server settings (backed by a `Setting` key/value table)
- Every admin route is gated by `admin_required`; verified anonymous and
  non-admin users get 403, admins get through — tested via Flask test client
- Bug fix carried over from earlier parts: `DATABASE_URL`/`EXPORTS_DIR`/
  `UPLOADS_DIR` relative paths from `.env` were resolving against the
  process's CWD instead of the project root, which breaks under gunicorn/
  systemd (`unable to open database file`). Now always resolved against
  the project root regardless of working directory.

## Part 3 — Import tool (this drop)
- `app/imports/service.py`: `ImportService` — detects target OS, extracts
  the package, re-verifies every file's sha256 against `manifest.json`
  (rejects tampered/corrupted packages before touching anything), restores
  the database (`psql` for Postgres, file copy w/ `.bak` backup for
  SQLite), restores config/CAD-config/uploads/custom files back to their
  original relative paths, applies default POSIX permissions on Linux
  targets, and flags cross-platform / version-mismatch warnings
- Zip-slip guarded on extraction (rejects paths that escape the staging dir)
- `/imports/new` — upload a package + target path + optional DB target
- `/imports/<id>` — status, warnings, progress log, delete
- `/imports` — history list
- Verified end-to-end: exported a fake install, restored it into a fresh
  target, confirmed restored bytes match the source exactly; also verified
  a tampered package (hash mismatch) is rejected before any files are
  written

## Part 2 — Export tool (this drop)
- `app/exports/service.py`: `ExportService` — validates the install path,
  collects `.env`/config files, CAD config, uploaded assets, custom paths;
  dumps the database (`pg_dump` for Postgres, file copy for SQLite);
  builds a `manifest.json` with per-file sha256; packages everything into
  one `.zip` with an archive-level sha256 sidecar file
- `/exports/new` — form to point at an install + DB and kick off an export
- `/exports/<id>` — status, manifest browser, download, delete
- Dashboard now links into real export creation/download
- Runs synchronously in-request for now — fine for testing and small
  instances; swap in Celery/RQ if exports get large enough to need a
  background worker (hooks are already isolated in `ExportService`)
- Export validation refuses to package an empty/incomplete export and
  re-hashes every staged file before zipping

## Part 1 — Foundation
- Flask app factory, config, extensions
- SQLAlchemy models: User (permanent + temporary), Export, AuditLog
- Full auth: register, login, logout, email verification (link surfaced via flash
  until mail is wired up), password reset, optional TOTP 2FA
- Temporary session accounts (12h expiry) — cleanup job comes in a later part
- Dark theme base UI (Tailwind + Flowbite), dashboard/account pages
- Rate limiting on login, audit logging on auth events

## Not yet built (later parts)
- Part 2: Export tool (DB, .env, config, uploads, roles, manifest, hashes, archive)
- Part 3: Import tool (OS detection, integrity check, restore, verification)
- Part 4: Admin dashboard (users, exports, system management, audit log UI)
- Part 5: Security hardening, cleanup jobs, deployment (gunicorn/waitress, nginx)

## Setup

```bash
python3 -m venv venv
source venv/bin/activate        # venv\Scripts\activate on Windows
pip install -r requirements.txt

cp .env.example .env            # edit SECRET_KEY at minimum

export FLASK_APP=run.py         # set FLASK_APP=run.py on Windows
flask db init
flask db migrate -m "initial schema"
flask db upgrade

python run.py
```

App runs at http://localhost:5000

## Notes
- No SSH key auth anywhere in this app — plain email/password + optional TOTP.
- Email sending isn't wired up yet: verification/reset links currently show in
  the flash message so you can test the flow. Hook up Flask-Mail or an API
  (Postmark/SES/etc) whenever you're ready.
- SQLite by default; set DATABASE_URL for Postgres/MySQL.
