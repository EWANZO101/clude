# CloudLoader Platform — Phase 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10

Phase 1: Core Skeleton + Auth System
Phase 2: Developer Panel (Products, Licenses, Customers, API Keys)
Phase 3: Tebex Integration
Phase 4: Script Upload + Automatic API Injector
Phase 5: CloudLoader Resource + Module Delivery System
Phase 6: Customer Portal + Zero-Config Server Setup
Phase 7: Admin Panel
Phase 8: Analytics
Phase 9: Two-Factor Authentication
Phase 10: Team Accounts

## Database migrations

Through Phase 10 this project used `db.create_all()` ad-hoc, which only
creates tables that don't exist yet — it silently does nothing for new
*columns* on existing tables. That caused repeated `UndefinedColumn` /
`UndefinedTable` errors on every phase that touched an existing model
(Phase 9's 2FA columns on `users`, Phase 10's `team_members` table, etc.).

This zip includes a proper Flask-Migrate baseline instead, covering the
full schema through Phase 10.

**One-time step on your existing swift1 database** (it already has this
schema, just built by hand instead of by a migration - this tells Alembic
"the baseline is already applied, don't try to CREATE TABLE again"):

```bash
flask db stamp head
```

**From Phase 11 onward**, every phase that changes a model ships an actual
migration file. Deploying it is:

```bash
flask db upgrade
```

That's it - no more hand-written `ALTER TABLE` snippets. If you ever do
change a model yourself outside of what I deliver, generate the migration
with:

```bash
flask db migrate -m "describe the change"
flask db upgrade
```

`FLASK_APP=run.py` needs to be set (or already exported) for `flask db`
commands to find the app - same as any other `flask` CLI usage.

## Phase 1 — Auth System

- **Registration** — username/email/password, generates User ID, Support ID,
  Recovery PIN (shown once), and API Identifier.
- **Login** — email + password, remember-me, rate-limited.
- **Password recovery** — email a signed, time-limited reset link
  (itsdangerous, 1hr expiry). Doesn't leak whether an email is registered.
- **Recovery PIN system** — bcrypt-hashed, never stored or shown in plain
  text after creation. Users can regenerate it from the dashboard (old PIN is
  invalidated immediately).
- **Support ID + support recovery flow** — support staff verify a user by
  Support ID + Recovery PIN, then can issue a one-time temporary password.
  Every lookup and temp-password issuance is written to `support_audit_log`.
  Passwords and recovery PINs are never visible to support.
- **Rate limiting** — Flask-Limiter backed by Redis on register/login/forgot-password.
- **Dark Tailwind UI** — base layout + all auth pages, flash messages, ready
  to extend for the dashboard.

## Phase 2 — Developer Panel

- **Become a developer** — any logged-in user can enable a developer
  workspace from `/developer`. Generates a Developer API Key (shown once,
  bcrypt-hashed at rest, only the prefix is kept visible for reference) —
  used for external sites, Tebex, and custom integrations per the spec.
- **Products** — create/list/view/disable. Each product gets a Product ID,
  a non-secret API Key (identifies the product to the license-check API),
  a Secret Key (bcrypt-hashed, shown once, regenerable), and a computed
  License Endpoint URL.
- **Licenses** — bulk-generate license keys per product (1–500 at a time),
  optionally pre-assigned to a customer email. Suspend / reactivate /
  revoke per license. Every license tracks `last_checked_at`,
  `activated_at` (set on first successful API check), and an optional
  `server_binding` (set automatically on first check if the caller sends
  a `server_id`).
- **Customers** — aggregated view of all licenses grouped by customer
  email, across all of a developer's products.
- **License check API** — `POST /api/license/check/<product_id>` with
  `{api_key, secret_key, license_key, server_id}` in the JSON body. This
  is the endpoint CloudLoader (Phase 5) will call at runtime. Rate-limited,
  validates product credentials + license status, returns product/license
  info on success.
- **Tenant isolation** — every developer route filters strictly by
  `developer_id == current_user.id`; a developer requesting another
  developer's product or license by ID gets a 404, not a 403 (doesn't
  even confirm the resource exists). Covered by an automated test in
  this delivery — two developers were created, and cross-tenant reads/
  writes were confirmed to fail.

## Phase 3 — Tebex Integration

- **Connect Tebex per product** from the product's Tebex page —
  optionally scoped to one Tebex package ID, otherwise accepts any package
  for that product. Generates a webhook secret (shown once, encrypted at
  rest — this one has to be reversible, unlike the password/PIN hashes,
  since the server needs the raw value to verify incoming signatures).
- **Webhook endpoint**: `POST /api/tebex/webhook/<product_id>`. Verifies
  the request via HMAC-SHA256 over the raw body using the `X-Signature`
  header (same shape as Tebex's own webhook signing) — invalid signatures
  are rejected with 401, no license is ever created on an unverified
  request.
- **On a valid purchase event**: generates a license (or several, if
  `quantity` is set), assigns it to the customer's email, and sends a
  confirmation email with the license key(s) via the same mailer used for
  password resets (logs to console if SMTP isn't configured yet).
- **Pause / resume / regenerate secret** without losing purchase history —
  `total_purchases` and `last_event_at` are tracked on the integration.
- Verified end-to-end in this delivery: real HMAC-signed webhook →
  license created → shows up on the Customers page → validates
  successfully through the Phase 2 license-check API. Bad signatures
  confirmed rejected.

## Phase 4 — Script Upload + Automatic API Injector

- **Upload** — developer picks a product, uploads `script.zip`. Platform
  finds `fxmanifest.lua` anywhere in the zip (root or one folder in,
  matching how most resources are packaged), validates it's a real FiveM
  resource, and rejects anything else with a clear error (bad zip, empty
  zip, no manifest) — stored as a `failed` record with the reason, not a
  silent 500.
- **Automatic API Injector** — generates `platform/api.lua`,
  `platform/license.lua`, `platform/updater.lua`, `platform/loader.lua`
  with the product's real credentials baked in (public API key only —
  never the developer's secret key, which stays server-side), appends
  four `server_script` lines to the *existing* `fxmanifest.lua` rather than
  trying to rewrite it, and leaves every original file untouched. Matches
  the spec's `protected_script/` = original files + `platform/` structure
  exactly.
- **What the injected Lua actually does at runtime**: on resource start,
  `license.lua` reads a `<resourcename>_license_key` convar, calls
  `POST /api/license/activate/<product_id>` (public-key gated, no secret
  needed), and stops the resource if invalid — with a re-check every 30
  minutes so a revoked license takes effect without a server restart.
  `updater.lua` polls `POST /api/update/check/<product_id>` every 6 hours
  and logs a console notice if a newer version is published.
- **Download** — developer downloads the protected build from the
  product's Scripts page and distributes that instead of their original
  zip. Storage is local disk under `UPLOAD_FOLDER` for now (swap for S3 or
  similar later — the DB only ever stores a relative path).
- Verified end-to-end: uploaded a synthetic resource → injector ran → all
  four platform files + correctly modified manifest confirmed present in
  the downloaded zip → original files confirmed byte-identical. Bad-zip
  and missing-manifest cases confirmed rejected with the record marked
  `failed`. Cross-developer download access confirmed blocked (404).

## Phase 5 — CloudLoader Resource + Module Delivery System

- **`GET /cloudloader`** — public page, no login needed. Explains setup for
  customers.
- **`GET /cloudloader/download`** — generates the actual `CloudLoader.zip`
  a customer installs: `fxmanifest.lua`, `client.lua`, `server.lua`,
  `api.lua`, `updater.lua`, `module_loader.lua` — matching the spec's file
  list exactly. It's generic (one build works for every customer, every
  developer) and configured purely through `server.cfg` convars:
  `cloudloader_site_url` and a `cloudloader_products` JSON array of
  `{product_id, api_key, license_key}` — one entry per product they've
  bought.
- **Modules** — a lightweight "Script Builder" on each product's Modules
  page: name, side (server/client), and a Lua code textarea. This is
  literally where the code lives — it is never written to the customer's
  resource folder as a file.
- **Module Delivery API**: `POST /api/module/list/<product_id>` and
  `POST /api/module/download/<product_id>/<module_name>`, both gated by a
  *valid, non-revoked* license (not just the product API key) — so
  revoking a license cuts off module access immediately, not just future
  license checks.
- **Server-side modules** run directly via `load()` in the CloudLoader
  resource; **client-side modules** are dispatched to connected players
  over a network event and `load()`'d there. Downloaded code is also
  cached to disk (`SaveResourceFile` into `cache/modules/`) per the spec.
- **Tebex confirmation emails now include full setup** — not just the
  license key, but the CloudLoader install link and a ready-to-paste
  `cloudloader_products` entry with the product's `product_id` and public
  `api_key` already filled in. A customer can go from "just bought it" to
  "running on their server" using only that one email.
- Verified end-to-end in this delivery, reproducing the spec's own demo
  scenario almost exactly: created a "Test Menu Script" product with a
  `/lka` module whose code prints "Licensed Successfully — Hello from
  Cloud API" — confirmed the CloudLoader zip downloads with all 6 files,
  simulated the Lua runtime's actual call sequence (license activate →
  module list → module download) against the real API and got the exact
  module code back, and confirmed revoking the license immediately blocks
  module list/download (403), not just future license checks.

## Phase 6 — Customer Portal + Zero-Config Server Setup

This was a direct response to the manual server.cfg JSON editing being bad
UX — the whole point was to remove it.

- **Auto-linking, no claim step.** A purchase made before someone has an
  account still shows up the instant they register (or log in) with the
  same email — checked automatically on both routes, not a one-time
  migration.
- **`/portal` — My Licenses.** Every purchase tied to your account, in
  one place, with status (active/suspended/revoked) visible at a glance.
- **`/portal/servers` — register a server, get one token.** The token is
  SHA-256-hashed at rest for lookup (not bcrypt — bcrypt is deliberately
  slow and wrong for exact-match lookups on a high-entropy secret; SHA-256
  is the same approach GitHub uses for personal access tokens).
- **Attach a license to a server with a dropdown**, not a text file. Same
  for detaching.
- **Auto-attach on purchase** — if the buyer already has an account and
  exactly one registered server, a new Tebex purchase attaches itself
  automatically. (Zero or multiple servers: left for the portal, since
  the platform can't guess which one you meant.)
- **`POST /api/server/config`** — the only call CloudLoader's `server.lua`
  makes now. One token in, every attached *and currently valid*
  product/license out. Suspend or revoke a license and it silently drops
  out of this response on the next check — no Lua-side status handling
  needed, the platform just stops including it.
- **`server.cfg` is now one line**: `setr cloudloader_server_token "srv_..."`.
  No more hand-written JSON array of products.
- **Tebex confirmation emails now branch on account state** — existing
  account + auto-attached: "already live, nothing to do." Existing
  account, multiple servers: link to the portal. No account yet: sign up
  with this email and it appears automatically, with the raw license key
  still included as a manual fallback for anyone who doesn't want an
  account.
- Verified end-to-end: bought a product with no account → registered with
  that email → confirmed it appeared with **zero claim step** → registered
  a server → attached the license through the actual web route (not a
  direct DB write) → called `/api/server/config` with just the token and
  got back the full product/license payload → suspended the license and
  confirmed it silently disappeared from that same response → bought a
  second product with the account already existing and exactly one
  server → confirmed it auto-attached with no action taken. Wrong tokens
  confirmed rejected (401). Server/license ownership isolation follows
  the same `owner_id`/`customer_user_id` filtering pattern already
  verified in the developer panel.

## Phase 7 — Admin Panel

- **`/admin`** — gated by `is_admin` only (separate from the narrower
  `is_support` recovery-lookup tool from Phase 1). Dashboard shows
  platform-wide counts: users, developers, products, licenses (with
  active count), Tebex integrations, suspended users.
- **Users** — searchable (username/email/User ID/Support ID), per-user
  detail page showing their products, purchased licenses, and support
  history. Toggle `is_admin` / `is_support` / `is_developer` and
  suspend/reactivate directly — suspension actually blocks login (reuses
  the check already in Phase 1's login route).
- **Self-protection built in**: an admin can't suspend their own account
  or remove their own admin role through the panel (confirmed by test —
  both attempts correctly rejected with the account state unchanged).
- **Products** — platform-wide list across every developer, searchable,
  with a hard disable switch independent of the developer's own toggle
  (useful for a ToS violation without waiting on the developer).
- **Licenses** — platform-wide search by key or customer email, with a
  direct revoke action for support/abuse cases.
- **Logs** — the `SupportAuditLog` entries from Phase 1's recovery-PIN
  support flow, now visible platform-wide instead of only in the moment.
- Verified end-to-end: non-admin blocked from every `/admin` route,
  admin dashboard/users/products/licenses all load and function, search
  works on both users and products, suspending a user actually blocks
  their next login attempt, role toggles work, and both self-protection
  guards confirmed to reject the action *and* leave the account state
  unchanged.

## Phase 8 — Analytics

- **New `usage_events` table** logs one row per license check, module
  download, and Tebex purchase — deliberately minimal (no big JSON
  payload per row) so it stays cheap to query as it grows.
- **`/developer/products/<id>/analytics`** — license checks, module
  downloads, and purchases over the last 14 days; total vs. active
  license counts; a 14-day daily bar chart of license-check activity
  (pure CSS/Jinja, no charting library or client JS needed); top modules
  ranked by download count.
- Verified end-to-end: generated real activity through the actual API
  endpoints (3 license checks, 2 module downloads via
  `/api/license/activate` and `/api/module/download`), then confirmed
  the analytics page's totals match exactly and the top-modules table
  reflects the real download count. Cross-developer access to another
  developer's analytics confirmed blocked (404), consistent with every
  other developer-scoped route.

## Phase 9 — Two-Factor Authentication

Explicitly called out as "future" in the spec's Login System section.

- **TOTP-based** (Google Authenticator, Authy, any standard app) via
  `pyotp`. QR code rendered client-side (CDN `qrcodejs`, no server-side
  image generation dependency) from an `otpauth://` URI; the secret is
  also shown as text for manual entry.
- **Secret storage**: reversibly encrypted (same Fernet approach as Tebex
  webhook secrets) since TOTP verification needs the raw value — this is
  correctly different from password/recovery-PIN storage, which is
  one-way hashed.
- **8 backup codes**, shown once, bcrypt-hashed at rest, single-use
  (consumed and removed from the stored list on successful use).
- **Login flow**: correct password alone no longer logs you in if 2FA is
  enabled — it stashes a pending identity in the session and requires a
  second-factor code (TOTP or backup code) at `/auth/login/2fa` before
  `login_user()` is ever called.
- **Disable requires password confirmation** (not just being logged in),
  and users can regenerate backup codes independently of re-doing TOTP
  setup.
- Verified end-to-end with **real TOTP codes** (computed the same way an
  authenticator app would, via `pyotp.TOTP(secret).now()`) rather than
  mocking verification: enabled 2FA → confirmed password-only login stops
  short at the 2FA step → wrong code rejected and confirmed still not
  logged in → correct code completes login. Separately verified backup
  codes: one consumed on use, remaining count decremented, reuse of the
  same code rejected. Disable flow confirmed to reject a wrong password
  and succeed with the correct one, after which login skips the 2FA step
  entirely.
- Dashboard (previously still a Phase 1 placeholder) is now a real hub:
  quick links to My Licenses / Developer Panel / CloudLoader / Admin
  (if applicable), plus the 2FA enable/disable/regenerate controls.

## Phase 10 — Team Accounts

This one required a real refactor, not just additive routes: every
developer route previously filtered by `developer_id=current_user.id`
directly. That's now computed once per request via
`get_workspace_developer_id(current_user)` — a developer's own ID if
they own products, or the workspace owner's ID if they're an accepted
team member — stored on `g.workspace_developer_id` and used everywhere
instead. Every one of the ~25 call sites this touched was bulk-verified
by grep after the change, and the full existing product/license/module/
analytics workflow was re-tested afterward specifically to catch
regressions from a change this wide.

- **Invite by email** — owner-only, requires the invitee already have an
  account (no email-invite-to-signup flow yet, keeps this scoped).
- **Pending until accepted** — an invited user has zero workspace access
  until they explicitly accept from their dashboard; confirmed a pending
  invitee is correctly blocked from `/developer` in the meantime.
- **Accepted members get full workspace access** — same products,
  licenses, modules, everything the owner sees — and anything they
  *create* correctly attributes to the owner's `developer_id`, not a
  separate workspace of their own (verified directly against the DB, not
  just the UI response).
- **Team management is owner-only** — a team member hitting
  `/developer/team` gets turned away, confirmed by test.
- **Isolation from actual outsiders is unaffected** — a third, unrelated
  developer (with their own separate workspace) still gets a 404 on any
  of this workspace's products, same as before Phase 10 existed.

## UI fixes (post-Phase 10)

A pass through every template for layout bugs rather than new features:

- **Nav had grown to 6 flat items** (CloudLoader, Admin, My Licenses,
  Developer, username, Log out) with zero mobile handling — would
  overflow or wrap badly on any narrow screen. Rebuilt as a proper
  responsive nav: full row on desktop, hamburger + dropdown panel below
  the `sm` breakpoint.
- **Tebex package ID placeholder** was a full sentence crammed into a
  single-line input (`"Leave blank to accept any package for this
  product"`) — truncates on any normal-width input. Moved to proper
  helper text below the field, placeholder now just shows an example.
- **Fragile negative-margin layout** on the Team page (`-mt-6` to visually
  pull helper text up under a form) — the kind of hack that breaks the
  moment content wraps differently. Replaced with normal document flow.
- **Four secret/token masking displays** (Tebex webhook secret, product
  secret key, developer API key, server token) were missing `break-all`
  that every *other* secret-display element in the app already has —
  these long monospace strings would overflow their card on mobile.
  Fixed all four for consistency.
- **Developer overview's "Tebex" tile** claimed to be its own section
  ("Per-product") but actually just linked to Products, which was
  confusing since Tebex/Scripts/Modules/Analytics are all configured
  per-product with no workspace-wide list page. Removed the misleading
  tile, added a plain sentence pointing at where those actually live, and
  gave Team a proper consistent tile instead of a small text link that
  didn't match the rest of the page.
- Full sweep for leftover draft text (TODO/FIXME/lorem ipsum/stray phase
  references) across every template — none found beyond what's listed
  above.
- Re-tested after: public pages, dashboard, developer overview, Tebex
  settings, and Team page all confirmed to render with the fixes in
  place and without the old broken patterns.

## UI fixes, round 2

A systemic issue: 19 templates shared a `flex items-center
justify-between` row pattern for list items (product names, usernames,
emails, server names, module names — all user-supplied, all unbounded
length) sitting directly against a status badge or action buttons, with
no `min-w-0`/`truncate` on the text side or `flex-shrink-0` on the badge
side. On a long name this just grows the row past its container instead
of truncating — the classic Tailwind flex-overflow bug. Fixed the twelve
call sites with genuinely unbounded content: developer products list +
overview's recent-products, modules, scripts, admin users list + admin
dashboard's recent-users, admin products, team members, customers
grouping, portal servers + my-licenses + server-detail's attached
products, analytics' top-modules, admin logs, and the team-invite row on
the dashboard. Rows with multiple badges that could appear simultaneously
(admin users can show up to 4: admin/support/dev/suspended) also got
`flex-wrap` so the badge cluster drops to its own line rather than
fighting the name for space.

Caught and fixed a self-inflicted regression during this pass — an edit
to `scripts.html` briefly deleted the status badge entirely; restored and
re-verified with a regression test that specifically checks for its
presence, not just that the page returns 200.

Verified with product/module/server names deliberately set to long
strings (`"A Very Long Product Name That Might Overflow On Mobile
Screens"` etc.) through the actual routes, confirming every touched page
still renders correctly end to end, plus a full admin-page sweep.

## Bug fix: broken admin dashboard layout

The "Licenses" stat tile in `admin/dashboard.html` opened with `<a
href="...">` but closed with `</div>` instead of `</a>` — a genuine typo
from when that template was first written. Browsers auto-correct broken
HTML by guessing, and the guess here corrupted everything after it: the
Tebex Integrations / Suspended Users / Support Logs tiles fell outside
the grid container entirely (rendering full-width instead of in the
4-column grid), stray empty bordered boxes appeared from the malformed
tag-closing recovery, and "View" got visually truncated to "ew".

Fixed by closing the tile with `</a>` to match its opening tag. Verified
three ways: rendered the actual page through the real route and confirmed
the tile closes correctly, ran the full page through Python's stdlib
`html.parser` with a tag-balance checker and got zero mismatches (up from
the implicit corruption before), and swept every other template in the
codebase with the same checker to confirm this was an isolated incident,
not a systemic pattern.

## Fix: upload should mean "live via the API", not "here's a zip"

Real gap, not just a UI issue: the platform had two disconnected content
paths. **Scripts** (upload → get a protected zip back) required manually
installing yet another file beyond CloudLoader — exactly the
folder-management problem this was supposed to eliminate. **Modules**
(the actual zero-install, API-delivered path) only worked if you manually
retyped your code into a form. Uploading never fed into it.

Fixed by making script upload automatically publish every client/server/
shared script it finds straight into Modules:

- New `app/injector/manifest.py` parses `fxmanifest.lua` for
  `client_script(s)` / `server_script(s)` / `shared_script(s)` -
  singular, array, and multiline array forms all handled.
- `extract_modules_from_upload()` reads each referenced file's actual
  content out of the zip and returns ready-to-publish module data. Shared
  scripts become two modules (`name_server` / `name_client`) since a
  module only has one side - disambiguated by name rather than changing
  the DB schema, since a schema change means another migration.
- The upload route now upserts these into `Module` rows automatically:
  new scripts get created, **re-uploading updates existing modules in
  place** rather than duplicating them - so pushing a code update is just
  re-uploading the zip.
- The protected zip is still generated too, but now clearly labeled
  "Download (manual install)" - an optional fallback for anyone who
  specifically wants a traditionally-distributed resource, not the
  primary path.

Verified end-to-end with a realistic multi-file resource (separate
client/server/shared scripts): uploaded once, confirmed 4 modules
appeared automatically with zero manual entry, then replayed the *exact*
call sequence CloudLoader's Lua makes (`license/activate` →
`module/list` → `module/download`) against the real API and got the
actual uploaded code back - no zip, no folder, nothing beyond CloudLoader
involved anywhere in that chain. Then re-uploaded with changed code and
confirmed it updated the existing 4 modules in place rather than
creating duplicates.

## Fix: malformed URL in CloudLoader's error message

If `SITE_URL` in `.env` has a trailing slash (or, as happened, was set to
a full path instead of just the domain root), the printed
`.../portal/servers` hint in `server.lua` would double up into a broken
URL like `.../api/license/check//portal/servers`. `SITE_URL` is now
`.rstrip("/")`'d in `app/config.py` so a trailing slash alone can no
longer cause this - verified by setting `SITE_URL=http://example.com/`
and confirming the generated CloudLoader zip contains the clean,
non-doubled URL.

This only guards against a trailing slash. If `SITE_URL` has an actual
wrong path baked into it (like `/api/license/check/`), that's a `.env`
content fix on the deploy side, not something code can safely
auto-correct - `SITE_URL` should be just the domain root, e.g.
`http://your-domain.com` or `https://your-domain.com`, nothing after it.

## Fix: CloudLoader.zip content bugs

Two real bugs in the generated resource, beyond the earlier SITE_URL
issue:

- **Late joiners never got client modules.** `module_loader.lua` had a
  `playerJoining` handler that was dead code - a comment promising to
  re-send modules to joining players, with an empty loop body that did
  nothing. Anyone who joined after the initial load would silently never
  receive client-side script content, with no error to explain why.
  Replaced with a proper request/response pattern: `client.lua` asks the
  server for everything already loaded on its own resource start (covers
  joining late *and* client-side resource restarts), and
  `module_loader.lua` replies to that specific player rather than relying
  on a broadcast racing the client's own startup timing.
- **Verified with a real Lua compiler, not just visual inspection.**
  Installed `lua5.4`/`luac5.4` and ran `luac -p` (syntax-check only)
  against every file the platform generates - both the generic
  CloudLoader resource and the per-product injected files from Phase 4.
  All pass. Also confirmed the event names actually match between
  `client.lua`'s `TriggerServerEvent` and `module_loader.lua`'s
  `RegisterNetEvent`, and that the server's response targets the specific
  requesting player (`src`) rather than broadcasting to everyone again.
- Re-verified the SITE_URL fix from the previous round through the actual
  `/cloudloader/download` HTTP endpoint (not just the template function
  directly) - confirmed the real downloaded zip contains the corrected,
  non-doubled URL.

## Not in this phase (coming later)

Admin panel, full support agent tooling beyond the recovery flow, 2FA,
analytics/server monitoring, developer marketplace, team accounts,
version channels.

## Setup

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt

cp .env.example .env
# edit .env: SECRET_KEY, DATABASE_URL, REDIS_URL, MAIL_* (optional — logs
# emails to console if MAIL_SERVER is left blank)
```

By default `DATABASE_URL` falls back to a local SQLite file if unset, so you
can run this immediately without standing up Postgres. Swap in a Postgres
URL in `.env` whenever you're ready to move off SQLite — no code changes
needed, it's all through SQLAlchemy.

Redis is required for rate limiting (`REDIS_URL`). If you don't have Redis
running yet, either install it or lower `RATELIMIT_ENABLED = False` in
`app/config.py` temporarily.

### Create the database + first admin

```bash
python create_admin.py
```

This creates all tables and walks you through creating (or promoting) an
admin/support account.

### Run it

```bash
python run.py
```

Visit `http://localhost:5000/auth/register` to create an account, or
`http://localhost:5000/auth/login`.

Support lookup tool (needs `is_support` or `is_admin` on your account):
`http://localhost:5000/auth/support/lookup`

## Notes on choices made

- **SQLite fallback**: spec calls for Postgres. Kept that as the intended
  production DB via `DATABASE_URL`, but defaulted to SQLite locally so this
  runs with zero external services out of the box. Swap the env var when you
  deploy to swift1.
- **Recovery PIN format**: `XXXX-XXXX` numeric, matches the spec's example.
  Hashed with bcrypt like the password — genuinely un-recoverable once
  shown, which is what "never displayed again" implies.
- **Support verification**: implemented literally per the spec's flow
  (Support ID + Recovery PIN → support verifies → issues temp password).
  Audit-logged either way.
- **Email**: SMTP is wired up but optional — if `MAIL_SERVER` isn't set in
  `.env`, reset emails get logged to the console instead so you can test the
  full flow without a mail server yet.

## Next phase

Remaining from the spec's "Future Features" wishlist: developer
marketplace, automatic billing beyond Tebex, version channels, remote
configuration, server monitoring. Genuinely optional at this point.

Ten phases deep now with (as of the last confirmed status) only Phase 1
verified actually running on swift1 — that gap is the real risk to this
project at this point, more than any remaining feature. Strong
recommendation: next session, stop adding scope and get current code
deployed, verified booting, and stable before anything else gets built
on top of it.
