# Moto Service History

Flask + Tailwind (dark theme) digital motorcycle service book. Standalone project — not part of MotoGuard.

## Features
- Accounts, multiple motorcycle profiles per user
- Service/maintenance records, modifications & upgrades, parts-purchased-not-fitted (with "mark as fitted" → moves into mod history), accident history
- Photo & document uploads per motorcycle and per record (receipts, invoices, MOT docs, etc.)
- Unified chronological timeline across every record type
- DVSA MOT History API integration — admin-configurable credentials, no code changes needed (Admin > MOT API settings)
- Shareable public link per motorcycle with owner-controlled field visibility, for use when selling
- Admin area: users (create/disable/promote/delete/reset password), MOT API + app settings, API error logs, motorcycle oversight

## Local dev
```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # edit SECRET_KEY at minimum
python run.py           # http://localhost:5050
```

First boot creates a default admin: `admin` / `changeme123` (override with `DEFAULT_ADMIN_PASSWORD` env var before first run). **Change this immediately.**

## MOT API setup
DVSA's MOT History API needs an OAuth2 client-credentials app registration (client id/secret, token URL, scope URL) plus a subscription API key. Register at https://documentation.history.mot.api.gov.uk/ and enter the values under **Admin > MOT API settings** once the app is running — no redeploy required.

## Tests
```bash
pip install -r requirements.txt   # includes pytest
pytest -q
```
27 tests cover auth, ownership boundaries, service/mod/accident records, the parts-in-stock → fitted workflow, public share visibility rules, admin actions, and the DVSA client's error handling (network calls are mocked — no real credentials needed to run tests).

## Database migrations
Schema is created automatically on first boot (`db.create_all()`), and an initial Alembic migration is included in `migrations/` and stamped as the baseline. For future schema changes:
```bash
export FLASK_APP=run.py
flask db migrate -m "describe the change"
flask db upgrade
```

## Rate limiting
Login and registration are rate-limited (Flask-Limiter, in-memory backend). In-memory limits are per-worker — fine for the default single small deployment, but if you run gunicorn with multiple workers behind heavy traffic, point `Limiter` at Redis instead (see Flask-Limiter docs) for limits shared across workers.

## Deploy
```bash
sudo bash deploy.sh service.opslabsystems.cloud
```
Sets up a venv, gunicorn behind systemd (`moto-service-history.service`), and an nginx reverse-proxy vhost on the given domain. Run `certbot --nginx -d <domain>` afterwards for HTTPS. Uploaded files persist in `instance/uploads/` — back this up.

## Structure
```
app/
  models.py            All entities (User, Motorcycle, ServiceRecord, Modification,
                        PartNotFitted, Accident, MOTRecord, AppSetting, ApiLog, ...)
  auth/                Register/login/account (rate-limited)
  motorcycles/          Profile + all record-type CRUD, sharing, MOT lookup
  mot/dvsa.py           DVSA MOT History API client
  admin/                Users, settings, logs
  public/               Token-based public share pages
  templates/            Dark theme Tailwind (CDN) templates, incl. error pages
tests/                  pytest suite (27 tests, network calls mocked)
migrations/             Alembic migrations (baseline included)
```
