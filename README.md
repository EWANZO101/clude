# Xon Sight Evidence Portal

## What's new (2026-10-19, latest: multi-tenancy foundations)

The beginning of real multi-tenancy - "a community" with its own isolated data, reachable by its own token:

- **One dedicated MySQL database per community** (`xonsight_<slug>`), provisioned on demand from
  `/admin/communities` - its own MySQL user scoped to only that database, its own API token. Proven
  end-to-end: created a real community, posted to all four webhook endpoints with its token, confirmed
  the data landed in its own MySQL database with zero leakage into the control-plane database, then
  confirmed the opposite direction too (the original shared-key path still writes to the control-plane
  database exactly as before, completely unaffected).
- **`X-XonSight-Token` header** - an alternative to `X-XonSight-Key` on all four webhook endpoints. A valid
  token routes that request's reads/writes to its community's own MySQL database instead of the control
  plane. An invalid token is a hard 401; it never silently falls back to the shared-key path.
- **Scope, honestly limited:** only the webhook ingestion endpoints are tenant-aware right now. The
  browser-facing app (dashboard, evidence viewer, cases, assistant, admin) still only reads the
  control-plane database - a community created today has no UI of its own yet to view what it's
  ingested. Subdomain/custom-domain routing is designed for (`slug`/`custom_domain` are stored on each
  `Community` row) but not wired up: `*.opslabsystems.cloud` wildcard DNS doesn't currently resolve, so
  there'd be nothing to test against. This site's own production data was deliberately **not** migrated
  into a Community row in this pass - doing that before the browser-facing app is tenant-aware would make
  the live dashboard appear to lose its data.
- Requires a scoped MySQL account (`MYSQL_PROVISIONER_*` in `.env`) that can only create/manage
  `xonsight_*` databases - see the comment above those variables in `.env.example` for the exact grants.

A Flask website (Tailwind, dark theme) that receives evidence submitted by
players' bodycams in your FiveM server (via the Xon Sight resource's
outbound webhook) and gives you a searchable evidence gallery plus a
"who's recording right now" live page.

## What's new (2026-10-19, latest: public API docs, Discord, bodycam parity)

- **Public API reference at `/api-docs`** (linked from the homepage footer) - documents the webhook contract
  (`/evidence`, `/recorders/sync`, `/alerts`, `/external-feeds/sync`) for anyone integrating a bridge script,
  independent of this README.
- **Discord webhook notifications** (`/admin/settings`) - new evidence, emergency alerts, and published BOLOs can
  each post to a Discord channel webhook, with per-event toggles. One webhook URL for the whole deployment for
  now (not per-community yet - see the Roadmap note on the API docs page). Fire-and-forget: a slow/unreachable
  Discord webhook never blocks or fails the request that triggered it.
- **`opslabs-bodycam` brought up to full API parity**: sends `deviceSerial` on the evidence webhook (fills the
  Metadata tab automatically instead of needing a manual entry), fires `/alerts` on shots-fired/weapon-drawn,
  and pushes the live roster immediately on start/stop instead of only on the periodic timer - the Live page now
  reflects a new recorder within about a second. It also gained an opt-in chest-mounted camera mode
  (`Config.ChestCam`, ported from `Your-Spy/spy-bodycam`'s technique) for a true body-worn-camera perspective
  instead of following free-look - see that resource's own README for the real gameplay trade-off before turning
  it on.

## What this is / isn't

- **Evidence (video) ingestion is real and matches Xon Sight's documented
  contract.** Xon Sight POSTs a JSON webhook (`id`, `submitterIdentifier`,
  `submitterName`, `caption`, `videoUrl`, `createdAt`) to this site every
  time a player submits evidence in-game. This site stores it and displays
  the video (hosted wherever LB Phone's camera upload put it — Fivemanage,
  S3, etc. — this site never handles raw video bytes).
- **"Live view" here means "who is currently recording", not a live video
  stream.** Xon Sight itself has no live video stream to give a website —
  per its own docs, it records a camera *path* (position/rotation/FOV
  over time) and replays it as a scripted camera on another player's
  client in-game. There's no documented API for pushing that, or actual
  video frames, to an external site. The `/live` page here is built
  against a small extension endpoint (`POST /api/xonsight/recorders/sync`)
  you'd feed from a script on the FiveM side that polls
  `exports.XonSight:GetActiveRecorders()` every few seconds — see
  "Wiring up live recorders" below. If you don't wire that up, `/live`
  will just always show "No active recorders".

## What's new (2026-10-19, latest: homepage tip line + security pass)

- **A permanent, no-account tip line lives at `/report`** and is front and
  center on the public homepage (`/`) - a "Report evidence" button in the
  header plus its own section, separate from the per-case links described
  below. Seeded once automatically (`is_general` on `CommunityRequest`);
  it can be closed from `/community` like any other request, but not
  deleted. Officers still generate one-off per-case links from
  `/community` the same way as before (shared via Discord, the in-game
  phone, etc. - still no real email/SMS delivery).
- **Fixed an open-redirect vulnerability** in the login flow: `/login?next=`
  was passed straight to `redirect()` with no validation, so a crafted
  link (`?next=https://evil.example.com`) could bounce a victim to an
  attacker's site immediately after they authenticated. `next` is now
  validated as a same-site relative path before use.
- **Known gap, not yet addressed:** none of this app's POST forms/API
  calls carry CSRF tokens. Session-cookie auth without CSRF protection
  means a malicious page could, in principle, trigger state-changing
  requests (logout, password change, case status, admin actions) in a
  logged-in user's browser. Worth adding (e.g. Flask-WTF) before treating
  this as hardened against a hostile network, not just honest-mistake
  bugs.

## What's new (2026-10-19, later still: Community Request)

An Axon "Community Request" analog (`/community`) - an investigator asks
the public, or an in-game civilian with dashcam/doorbell footage, for
evidence or tips:

- **Create a request** with a title, category, public description, and
  optional instructions/case link. This generates a short reference code
  and a public link (`/r/<code>`) - **Xon Sight has no email/SMS delivery
  system like Axon App's "Send Invite,"** so there's no automated invite;
  you share the link yourself (Discord, the in-game phone, wherever
  reaches that person).
- **The public link needs no portal account.** A visitor can leave a
  message, a link to footage they already have hosted somewhere, and/or
  upload a photo or short video directly (stored under
  `instance/community_uploads/`, served back to investigators through an
  authenticated route - never exposed publicly). A consent checkbox
  ("may be used as evidence") is configurable per request, and there's a
  name/contact field with its own separate storage-consent toggle,
  mirroring Axon's "consent to store contact details."
- **Investigators review submissions** on the request's detail page -
  mark reviewed, close the request to stop taking new submissions, copy
  the link, or delete the whole thing.
- **Rate-limited and CAPTCHA-gated** (added 2026-10-19, same day): the
  public submission endpoint is capped at 8 POSTs/hour per visitor
  (Flask-Limiter), stacked with the honeypot field above and a CAPTCHA -
  a real hCaptcha widget if `HCAPTCHA_SITE_KEY`/`HCAPTCHA_SECRET_KEY` are
  set (free keys at hcaptcha.com), otherwise a built-in math challenge so
  there's still real bot resistance with zero external signup. The app
  now also applies Werkzeug's `ProxyFix` (trusting nginx as the one hop in
  front of it) so the per-visitor rate limit keys off the real client IP
  from `X-Forwarded-For` rather than nginx's own loopback address - without
  that, every visitor behind the reverse proxy would share one limit.

## What's new (2026-10-19, later same day: accounts + redesign)

- **Accounts are required now.** Every page except the new public welcome
  page (`/`) and the login/signup pages requires a logged-in session -
  including the JSON API (`/api/...`, unauthenticated calls get a 401).
  Webhook endpoints (`/api/xonsight/...`) are unaffected - they're still
  authenticated by the `X-XonSight-Key` header only, no session needed.
- **First boot creates one admin account** (`seed.py`) and writes its
  generated password to `instance/ADMIN_CREDENTIALS.txt` once - log in with
  it, then delete that file. Every evidence item that existed before
  accounts were added was attributed to this account (`Evidence.owner_id`);
  every item ingested afterward defaults to it too, since the webhook
  carries no portal login to attribute it to otherwise.
- **Signup policy is a runtime setting, not an env var** - `/admin/settings`
  (admin-only) lets each deployment choose: open signup, invite-code-gated
  signup (code set there, blank code = signups effectively closed), or an
  admin-approval queue (`/admin/users` to approve/disable/promote). There's
  no single right default across communities, so nothing is hardcoded.
- **New public welcome page** (`/`) with an animated OPS Phone → Xon Sight
  diagram and feature highlights - logged-in visitors are redirected
  straight to `/dashboard`.
- Visual pass across the app shell (branded mark, user menu, consistent
  focus/hover states) - page content itself is largely unchanged from the
  Axon-style update above.

## What's new (2026-10-19 Axon-style update)

The evidence viewer and Live page were rebuilt to mirror Axon Evidence /
Axon Respond's feature set, plus AI and records analogs (Draft One /
Brief One / Axon Assistant / Axon Fusus / Axon Records & Standards),
adapted honestly to what Xon Sight actually has:

- **Evidence viewer** (`/evidence/<id>`): custom player with scrub-bar
  hover thumbnails, frame-stepping, 0.25x-4x speed, brightness/contrast,
  burned-in metadata overlay (agency/officer/device serial/clock),
  markers + in/out clip bookmarks (not exported files - Xon Sight never
  has the raw bytes to cut), up to 4-camera multicam synced by capture
  time (not location - the webhook carries no incident/location id),
  per-camera audio toggle, case notes, and a manual transcript field
  (no speech-to-text service is wired up).
- **Live page** (`/live`, Axon Respond analog): a schematic pan/zoom grid
  of in-game world coordinates (not a real map - there's no real GPS),
  color-coded recorder markers (recording/buffering/stale), a roster
  sidebar with search and "Follow" (pans the map, doesn't move a video
  window - there's no live video to tether), and a flashing alert banner
  for emergency triggers.
- **Cases** (`/cases`): a lightweight records wrapper - groups evidence
  under a status (open/under review/closed) with an audit trail. This is
  an Axon Records & Standards analog in name only - no use-of-force
  review workflow, no compliance auditing beyond the status log.
- **Assistant** (`/assistant`, Axon Assistant analog): a Claude-powered
  chat over recent evidence/case/BOLO context, plus AI-assisted BOLO
  drafting (a human always clicks "Publish" - nothing posts itself).
  **Not CJIS-compliant or any other certified system** - that's a real
  audit this app hasn't gone through, and nothing here claims it.
- **Draft One / Brief One analogs** (in the evidence viewer's "AI tools"
  tab): draft a report narrative, or summarize + flag likely evidentiary
  milestones - both generated from the manual transcript/notes above,
  via the Claude API. Always meant for human review before use.
- **Axon Fusus analog**: `external_feeds` table + `/api/xonsight/external-
  feeds/sync` - an empty, extensible pin layer on the Live map for any
  future fixed camera/sensor/drone integration. Nothing feeds it today.

See "AI features" and "Wiring up alerts / external feeds" below for env
vars and webhook shapes.

## Project layout

```
xon-sight/
├── app.py                     # entry point
├── requirements.txt
├── .env.example
└── xonsight/
    ├── __init__.py             # app factory
    ├── config.py
    ├── extensions.py           # SQLAlchemy instance
    ├── migrations.py           # in-place ALTER TABLE for columns added after initial deploy
    ├── ai.py                   # Claude API wrapper for Draft One/Brief One/Assistant analogs
    ├── models.py               # Evidence, ActiveRecorder, CaseNote, Marker, Clip, Alert,
    │                           # ExternalFeed, Case/CaseEvidence/CaseAuditEntry, Draft, Brief, Bolo
    ├── webhooks.py             # POST /api/xonsight/evidence, /recorders/sync, /alerts, /external-feeds/sync
    ├── api.py                  # same-origin JSON used by the frontend JS (evidence, cases, AI, etc.)
    ├── views.py                # page routes: /, /evidence(+/<id>), /live, /cases(+/<id>), /assistant
    ├── templates/              # Tailwind (CDN) dark-theme templates
    └── static/                 # evidence-player.js, live-map.js, cases.js, case-detail.js, assistant.js, app.js
```

Evidence is stored in a local SQLite DB at `instance/xonsight.db` by
default (created automatically). Point `DATABASE_URL` at Postgres/MySQL/etc.
if you want something else.

## Setup

```bash
cd xon-sight
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# edit .env: set SECRET_KEY and XONSIGHT_WEBHOOK_KEY
```

Run it:

```bash
python app.py            # dev server on http://localhost:5000
# or, for production:
gunicorn -w 2 -b 0.0.0.0:5000 app:app
```

Put this behind a reverse proxy (nginx/Caddy) with TLS if it's reachable
from the internet — Xon Sight's webhook auth is just a shared header, so
you want HTTPS in front of it regardless.

## Wiring up Xon Sight

In `resources/XonSight/config.lua` on your FiveM server:

```lua
Config.Evidence = {
    webhookUrl = "https://your-site.example.com/api/xonsight/evidence",
    webhookApiKey = "the-same-value-as-XONSIGHT_WEBHOOK_KEY-in-.env",
}
```

Restart the resource. Test independently of the game with:

```bash
curl -X POST http://localhost:5000/api/xonsight/evidence \
  -H "Content-Type: application/json" \
  -H "X-XonSight-Key: your-shared-secret" \
  -d '{
    "id": 1,
    "submitterIdentifier": "TESTID123",
    "submitterName": "Test Officer",
    "caption": "Test evidence submission",
    "videoUrl": "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4",
    "createdAt": "2026-09-16T02:14:00Z"
  }'
```

Then check `/evidence` in the browser.

## Wiring up live recorders (optional)

Xon Sight doesn't ship a webhook for this — you build a tiny bridge
resource/script server-side that calls
`exports.XonSight:GetActiveRecorders()` (see the API doc's typical
integration example) every few seconds and forwards the result here:

```bash
curl -X POST http://localhost:5000/api/xonsight/recorders/sync \
  -H "Content-Type: application/json" \
  -H "X-XonSight-Key: your-shared-secret" \
  -d '{
    "recorders": [
      {"id": "1", "name": "Officer Doe", "job": "police", "startedAt": "2026-09-16T02:10:00Z"}
    ]
  }'
```

Send an empty `recorders` array (or nothing at all) once nobody is
recording — this endpoint replaces the whole roster on every call, it
does not append.

## Wiring up alerts / external feeds (optional)

Same pattern as recorders/sync — extension endpoints, nothing in Xon
Sight ships these:

```bash
# Emergency trigger banner on /live
curl -X POST http://localhost:5010/api/xonsight/alerts \
  -H "Content-Type: application/json" -H "X-XonSight-Key: your-shared-secret" \
  -d '{"recorderId": "1", "recorderName": "Officer Doe", "type": "weapon_drawn", "message": "Drew sidearm"}'

# External feed pins on /live (Axon Fusus analog) - full snapshot each call
curl -X POST http://localhost:5010/api/xonsight/external-feeds/sync \
  -H "Content-Type: application/json" -H "X-XonSight-Key: your-shared-secret" \
  -d '{"feeds": [{"id": "cam-1", "label": "Vinewood Blvd Cam", "kind": "camera", "status": "online", "position": {"x": 215.0, "y": -800.0}}]}'
```

## AI features (Draft One / Brief One / Axon Assistant analogs)

Set `ANTHROPIC_API_KEY` in `.env` (get one at
https://console.anthropic.com/ — this has a real per-request cost) to
enable:

- The evidence viewer's **AI tools** tab — draft a report narrative, or
  summarize + flag likely evidentiary milestones, from the manual
  transcript/case notes on that item.
- The **Assistant** page (`/assistant`) — chat over recent evidence/case/
  BOLO context, and AI-assisted BOLO drafting.

Leave it blank and these features show "not configured" in the UI
instead of erroring. `AGENCY_NAME` is shown in the video overlay and sent
along with AI requests — set it to your server's actual agency name.

None of this is CJIS-compliant or carries any other compliance
certification, and nothing in the UI claims otherwise. Every draft,
brief, or BOLO is meant for a human to review/edit; the portal never
submits or publishes anything on its own — publishing a BOLO always
needs an explicit "Publish" click.

## Notes / gotchas

- **`X-XonSight-Key` is optional**, matching Xon Sight's own design: if
  you leave `XONSIGHT_WEBHOOK_KEY` blank in `.env`, both webhook endpoints
  accept requests with no header check at all. Set it for anything
  internet-facing.
- **No retries.** Xon Sight's webhook is fire-and-forget; if this site is
  down when a player submits evidence, that submission never reaches it
  (it's still safe in Xon Sight's own `axonsight_evidence` table on the
  game server).
- **`id` isn't globally unique** if you ever aggregate more than one FiveM
  server into this site — the `remote_id` column here is unique per row,
  so you'd want to add a `server` field/column and dedupe on
  `(server, remote_id)` instead before doing that.
- Tailwind is loaded from the CDN (`cdn.tailwindcss.com`) for simplicity.
  Swap in a compiled Tailwind build (`npx tailwindcss ...`) before running
  this somewhere with real production traffic.
