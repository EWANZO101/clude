# SnailyCAD Migration Platform

## Part 26 — DB-only export with no name given now backs up every database (this drop)

**No migration needed** — code-only fix, just redeploy and re-download a
fresh agent zip for any new job.

- Previously, a database-only export (no install path, no DB name typed
  in) failed outright with "No database name was given, and I couldn't
  figure one out automatically" — even though the host/port/user/password
  were enough to connect to the server.
- The agent now falls back to listing every non-template database on the
  target Postgres server (`SELECT datname FROM pg_database WHERE
  datistemplate = false`) and backs up all of them, each as its own
  `database/<name>.sql` inside the package. An explicitly-typed DB name
  still wins and behaves exactly as before — this only kicks in when the
  name field is left blank and auto-detect from an install path also
  comes up empty.
- The manifest now records `database_names` (the list of databases that
  were actually backed up) alongside the existing `database_type`.
- Import side updated to match: restoring a multi-database backup with no
  target DB name given restores each database under its original name
  (creating it on the destination server first if it doesn't already
  exist). Restoring to a single explicitly-named target still works as
  before, and is refused with a clear message if the backup actually has
  more than one database in it.
- Verified for real: ran a database-only export with the DB name field
  blank against a server with multiple databases, confirmed all of them
  came back in the package with correct manifest entries, then restored
  the resulting package to a fresh server with no target name given and
  confirmed every database was recreated and populated correctly.

## Part 25 — Built-in step-by-step guide (this drop)

**No migration needed** — code-only addition, just redeploy.

- New `/guide` page — accessible whether logged in or not, linked from
  the top nav ("Guide") and a callout banner on the dashboard.
- Explains what exports/imports actually are, the three connection
  methods (Local / SSH / Agent) and when to use each, and gives full
  step-by-step walkthroughs for the two most common paths: exporting
  via Agent and importing via Agent. Also covers database-only mode +
  auto-detect, sharing an export, retention, and where to go if
  something goes wrong.
- Verified for real: confirmed the page renders and is reachable both
  logged out and logged in, confirmed the dashboard callout shows up,
  and confirmed the "get help" link correctly points to the support
  ticket form when logged in vs. the login page when not.

## Part 24 — Made DB auto-detect failures fully diagnostic (this drop)

**No migration needed** — code-only fix, just redeploy and re-download a
fresh agent zip.

- The recurring `database "snaily-cadv4" does not exist` was still
  happening after Part 23's mismatch warning, but the warning itself
  never fired — meaning no `.env` was actually found to compare
  against, and that failure was completely silent.
- `parse_env_database_url()` now logs **exactly which paths it checked
  and what it found at each one** — not found, found but no
  `DATABASE_URL` line, found but empty, found but not a `postgres://`
  URL, or found but with no database name in it. Reaches both the
  terminal and the job's live web log, same as everywhere else.
- This turns "why didn't auto-detect work" from a guessing game into
  something self-explanatory in the output itself — if it's still
  failing after this, the log will say precisely why (e.g. wrong
  install path, `.env` in a different location than expected, or a
  non-Postgres/malformed `DATABASE_URL`), which makes it possible to
  fix the actual layout mismatch instead of guessing.
- Verified for real: simulated an install path with no `.env` anywhere
  near it and confirmed the exact "checked: ... (not found)" message
  for every location, both in the terminal and stored in the job's log.

## Part 23 — Fixed DB auto-detect being unusable in database-only mode (this drop)

**No migration needed** — code-only fix, just redeploy and re-download a
fresh agent zip for any new job.

- Root cause of `database "snaily-cadv4" does not exist` recurring even
  after Part 17's auto-detect fix: when "Include files"/"Restore files"
  was unchecked (database-only mode), the install/target path was being
  discarded entirely before reaching the agent — so there was nothing
  left to read the `.env` from, and auto-detect never even ran. Fixed:
  the path is now always passed through if you typed one, independent
  of whether file collection happens — filling it in for a
  database-only job still gets you auto-detect, it just skips copying
  files.
- Second issue found alongside it: if you type *any* database name —
  even a wrong one — the tool respects it and won't second-guess you
  (that's the correct behavior for someone who really does want a
  different name). But since this exact wrong name kept recurring, it
  now also **cross-checks against the `.env`** and warns loudly, right
  in both the terminal and the live web progress log, when what you
  typed doesn't match what's actually there — telling you the real name
  and exactly what to do about it, instead of just failing.
- Verified for real, all three paths: database-only export with the
  path filled in and the wrong name typed (now shows the exact
  mismatch warning with the real name), same setup with the name left
  blank (auto-detects cleanly, confirmed this still works), and
  confirmed the warning appears in the actual job status page's live
  log, not just the terminal.

## Part 22 — Email verification was never actually enforced (this drop)

**No migration needed** — code-only fix, just redeploy.

- Real bug found: `email_verified` got set correctly on register and on
  clicking the verify link, but **`login()` never checked it**. The
  entire verification requirement was decorative — anyone could log in
  immediately after registering without ever opening the email.
- Fixed: login now blocks unverified (non-temporary) accounts with a
  clear message, and shows a "Resend verification email" button right
  there on the login page.
- Added `/auth/resend-verification` — in case the original email got
  lost or the 24h link expired. Same non-enumeration protection as
  password reset: identical response whether or not the account exists
  or needs verifying, no account-existence leak. Falls back to showing
  the link directly if mail isn't configured, same as everywhere else.
- Verified for real, full loop: registered a new account, confirmed
  login was correctly blocked before verifying, clicked the actual
  verification link, confirmed login then succeeded. Separately tested
  resend-verification against a live SMTP server and confirmed the
  real email arrives with a working link.

## Part 21 — Fixed the actual reason emails weren't sending (this drop)

**No migration needed** — code-only fix, just redeploy.

- Root cause: `Setting.DEFAULTS["mail_from"]` was hardcoded to
  `"no-reply@example.com"`. Since `Setting.get()` checks its own
  `DEFAULTS` dict before falling back to whatever default you pass it,
  this silently won *every* time — meaning every email sent claimed to
  be from `no-reply@example.com` regardless of the real
  `MAIL_DEFAULT_SENDER` set in `.env`. Your mail server almost certainly
  wasn't authenticating/relaying mail claiming to be from an unrelated
  `example.com` address, so nothing ever arrived — while the SMTP
  transaction itself could still complete without raising an error,
  which is why there was nothing obvious in the logs either.
- Fixed by changing that default to an empty string, so it correctly
  falls through to your `.env` value unless you've explicitly set a
  different "mail from" in `/admin/settings`.
- New `flask test-email` command — prints the mail config actually being
  used (server/port/TLS/sender), prompts for a recipient, sends a real
  test message, and tells you plainly whether it succeeded or failed.
  Use this any time mail seems off, instead of triggering the full
  register/reset flow to find out.
- Verified for real: reproduced the bug first (confirmed the wrong
  sender was being used), applied the fix, confirmed the sender
  resolves correctly, then ran `flask test-email` against a live local
  SMTP server and confirmed the received message's `From:` header
  matches your real configured address exactly.

## Part 20 — Admin-set retention override + consolidated user activity (this drop)

**⚠️ Migration required** — one new column (`exports.retention_override_days`).
Run `flask db migrate -m "add retention override" && flask db upgrade`
(or `./fix_db.sh`).

This closes the two remaining admin-area items from the requirements doc:

- **"Setting custom retention periods beyond the standard 7 days"** — until
  now admins could only approve/decline a *user-submitted* request.
  `/admin/exports` now has a direct per-export retention override field —
  type a number of days, hit Set, done immediately, no request/approval
  round-trip needed. Clear the field to remove the override. Whichever
  source (standard/approved-request/admin-override) grants the most time
  wins, so setting one doesn't accidentally shorten another.
- **"Viewing user activity and requests"** — `/admin/users/<id>` now shows
  a full picture, not just exports: retention extension requests, support
  tickets, share links they've created, and a recent-activity feed from
  the audit log — all in one place, matching "access relevant user
  information required for support and moderation" from the doc.
- Verified for real: backdated a 10-day-old export (already past the
  standard 7-day window, no extension request), set a 30-day admin
  override on it through the actual form, ran `flask cleanup`, confirmed
  it survived — then cleared the override and confirmed that worked too.
  Also confirmed the consolidated activity view actually renders all
  five sections on a live user detail page.

## Part 19 — Retention extension requests + support tickets (this drop)

**⚠️ Migration required** — 4 new tables (`retention_extension_requests`,
`support_tickets`, `ticket_messages`, and the share-link table from Part
18 if not already migrated). Run `flask db migrate -m "..." && flask db
upgrade` (or `./fix_db.sh`) before restarting.

### Data retention extension requests
- Standard retention is now **7 days** (matching the doc), down from the
  30-day default this had before — configurable per-platform in
  `/admin/settings` same as always.
- On any completed export: "Request longer retention" — reason, requested
  number of days, and all 5 consent checkboxes from the doc's Extended
  Data Retention Terms, enforced (won't submit unless every box is
  checked — verified this rejects incomplete consent and accepts full
  consent, tested both paths for real).
- Anything beyond standard always needs admin approval —
  `/admin/extension-requests` shows pending requests with the user's
  stated reason, approve/decline with optional notes.
- **The part that actually matters**: `flask cleanup` (and the admin's
  manual "clean up expired" button) now check each export individually
  for an approved extension before expiring it, instead of applying one
  flat cutoff to everything. Verified with a real before/after test:
  backdated two exports past the 7-day standard, one with an approved
  90-day extension and one without — cleanup correctly left the
  extended one alone and expired the control one.

### Support ticket system
- User-facing (`/support`): create tickets, see status, reply, track
  history.
- Admin-facing (`/admin/support`): full ticket list with status/priority/
  assignment filters, a conversation view per ticket, assign to any
  admin, set priority (low/normal/high/urgent) and status (open/pending
  user/pending support/resolved/closed), and — per the doc's
  requirement — full visibility into that user's recent exports and
  extension requests right on the ticket page, plus a link straight to
  their account.
- Admins can open a ticket **on the user's behalf** (`/admin/support/new`)
  — searches by email, creates the ticket with the admin's first message
  already in it. Verified the user then sees it in their own ticket list
  and can read/reply to it, exactly as if they'd opened it themselves.

### Bugs found and fixed while building this
- **`_form_errors.html` assumed a single ambient `form` variable** —
  broke the export detail page with a 500 the moment it had two forms on
  one page (share link + extension request). Fixed by scoping each
  include with `{% with form=... %}`. Caught this via the same real-HTTP
  testing discipline used throughout, not by manual inspection.
- Continued the CSRF-token audit from Part 18 across all the new admin
  action forms (approve/decline buttons, etc.) — all carry tokens now.

## Part 18 — Live progress logs + share links (this drop)

This was a big combined ask; the retention-extension-request system and
full support ticket system from the requirements doc are **not** in this
drop — that's a genuinely separate, large system (approval workflows,
terms-acceptance, ticket UI) and deserves its own focused build rather
than being rushed in alongside everything else here. Flagging it as the
next part.

### Live progress (agent job page)
- The agent now narrates everything in plain English instead of
  technical log lines — "Backing up your database... this can take a
  few minutes" instead of "Dumping local Postgres database..."
- A real ASCII progress bar in the terminal for uploads/downloads,
  showing percent and running/total size (`[####------] 40% (2.1 MB of
  5.3 MB)`)
- Explicit size reporting and mismatch flagging at every transfer point:
  what got uploaded vs. what the platform confirms it received; what
  got downloaded vs. the `Content-Length` the platform sent; the
  database backup's file size vs. the size of the file actually
  restored. Any mismatch gets a clear ⚠ warning, not a silent failure.
- The job status page (`/agent/job/<id>`) now shows this live: a
  progress bar and a growing, timestamped, plain-English log —
  starts updating the moment the agent connects, not just at the end.
  New `POST /agent/api/<job_id>/progress` endpoint the agent calls
  throughout the run; `AgentJob.log_text` (already existed) now holds
  the running transcript, plus a new `progress_percent` column.
- Verified for real: ran the actual agent against a live server,
  confirmed the terminal output, confirmed the exact `status.json` HTTP
  endpoint the browser polls returns the right progress/log data at
  each stage, confirmed `human_size()` formatting across scales.

### Share links
- Any completed export can now be shared via `/exports/<id>` → pick a
  duration (30 min / 1 hour / 12 hours / custom) → get a one-time PIN
  and a public link. No account needed on the recipient's end — hand it
  to a hosting provider or whoever's helping with the migration.
- Durations up to 168 hours (7 days) activate immediately; anything
  longer needs approval from an admin first (`/admin/share-links`),
  matching the requirement that OpsLab team sign off on anything past
  the standard window.
- PINs are hashed (never stored in plain text), rate-limited (15
  requests/min per IP) on top of a persistent lockout after 10 wrong
  attempts on a given link, and links can be turned off early by the
  owner or an admin at any time.
- Verified for real: created a link through the actual form, accessed
  it from a completely separate, never-authenticated session (no login
  cookie at all) with the wrong PIN (rejected, correct error shown),
  then the right PIN (got the real file bytes back), tested the >168h
  approval flow end-to-end including the admin approve action, tested
  revocation actually blocks access immediately, and verified the
  lockout/expiry logic directly.
- **Found and fixed a real, previously-shipped bug while building
  this**: several existing action forms across the app (admin export
  cleanup/delete, admin user force-logout/reset-link/delete, export
  delete, import delete) were missing CSRF tokens entirely — they would
  have failed with a 400 error the moment anyone actually clicked them
  in production, since Flask-WTF's CSRF protection covers all POST
  requests app-wide. Caught this because my own new admin approve/deny
  buttons hit the same issue during testing, then audited every POST
  form in the app for the same gap and fixed all of them.

## Part 17 — Auto-detect database credentials from .env (this drop)
- Root cause of "database snaily-cadv4 does not exist": that name was
  typed by hand and simply wasn't the real one. The agent now reads it
  straight out of SnailyCAD's own `.env` (`DATABASE_URL=...`) instead of
  relying on anyone typing it correctly.
- `parse_env_database_url()` finds and parses `DATABASE_URL` from the
  install's `.env`/`apps/api/.env`; `resolve_db_config()` fills in any
  blank host/port/user/password/name fields from it — anything you did
  type explicitly is left alone, only blanks get auto-filled.
- Applies to both directions: export (using the install path you gave)
  and restore (using the target path, if it already has an existing
  SnailyCAD `.env` there — useful when restoring over/updating an
  existing install).
- If there's genuinely no way to determine the DB name (no name given
  and no install/target path to read a `.env` from), the error message
  now says exactly that instead of a cryptic `KeyError` or a
  "database does not exist" surprise.
- Form hints updated: "DB name — leave blank to auto-detect from the
  install's .env."
- Verified for real: parsed an actual `DATABASE_URL` line, confirmed
  auto-fill only touches blank fields (explicit values always win), and
  ran a full agent export with the DB name left blank — confirmed it
  logged the auto-detected name pulled from a real `.env` file rather
  than failing or using a wrong guess.

## Part 16 — Database-only agent export (this drop)
- Same fix as Part 14, applied to the export side: `/agent/new-export`
  now has an **"Include files"** checkbox (checked by default). Uncheck
  it and the install path is no longer required — the agent skips
  install-path validation and file collection entirely, doing nothing
  but the database dump.
- Same custom-validator pattern as the import form (required install
  path unless database-only; required at least one of files/database),
  and deliberately no `Optional()` on `install_path`/`db_type` this
  time, having learned that lesson from Part 14.
- Verified for real: all four scenarios through the actual HTTP
  flow (database-only, neither selected, files-only, and the exact
  "install path required" bug reproduced and confirmed fixed), then a
  full real agent run doing a genuine database-only export — logged
  "No install path configured — database-only export, skipping files"
  and produced a package with just the database in it.

## Part 15 — Auto-detect PostgreSQL instead of requiring PATH setup (this drop)
- The agent no longer asks you to manually edit PATH. `find_db_tool()`
  tries `psql`/`pg_dump` on PATH first (unchanged, still the fast path
  if it's already set up), and if that fails, scans the standard Windows
  PostgreSQL install locations directly (`C:\Program Files\PostgreSQL\*\bin\`
  and the `(x86)` variant), picks the newest version if more than one is
  installed, and just uses the full path — no PATH edit, no new
  terminal, no reboot.
- If it's genuinely not installed anywhere, the error message no longer
  suggests editing PATH (since auto-detect already covers that case) —
  it just says to install PostgreSQL.
- Verified for real: simulated multiple PostgreSQL versions installed
  side by side and confirmed it picks the newest one; confirmed the
  normal already-on-PATH case is untouched; confirmed a genuinely
  missing tool still fails with a clear message instead of a raw OS error.

## Part 14 — Database-only agent restore (this drop)
- `/agent/new-import` now has a **"Restore files"** checkbox (checked by
  default). Uncheck it for a database-only restore — the target install
  path is no longer required in that mode, and the agent skips the file
  restore/permissions step entirely, doing nothing but the DB restore.
- Fixed two real WTForms bugs found while building this: `Optional()`
  validators on `db_type` and `target_path` were silently short-circuiting
  the validation chain (`Optional` raises `StopValidation`, which skips
  every validator queued after it — including the custom "at least one
  of files/database must be selected" check and the "target path
  required unless database-only" check). Both fields no longer carry a
  redundant `Optional()`, since the custom inline validators already
  handle their optionality correctly.
- Verified for real, all four paths: database-only (no target path,
  succeeds), neither files nor database selected (clear error, doesn't
  silently create a no-op job), files-only, and the original bug
  scenario (files checked, path blank — now shows a proper error
  instead of a silent redirect). Then ran a full real agent restore in
  database-only mode end to end: real SQLite export → real DB-only
  import → confirmed the exact data was restored and zero files were
  touched.

## Part 13 — Fixed silent form-validation failures (this drop)
- Root cause of "I filled it in and clicking Generate just reloads the
  page": several forms (both agent forms, the SSH export form, and
  several auth/admin forms) never rendered validation errors anywhere —
  a required field left blank (in your case, "Target SnailyCAD install
  path") failed validation, Flask re-rendered the same form, and nothing
  told you why. It looked exactly like the button did nothing.
- Added `app/templates/_form_errors.html` — a shared error-summary
  banner ("Please fix the following: ...") — and included it in every
  form across the app: both agent forms, SSH export/import forms, admin
  settings/user-edit, and all the auth forms.
- Verified for real: reproduced your exact scenario (DB fields filled,
  target path left blank) through the actual HTTP flow, confirmed the
  old behavior silently re-rendered with zero feedback, confirmed the
  fix now shows "Target SnailyCAD install path: This field is required."
  right on the page, and confirmed the normal (all-fields-filled) path
  still redirects to the job page correctly.

## Part 12 — Clear error when psql/pg_dump isn't installed (this drop)
- `[WinError 2] The system cannot find the file specified` (Windows) /
  `No such file or directory` (Linux) is what Python's `subprocess`
  raises when the executable itself can't be found — i.e. `psql` or
  `pg_dump` isn't installed or isn't on PATH on the machine running the
  agent. That raw OS error doesn't say any of that.
- Both call sites now go through `run_db_tool()`, which catches exactly
  this and raises a clear, OS-appropriate message instead: on Windows,
  it points at the typical PostgreSQL install location
  (`C:\Program Files\PostgreSQL\<version>\bin\`) and a download link; on
  Linux, it says to install `postgresql-client`.
- Verified for real: simulated a missing binary and confirmed both the
  Windows- and Linux-flavored messages render correctly, then ran a full
  no-database export end to end to confirm nothing else broke.

## Part 11 — File-vs-folder confusion fix (this drop)
- Root cause of the `D:\.env.example` failure: the install path field
  needs the SnailyCAD **folder**, and a specific file inside it (like
  `.env.example`) was entered instead.
- Auto-correct: if the given install path is actually a file, the agent
  now uses its parent folder automatically and logs that it did so,
  instead of just failing.
- If the path still doesn't check out after that, the error message now
  explicitly says it needs the install FOLDER, not a specific file, with
  an example.
- Form field description + placeholder updated to say this up front
  ("The FOLDER SnailyCAD is installed in — not this server, and not a
  specific file inside it").
- Verified for real: submitted a job with the install path pointed
  directly at a file, confirmed the agent auto-corrected to the parent
  folder and completed the export; also confirmed a genuinely bad path
  now gets the clearer error message.

## Part 10 — Bug fix: quoted paths and Ctrl+C crash (this drop)
- **Root cause of the "Install path does not exist" failure**: pasting a
  path copied via Windows Explorer's "Copy as path" wraps it in literal
  double quotes (`"D:\SnailyCAD"`), and that was going straight through
  unmodified — `os.path.isdir('"D:\SnailyCAD"')` is never true since the
  quote characters are part of the string.
- Fixed at both ends: `app/path_utils.py::clean_path()` strips a matching
  pair of surrounding quotes + whitespace, wired in as a WTForms filter
  on every path field (agent export/import, SSH export/import, SQLite
  paths) so bad input never even gets saved. The agent script has the
  same logic built in too, as a second layer, for configs that were
  already saved before this fix.
- Fixed the `KeyboardInterrupt` traceback on Ctrl+C at the "Press Enter
  to close" prompt — now exits cleanly instead of dumping a stack trace.
- Verified for real: reproduced your exact failure by submitting
  `"/root/quote-test-snailycad"` (quotes included) through the actual
  web form, confirmed the agent received the cleaned path
  (`/root/quote-test-snailycad`, no quotes) and completed the export
  successfully end to end.

## Part 9 — True one-click download (no command line) (this drop)
- The job status page no longer shows a command to copy-paste. Two
  buttons instead: **Download for Windows** / **Download for Linux**,
  each a zip generated per-job with the server URL and one-time token
  **already baked into the script** — nothing to type.
- Windows: unzip, double-click `Start Agent.bat`. It tries `py` then
  `python`; if neither is found it prints a clear message with a link to
  install Python (checking "Add python.exe to PATH") instead of failing
  silently or throwing a wall of Windows console errors. Ends with
  "Press Enter to close this window" so the console doesn't just vanish
  before you can read the result.
- Linux: unzip, `./start-agent.sh` (or run `snailycad_agent.py` directly
  — same zero-argument behavior).
- Honest limitation: this is still a Python script (with a `.bat`
  wrapper), not a compiled `.exe`. It requires Python 3 on the Windows
  box — most modern Windows machines either have it or it's a 2-minute
  install, and the launcher tells you exactly what to do if it's
  missing. A true dependency-free `.exe` needs building with PyInstaller
  **on** (or targeting) Windows, which isn't something I can produce
  from this Linux sandbox — happy to set up a GitHub Actions workflow
  that builds one automatically on a Windows runner if you want to go
  that route later.
- Verified for real: downloaded both zips through the actual HTTP flow,
  confirmed the embedded server URL/token are correctly spliced into the
  script (with proper Windows CRLF line endings and syntax-checked), and
  ran the Linux bundle exactly like a double-click would — zero
  command-line arguments — through a full real export.

## Part 8 — Downloadable agent (no port forwarding needed) (this drop)
- **New connection method: Agent.** Instead of this platform reaching out
  to a target (SSH), the target downloads a small script and it connects
  **out** to the platform over plain HTTP(S) — same direction as normal
  web browsing. Nothing needs to be reachable, port-forwarded, or opened
  on the target's firewall/router, and it works the same whether the
  target is behind NAT, on a different network, wherever.
- `agent_downloads/snailycad_agent.py` — the agent itself. **Python
  standard library only, nothing to pip install** on the target machine.
  Handshakes with a one-time token, then either:
  - **export**: walks the install path locally using the same known-path
    rules as the SSH/local exporter, runs `pg_dump`/copies SQLite locally
    (so the database only needs to be reachable from the target, never
    from this server), builds the same zip+manifest format as every other
    export path, and uploads it in one shot
  - **import**: downloads the package, verifies every file's sha256
    against the manifest locally, restores files + runs `psql`/SQLite
    restore + fixes permissions, all on the target machine
- `app/agent/` — new blueprint: `/agent/new-export` and `/agent/new-import`
  (same config fields as the SSH forms, minus any host/credentials —
  the agent doesn't need them, it's already standing on the target),
  `/agent/job/<id>` is a live-polling status page showing the download
  link, the one-line command to run, and updates automatically once the
  agent connects
  - Token-authenticated API (`/agent/api/*`) for the agent script itself —
    no login/session, no CSRF, just a single-use bearer token generated
    per job, expires in 2h if never claimed, and can't be replayed once
    the job completes
  - Server re-verifies every file hash in an uploaded export package
    itself rather than trusting the agent's claims — defense in depth
    against a buggy or tampered agent
  - Completed agent exports/imports land in the exact same `Export`/
    `ImportJob` tables as SSH or local ones — same dashboard, same
    detail pages, same admin views, no special-casing needed downstream
- Linked from both the regular export and import "new" pages
  ("Can't open a port to the target? → Use the agent method instead")
- Verified for real, not mocked: ran the actual agent script as a real
  subprocess against a real running Flask server — full export round
  trip (byte-exact content verified against the source files), full
  import round trip using the export the agent itself produced
  (byte-exact restore), a failure case (nonexistent install path,
  reported back correctly), an invalid-token rejection (401), and a
  replayed-token-on-a-completed-job rejection (409)

## Part 7 — Dependency checks
- `flask check-deps` — verifies all required packages are actually
  importable in the current venv and tells you exactly what's missing
  and what it's needed for, instead of failing mid-export with a raw
  `ModuleNotFoundError`
- Missing `paramiko` (SSH support) now fails with a clear "run pip
  install -r requirements.txt" message instead of a bare traceback
- `fix_db.sh` now runs `pip install -r requirements.txt` and
  `flask check-deps` automatically before touching the database, so
  re-running it after any future pull also catches dependency drift

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
