# OpsLabs SaaS Platform

Multi-tenant SaaS platform: companies/individuals sign up, subscribe to plans, spend a
shared credits system gated per-feature, and can connect a custom domain. Full platform-
admin control over products, plans, pricing, users, companies, subscriptions, payments,
credits, domains, and feature grants.

Build plan and design rationale: see the plan this was built from — ask Claude to pull
up the session history, or read the phase summaries below.

## Status

All 7 planned phases are built and tested. What's tested for real vs. what still needs
your credentials:

| Phase | What | Status |
|---|---|---|
| 0–1 | Foundations, accounts, RBAC | Live, fully tested |
| 2 | Products, plans, manual assignment | Live, fully tested |
| 3 | Stripe billing (Checkout, Portal, webhooks) | Built, signature/idempotency logic tested — **needs your `STRIPE_SECRET_KEY`** to actually call Stripe |
| 4 | Credits system (ledger, spend, reconcile) | Live, fully tested incl. concurrency/idempotency |
| 5 | Custom domains (Cloudflare) | Built, logic tested with Cloudflare calls mocked — **needs your `CLOUDFLARE_API_TOKEN`/`CLOUDFLARE_ZONE_ID`** |
| 6 | Dashboard/admin polish, feature grants, audit log | Live, fully tested |
| 7 | OpsLabs Commission integration | Live, tested cross-service against the non-production Commission copy at `/root/opslabs-commission` |

Currently running on `127.0.0.1:6200` (exposed to `0.0.0.0:6200` behind `ufw` for quick
external access — **plain HTTP, no TLS**, meant to be temporary). Not yet behind nginx
or a real domain.

## Setup

```
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

Postgres database `opslabs_platform` / role `opslabs_platform` already exists on this
box. Connection string is in `.env` (`DATABASE_URL`).

```
export FLASK_APP=wsgi.py
./venv/bin/flask db upgrade      # apply migrations
./venv/bin/flask seed-admin      # create the first platform-admin from .env
```

## Configuration (`.env`)

Only bootstrap secrets live here — the things you need before the admin UI is even
reachable. Everything else (Stripe keys, Cloudflare token, products, plans, pricing,
per-company settings) is admin-editable from the running app instead.

- `FLASK_SECRET_KEY` — session signing key. Rotating it logs out every open session.
- `DATABASE_URL` — Postgres connection string.
- `SESSION_COOKIE_SECURE` — must be `1` once served over real TLS; `0` only for plain-HTTP local dev.
- `PLATFORM_ADMIN_EMAIL` / `PLATFORM_ADMIN_PASSWORD_HASH` — first admin login, created by `flask seed-admin`.
- `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` — blank disables billing entirely (routes return a friendly "not configured" message, never crash). Webhook secret comes from `stripe listen` while testing locally, or the Stripe Dashboard once there's a public HTTPS endpoint.
- `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ZONE_ID` / `CUSTOM_DOMAIN_CNAME_TARGET` — same pattern, blank disables custom domains.

## Scheduled jobs

Two systemd timers, installed and running:
- `opslabs-platform-reconcile.timer` (hourly) — safety net for missed/delayed Stripe renewal webhooks.
- `opslabs-platform-verify-domains.timer` (every 5 min) — polls pending custom domain verifications.

Check with `systemctl list-timers 'opslabs-platform*'`.

## Architecture notes worth knowing before touching the code

- **Every signup — solo or team — creates a `Company` row** (`is_personal=True` for solo). Every billing/credit/domain entity has a single real `company_id` FK — no polymorphic owner_type/owner_id. This was a deliberate fix during design; don't reintroduce polymorphic ownership.
- **Credits are never balance-assigned directly.** `app/billing/credits.py`'s `grant()`/`spend()`/`reset_to()` are the only things allowed to touch `CompanyCreditAccount.balance`, always via an atomic SQL-level update in the same transaction as the `CreditLedger` row that explains it. `spend()` can't overdraft (`WHERE balance >= amount` guard, verified by test). Idempotency for renewals/grants relies on a real DB unique constraint on `(company_id, source_type, source_event_id)`, not just an application-level check.
- **Webhook handlers commit exactly once**, at the end of `stripe_webhook()`, wrapping the handler call itself — not per-handler commits. A `IntegrityError` from a duplicate business-level effect (not just a duplicate event id) rolls back cleanly and reports success rather than erroring Stripe into an infinite retry loop.
- **Domain verification requires passing twice in a row** (`pending → verified → active`) before a domain is trusted, specifically to avoid promoting on one lucky check during DNS propagation flapping.
- **The OpsLabs Commission integration (`/api/v1`) fails open everywhere.** `platform_client.py` in the Commission app never raises, always has a short timeout, and caches the last good result — a platform outage must never block a real admin from managing real customer orders. Don't "fix" this to fail closed without a very deliberate reason.
- Every admin-mutating action should call `app/audit.py`'s `log()` right before its `db.session.commit()` (it rides along in the same commit, doesn't commit itself) — keep doing this for new admin actions so `/admin/activity` stays complete.

## Known gaps / deliberately deferred

- No CSRF tokens (same as the OpsLabs Commission app this was built alongside) — relying on `SESSION_COOKIE_SAMESITE=Lax`, which blocks cross-site POST in modern browsers but isn't defense in depth. Consider Flask-WTF's CSRF protection before this handles real money at scale.
- `Plan.usage_limits` (hard caps like seat limits) is stored but not enforced anywhere yet — only the credits system is actually metered. A `UsageCounter` table was scoped in the original design review but not built; add it if hard usage caps become a real requirement.
- No email delivery — team invite links are shown to the inviter to copy/send manually (no SMTP configured for this project).
- OpsLabs Commission integration targets the **non-production** copy at `/root/opslabs-commission`, not the live production app at `/root/cioda_commissions` — that's a deliberate choice given production risk, not an oversight.
