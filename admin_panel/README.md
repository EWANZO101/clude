# OpsLab Admin Panel — Parts 1–9 (COMPLETE): Scaffold, Auth, Companies & Roles, Instances, Remote Config, Update Packages, Update Scheduling, Update Lifecycle, Monitoring, Security & Staged Rollouts

This is the new **central, multi-tenant Admin Panel** described in the Kiosk Management
System remake spec — NOT the old per-kiosk local Admin Panel already built into the
kiosk exe. This one is a standalone Flask app that will eventually manage every customer's
fleet of kiosk instances remotely.

## What's in Part 1

- Flask app factory (`app/__init__.py`), config via `.env`
- SQLAlchemy models: `User`, `Company`, `CompanyMembership`, `CompanyInvite`
- Full auth system: signup, login, logout, email verification, forgot/reset password,
  change password, profile edit
- Company system: create company, edit details, list "my companies" on the dashboard
- Role-based access control: `owner / administrator / manager / operator`, with a
  permission matrix (`app/models.py::ROLE_PERMISSIONS`) and a `@permission_required(...)`
  decorator (`app/rbac.py`) for use on every company-scoped route going forward
- Member invites by email (token link, accept flow), role changes, member removal,
  "always at least one owner" guard
- Dark UI matching the StockTool Kiosk design system palette (Section 10 of the tech doc)

## The Admin Panel plan is now complete (Parts 1-9)

This zip contains the entire Admin Panel as specced. See
`ADMIN_PANEL_PROGRESS.txt` for the full history and what's explicitly
**not** built (Instance Agent, Kiosk Application, installers, tunnel server
— all separate future work).

## What's new in Part 9

- `StagedRollout` / `StagedRolloutInstance` models + `/companies/<id>/rollouts`
  (spec Section 42): pick a package, a batch size, and an ordered set of
  instances — batch 1 pushes immediately on creation, then an
  owner/administrator manually clicks "Advance to batch N" after eyeballing
  the previous batch (no automatic health-based gating — the spec's model is
  human judgement between batches, not an automated canary)
  - One instance's push failure inside a batch never blocks the rest (same
    principle as Part 5's bulk push)
  - Rollout auto-marks itself `completed` once the last batch is pushed;
    `halt` stops it early
- Configuration rollback (spec Section 43): a "Restore" button on any
  previously-`applied` config version — pushes a **new** version carrying
  that old version's content through the normal
  receive/validate/apply/confirm path, rather than rewriting history
- Smoke-tested: a 5-instance rollout at batch size 2 (batches of 2/2/1),
  advancing through all three batches, auto-completion on the last one,
  advance-after-completion correctly rejected, and a config restore that
  reproduces the old version's exact content as a new pending push

## What's new in Part 8

- `User.is_platform_admin`-adjacent addition: `RemoteAccessToken` model +
  a "Request remote access token" button on the instance detail page (spec
  Section 14) — issues a 10-minute token and tracks it; the tunnel server
  that would actually use it to proxy a session isn't built (noted plainly
  in the UI, not implied)
- `AuditLogEntry` model + `log_action()` helper (spec Section 15), wired
  into: enrollment token create/revoke, config push, update push/cancel/
  bulk-push, member role changes/removal, and platform-level package
  upload/withdraw. Company-scoped `/audit-log` page for owners/administrators
- **Bug found and fixed along the way**: `.env.example` shipped with
  `MAIL_SERVER=smtp.example.com`, which meant any email-triggering action
  (signup verification, invites, password reset) would throw an unhandled
  `socket.gaierror` and 500 the whole request the moment that placeholder
  host wasn't reachable — instead of falling back to the "log instead of
  send" dev behavior the README already described. Fixed by (1) wrapping
  `mail.send()` in try/except so a broken/misconfigured SMTP server logs the
  failure instead of crashing the action that triggered it, and (2) blanking
  `MAIL_SERVER` in `.env.example` so a fresh install actually gets the
  documented console-logging behavior by default
- Smoke-tested: remote access token issuance + validity check, audit log
  page rendering real entries, and confirmed the email fix resolves the
  crash (invite flow now succeeds even with no reachable SMTP host)

## What's new in Part 7

- Fleet stat cards (total/online/offline/updating/failed-in-24h) at the top
  of each company's instances page (spec Section 39)
- Instances table gained an "Update status" column showing the active
  deployment's live state, or "Up to date"
- Diagnostics panel on the instance detail page (spec Section 40): health
  status, tunnel status, and the current/most-recent deployment's event log
  (built from Part 6's `status_log` field) — honestly scoped as
  heartbeat/lifecycle-derived only, since real agent-pushed logs need the
  Instance Agent
- New platform-wide `/admin/dashboard` for OpsLab staff: companies, total
  kiosks, online/offline, updating, successful/failed in 24h, release count,
  and a recent-outcomes table across every company (the cross-company
  equivalent of the company-scoped stats)
- Smoke-tested: stat cards render with correct counts, diagnostics panel
  shows healthy status for a freshly-heartbeating instance, platform
  dashboard renders and aggregates correctly

## What's new in Part 6

- Full deployment lifecycle on `UpdateDeployment` (spec Sections 28-34):
  `scheduled → waiting → downloading → validating → preparing → installing →
  restarting → health_check → successful`, with `failed → rolling_back →
  rolled_back` as the automatic-rollback branch (spec Section 29), plus
  `cancelled`/`superseded` from Part 5
- Forward-only state machine (`app/models.py::ALLOWED_TRANSITIONS`) — any
  status report that isn't a legal next step from the current one is
  rejected with 409 and the list of what *is* allowed, so a confused or
  replayed agent report can never jump the sequence or resurrect a finished
  deployment
- `successful` is only accepted if a `health_check` report already marked
  `health_check_passed: true` on that same deployment (spec Section 32: "Only
  when the health checks pass should the update be marked Successful") —
  rejected with 400 otherwise, even if the agent claims success directly
- `Instance.last_known_good_version` — set only on a real `successful`
  transition, never optimistically (spec Section 31); a failed/rolled-back
  deployment leaves `app_version`/LKG untouched, since they were never
  advanced in the first place
- `UpdateDeployment.previous_version` snapshotted at push time (spec Section
  19: recovery info "should not be stored only inside the files being
  replaced by the update")
- New agent-facing endpoints:
  - `GET /api/v1/instances/updates/current` — the agent's poll target;
    flips `scheduled → waiting` automatically once `target_time_utc` arrives
  - `GET /api/v1/updates/<package_id>/download` — streams the ZIP, but only
    for a package the instance actually has an authorized in-flight
    deployment for (never an arbitrary package by ID); flips
    `waiting → downloading` on first successful call
  - `POST /api/v1/instances/updates/<deployment_id>/status` — the agent
    reports each step; validated against `ALLOWED_TRANSITIONS`
- Pushing a new update while one is already downloading/installing/etc. is
  now rejected outright (rather than silently superseding mid-flight) — only
  a still-`scheduled`/`waiting` (not yet started) deployment can be
  superseded by a newer push
- Instance detail page: current version + Last Known Good, live status of
  the active deployment (with health-check/rollback messages inline), and
  an expanded history table (started/completed times, health check
  pass/fail)
- Smoke-tested a full success run (push → poll → download → validating →
  preparing → installing → restarting → health_check pass → successful,
  confirming `app_version`/LKG updated) and a full failure/rollback run
  (health_check fail → successful correctly rejected with 400 → failed →
  rolling_back → rolled_back, confirming `app_version`/LKG stayed
  unchanged), plus an invalid state jump (409), unauthorized/unknown package
  download (404), and blocked-vs-allowed re-push depending on how far the
  existing deployment had progressed

## What's new in Part 5

- `UpdateDeployment` model — one row per targeted instance for every push,
  scoped down for this part to `scheduled` / `cancelled` / `superseded` (the
  full Downloading/Installing/Health Check/Rolled Back state machine is
  Part 6)
- Priority hierarchy (`app/update_scheduling.py`, spec Section 24, most
  specific wins): kiosk-specific time → company-wide time → 9:00 PM UK
  system default. Company gets `default_update_time` +
  `update_countdown_minutes`; Instance gets `scheduled_update_time` — both
  editable in the UI, both nullable ("clear override" checkboxes to inherit)
- BST/GMT-correct scheduling: uses `zoneinfo("Europe/London")` rather than a
  fixed UTC offset (spec Section 21 explicitly requires this), tested across
  a summer date, a winter date, and the day-rollover case
- Push flow on the instance detail page: pick a validated package (only
  ones whose `supported_os` includes this instance's OS are offered), choose
  **Update now** / **use configured schedule** / **custom date & time**
  (spec Section 27's "individual scheduled update" — highest priority)
- Bulk push page per company (spec Sections 27/41): tick instances, one
  package, one mode → creates one `UpdateDeployment` per instance; one
  instance's rejection (e.g. unsupported OS) is reported individually and
  never blocks the others
- Pushing again to an instance with an unacknowledged scheduled update
  auto-supersedes the old one — same one-thing-in-flight pattern as Part 3's
  config pushes
- Cancel a scheduled update (spec Section 23)
- Smoke-tested end to end: push-now, push-with-hierarchy (confirmed
  `system_default` source), company override picked up (`company` source),
  kiosk override taking priority over company (`kiosk` source), double-push
  supersede, cancel, bulk push across 2 instances, and a package correctly
  rejected for an OS it doesn't support — all passed

## What's new in Part 4

- New concept: `User.is_platform_admin` — OpsLab-staff-only flag, separate from
  any company's owner/administrator/manager/operator roles. Release management
  is an OpsLab (vendor) action, not a customer action, per spec Section 49.
  Grant it with `flask create-superuser ... --platform-admin`, or flip the
  column for an existing user.
- `UpdatePackage` model + `/admin/releases` (platform-admin only): upload a
  ZIP, see validation results, browse history, withdraw/reinstate a release
- ZIP validation (`app/update_validation.py`, spec Section 18): valid archive,
  package integrity (`zf.testzip()`), zip-slip / path-traversal protection,
  required `update.json` manifest with matching `version` and a valid
  `supported_os` list, and a required `rescue/` component (spec Section 17 —
  "should remain available independently from the main kiosk application")
- SHA-256 checksum computed and stored for every upload (spec Section 18
  "file integrity")
- Uploaded ZIPs are stored on disk under `UPDATE_PACKAGE_DIR` (default
  `./data/update_packages/`, configurable via `.env`), never in the database
- Duplicate versions rejected before validation even runs
- Signature/authentication verification of the package itself (the other half
  of spec Section 18) is deferred to Part 8's security hardening — noted in
  code rather than silently skipped
- Smoke-tested directly against 6 crafted fixture ZIPs (good, missing rescue,
  version mismatch, zip-slip attempt, invalid JSON, unsupported OS) — all
  validated exactly as expected — and through the full HTTP upload flow:
  403 before platform-admin grant → 200 after, good package validates,
  bad package correctly marked invalid with its errors shown, duplicate
  version blocked, withdraw/reinstate both work, files land on disk correctly

## What's new in Part 3

- `InstanceConfig` model — append-only, versioned per instance
  (spec Section 11: "Configuration should have versioning/history")
- Admin UI: a Configuration panel on the instance detail page — shows the
  current applied config, lets `manage_config`-permitted roles push a new JSON
  config, and lists full history with status badges (Pending / Applied /
  Failed / Rejected)
- Agent-facing API additions:
  - `GET /api/v1/instances/config` — returns the newest unacknowledged
    (`pending`) push if any, plus the last `current` applied config for reference
  - `POST /api/v1/instances/config/ack` — agent reports `applied` / `failed` /
    `rejected` with an optional message; a stale/duplicate ack on an
    already-resolved version correctly 409s instead of overwriting history
- Pushing a new config while a previous one is still unacknowledged
  automatically marks the old one `rejected` ("superseded") — an instance only
  ever has one thing to apply at a time
- Smoke-tested: push → agent polls → acks applied → current updates; push
  twice before ack → older one auto-superseded, agent sees only the latest;
  invalid JSON rejected client-side with a clear message; stale ack rejected
  with 409 without corrupting the resolved record

## What's new in Part 2

- `Instance` and `EnrollmentToken` models
- Admin-facing: `/companies/<id>/instances/` — list instances, generate/revoke
  enrollment tokens (optional expiry + max uses), open an instance detail page,
  rename an instance
- Agent-facing API (`/api/v1`, what an installed kiosk's Instance Agent calls):
  - `POST /api/v1/instances/register` — consumes an enrollment token, creates the
    instance, returns a one-time `instance_secret`
  - `POST /api/v1/instances/heartbeat` — authenticated via
    `Authorization: Bearer <instance_id>.<instance_secret>`, updates connection
    status/last-seen/IPs/versions
  - `GET /api/v1/instances/me` — lets the agent confirm its own identity
- Per-instance credentials are argon2-hashed server-side, same as user passwords —
  the raw secret is never stored and is only ever returned once, at registration
- Smoke-tested: create company → generate token → register two instances via the
  API → heartbeat → both show Online in the dashboard; bad credentials and bad
  tokens correctly rejected with 401

The actual install script (`install.sh` for Ubuntu/Debian, the Windows MSI) and the
Instance Agent binary that calls this API don't exist yet — those are part of the
separate Instance Agent build, not counted in the Admin Panel's 9 parts.

## Setup

```bash
cd admin_panel
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # edit SECRET_KEY, DATABASE_URL, mail settings
flask db init
flask db migrate -m "part 1: auth, companies, roles"
flask db upgrade
flask create-superuser you@example.com "Your Name"                       # regular first account
flask create-superuser ops@opslabsystems.cloud "Ops Admin" --platform-admin  # can upload releases
python run.py                # http://127.0.0.1:5000
```

If `MAIL_SERVER` is left blank in `.env`, verification/reset emails are logged to the
console instead of sent — fine for local dev, set `REQUIRE_EMAIL_VERIFICATION=0` too if
you want to skip the verify-email step entirely while testing.

## Repo layout: three separate systems

This repo hosts the **Admin Panel** (this app, `app/`), the **Kiosk App**
(`kiosk_app/` — a fully separate Flask project shipped to kiosk machines as
versioned releases), and the **Instance Agent** (`agent/` — the daemon that
manages a kiosk machine). See `OWNERSHIP.md` for the rule for each path and
why the split exists.

## Tests

```bash
python3 -m pytest        # everything: Admin Panel, Kiosk App smoke test, Agent
```

Or run any single file directly, e.g. `python3 -m unittest tests.test_app_boundaries -v`.
`tests/test_app_boundaries.py` is the structural safety net for the
Admin-Panel/Kiosk-App split described in `OWNERSHIP.md` — it fails if either
side ever imports the other, or if a template links to a route that doesn't
exist.

## Notes for what's coming next

- `Company` currently has no linked `Instance` model yet — that's Part 2, together with
  the agent-facing registration/heartbeat API real kiosk installs will call.
- `ROLE_PERMISSIONS` is a fixed dict for now. The remake spec doesn't call for fully
  custom roles at the company level (unlike the kiosk-local Admin Panel's AdminRole
  table), so this stays simple unless you want it editable later.
- See `ADMIN_PANEL_PROGRESS.txt` for the full part-by-part plan and what's left.
