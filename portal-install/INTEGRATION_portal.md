# OpsLab Systems — Portal Expansion (Phase 1)

This adds a customer **portal** on top of your existing app: dashboard, projects
with progress tracking + timeline, appointments (Europe/London, 24h, conflict
detection), invoices with Stripe checkout, an in-app notification centre, plus
the full data layer + 5-role RBAC for everything in the spec. Built on plain
Flask, your existing Flask-Login auth, and the Flowbite dark theme.

---

## What's included and working (verified end-to-end)

- **Data layer** — `app/models_business.py`: Service, Project (+milestones,
  timeline events), Appointment (+working hours, blackout dates), Invoice
  (+line items, payments), ShopCategory/ShopProduct, Notification, AuditLog,
  StoredFile, UserProfile, LoginEvent, plus schema for KbArticle, Message,
  Announcement, Review (UIs land in later phases). Money is stored as integer
  **cents**.
- **RBAC** — `app/rbac.py`: `super_admin > admin > staff > support > customer`,
  backward compatible with your existing `"admin"`/`"user"`/`"staff"` values.
  Decorators `@require_role`, `@require_permission`.
- **Portal** — `app/portal/`: 15 routes under `/portal` + `/billing/webhook`.
  Customer dashboard, project create/view + visual timeline + progress bar,
  staff stage/percent/assignment controls, appointment booking with live slot
  generation and conflict detection, invoice list/detail + Stripe pay button,
  notification centre.
- **Stripe** — `app/billing.py`: checkout sessions + webhook handler. No-ops
  cleanly until you set keys, so the rest runs without Stripe.
- **A required auth fix** — see the note at the bottom.

## Files

**New:** `app/models_business.py`, `app/rbac.py`, `app/billing.py`,
`app/portal/__init__.py`, `app/portal/routes.py`,
`app/templates/portal/*.html` (10 templates).

**Edited:** `app/__init__.py` (register models + blueprints + Stripe/timezone
config + login-manager fix), `app/templates/base.html` (Dashboard nav link),
`requirements.txt`.

---

## Install

```bash
cd /opt/opslabs            # your deploy path
source .venv/bin/activate  # if you use one
pip install -r requirements.txt
```

## Move to PostgreSQL

1. Create the DB and user:
   ```bash
   sudo -u postgres psql -c "CREATE USER opslabs WITH PASSWORD 'CHANGE_ME';"
   sudo -u postgres psql -c "CREATE DATABASE opslabs OWNER opslabs;"
   ```
2. Point the app at it (add to your `.env` / systemd unit):
   ```
   DATABASE_URL=postgresql+psycopg2://opslabs:CHANGE_ME@127.0.0.1:5432/opslabs
   ```
   Leave `DATABASE_URL` unset and it falls back to the existing SQLite file —
   handy for local dev. **Schema is identical either way.**

The app still calls `db.create_all()` on boot, so tables are created
automatically. If you'd rather use real migrations (recommended for prod):

```bash
export FLASK_APP=wsgi.py        # or run.py — whatever your entrypoint is
flask db migrate -m "portal expansion"
flask db upgrade
```

## Stripe (optional — pay buttons stay disabled until set)

Add to `.env`:
```
STRIPE_SECRET_KEY=sk_live_...
STRIPE_PUBLISHABLE_KEY=pk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
DISPLAY_TIMEZONE=Europe/London
```
Then register the webhook in the Stripe dashboard:
`https://web.opslabsystems.cloud/billing/webhook`
(events: `checkout.session.completed`, `invoice.paid`,
`customer.subscription.deleted`).

## Restart

```bash
systemctl restart opslabs-app.service
```

Then sign in and open **/portal**. The new **Dashboard** link is in the nav for
logged-in users.

---

## Required auth fix (read this)

While testing I found a pre-existing issue that blocks the portal **and already
breaks `/tickets` and `/admin` in a clean build**: the License Manager's
`_setup_independent_login()` calls `lic_lm.init_app(app)` last, which makes its
`AdminUser`-only loader the app-wide Flask-Login manager. That shadows the
scope-aware wrapper it installs on your main manager, so `current_user` comes
back anonymous on every non-`/licenses` page.

The fix is already applied in the edited `app/__init__.py`: right after
`licenses.register(app)` it re-asserts your OpsLabs manager as active and adds a
scoped `unauthorized_handler` so `/licenses/*` still redirects to the licenses
login. Verified: `/tickets`, `/admin`, `/portal` all authenticate; `/licenses`
admin still gates to `/licenses/auth/login`. If your production somehow relies
on `lic_lm` being the global manager, remove those lines — but in this codebase
as shipped, the app needs them.

---

## Deferred to later phases (schema is already in place)

E-commerce storefront/cart + product admin, Stripe subscriptions UI + customer
billing portal, PDF invoices, file uploads + ClamAV virus scanning, knowledge
base, internal messaging, reviews, announcement management UI, real-time
activity feed, and Celery/Redis background jobs (email/PDF/webhook retries).
Each builds on the models and RBAC shipped here.
