# StockTool API

The only piece of this system that touches a database. Owns all models,
all business logic (auth, barcode generation, audit logging, stock math),
exposes a full REST API, and also serves the shop-floor kiosk touch-UI
(same process, direct DB access, plain cookie session — separate from the
JWT-based REST API used by the admin frontend).

## Deploy

```bash
cd stocktool-api
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt

export SECRET_KEY="something-random"
export JWT_SECRET_KEY="something-else-random"
export KIOSK_NAME="kiosk-1"        # only matters if you open /kiosk/ on this box
export PORT=5000

python scripts/init_db.py          # creates tables + first admin, interactive
python run.py
```

Remember: `/opt/`, not `/root/` — nginx (www-data) can't traverse a
mode-700 home directory, same issue as every other app on swift1.

## What's here

- `app/models/` — User, Item, Tool, Project, Barcode, ToolHistory,
  AuditLog, Settings. Single source of truth; nothing else in this whole
  system defines its own copy of the schema.
- `app/api/` — REST blueprints: `auth`, `users`, `items`, `tools`,
  `projects`, `barcodes`, `audit` (logs + reports), `settings`. All
  JSON, all JWT-protected except login and the barcode image endpoint.
- `app/kiosk/` — the touch-screen UI from Phase 1, now living inside this
  app instead of a separate codebase, since it needs direct DB access
  anyway.
- `app/utils/audit.py`, `app/utils/barcode_helper.py` — the business
  logic every route calls into, so behavior can't drift between endpoints.

## Auth model

- Admin frontend: `POST /api/auth/login` (username/password) → 8h JWT.
- Kiosk / badge scan: `POST /api/auth/kiosk-login` (barcode code) → short
  JWT, expiry configurable via `PUT /api/settings/` →
  `kiosk_token_expires_minutes`.
- Every protected endpoint re-loads the user from the DB on each request
  (see `jwt.user_lookup_loader` in `app/__init__.py`) rather than trusting
  the role baked into the token, so a demotion/deactivation takes effect
  immediately instead of waiting out the token's lifetime.
- Logout is a logged event only — tokens are stateless, there's no
  server-side revocation list. Acceptable for an internal tool given how
  short-lived the tokens are; flag it if that ever needs to change.

## Barcode images

`GET /api/barcodes/image/<code>` is deliberately NOT JWT-protected — the
admin frontend's `<img>` tags load straight from it, and a printed barcode
is already physically accessible to anyone near it anyway.

## Not yet built

- Phase 2 (mobile phone as a backup scanner, QR-paired to a kiosk session)
- Token revocation / blocklist for logout
