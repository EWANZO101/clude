# Personal Management Platform — Parts 1-8, plus a Part 10 pass

## What's in this build

### Part 1 — Core skeleton
Flask app factory, config, extensions. User/session/settings/dashboard-widget/
nav-item models. Auth (signup, login, logout, forgot/reset password, change
password, email verification token, session list/revoke, login history,
delete account). First-time setup wizard. Dashboard shell + widget
placeholders. Settings pages. Responsive dark Tailwind UI (desktop sidebar,
tablet, mobile bottom nav + drawer). Error pages, PWA manifest stub.

### Part 2 — Core systems
Permissions (roles/capabilities, single-user mode allows everything until
roles are configured). Event bus (in-process pub/sub + persisted event log;
core events: transaction.imported/updated/categorised, merchant.matched,
bill.upcoming, budget.exceeded, checklist.created, task.completed,
module.installed/updated/disabled). Notifications (in-app + email-stub
backend, per-kind preferences). Background jobs (DB-backed, runs
synchronously in-request — swap for a real queue/worker in production).
Scheduler (`run_due_scheduled_jobs()`). Global search registry + page.
Central file storage service (type-validated, UUID-named). Audit log
(writer + paginated viewer). System health page.

### Part 3 — Module system
Manifest-driven module install: ZIP upload → structural validation →
zip-slip-safe extraction → manifest.yaml parsing → core-compatibility check
→ dependency pip install → migrations (`db.create_all()` after importing the
module's models) → enable (dynamic blueprint import + nav/widget
registration). Enable/disable/uninstall (data kept unless explicitly
deleted). Per-module log viewer. Modules management page.
`module_template/my_module/` is a ready-to-copy skeleton, and
`scripts/package_module.py` validates + zips any module folder.

### Part 4 — Checklist module
Ships as a real installed module (`module_packages/checklist/`). Lists:
create/rename/delete/archive/duplicate. Tasks: subtasks, notes, tags,
priority, due date, estimated time, complete/reopen, search/filter/sort,
progress bar, CSV export. Generator (`generator.py`): rule-based, offline —
turns pasted text / rough requirements into a structured, editable task
list (compound-sentence splitting, category/priority/time-estimate
guessing). No external AI dependency; swappable for an AI-backed generator
later with the same output shape.

### Part 5 — Finance module (core)
Ships as a real installed module (`module_packages/finance/`). Decimal-safe
money (`money.py` — everything stored as integer minor units, never floats).
Accounts (multi-account, current/savings/credit card, opening balance,
default account). **Real Monzo OAuth bank connection** (`providers/monzo.py`):
full authorization-code flow against `https://api.monzo.com`, encrypted
token storage (`crypto.py`, Fernet — set `FINANCE_ENCRYPTION_KEY`),
automatic account creation with live account number/sort code and balance,
manual "Sync now" with refresh-token handling, and disconnect. Requires a
client registered at developers.monzo.com — see `.env.example`. Other UK
banks are listed on the "Add a bank" page as not-yet-supported rather than
faked; add any account manually (with sort code/account number if you
like) regardless of whether it's live-connected. CSV statement import:
auto-detects date/description/amount (or separate debit/credit) columns
from common UK bank export headers, previews parsed rows, flags duplicates
against existing transactions before import. Duplicate detection via a
description+date+amount+account hash, with same-batch collision handling
so two genuinely identical same-day purchases both import while
re-uploading the same file is still fully deduped. Transactions: edit,
categorise, split, tag, notes, ignore, mark-reviewed, delete. Rule-based
auto-categorisation (`categorize.py`) with default UK merchant keyword
rules; corrections are remembered as rules automatically.

### Part 6 — Finance module (extended)
Budgets: per-category monthly amount with spent/remaining/%-used, warning
threshold, and a linear month-end forecast. Bills: due-day/frequency,
mark-paid rolls the due date forward automatically. Subscriptions:
monthly/annual with monthly/annual cost totals. Recurring payment
detection (`calculations.py`): groups spending by normalised description +
exact amount across 2+ distinct months — fixed-amount charges (Netflix,
Spotify) get flagged; variable grocery-style spending correctly doesn't.
Planned purchases ("Things I Want To Buy") with the spec's exact safe-balance
formula: current money − upcoming bills − upcoming subscriptions − planned
purchases − minimum safe balance. Savings goals with progress bars and
add-funds. Money-saving suggestions (month-on-month comparison, active
subscription total) — clearly labelled as suggestions, not advice.
Financial calendar (month agenda view). Financial forecast (projected
month-end balance with a plain-English explanation of the basis). 12-month
income/spending/net history with a simple bar chart. Finance settings page
(default account, minimum safe balance, savings targets).

### Part 7 — Merchant module
Ships as a real installed module (`module_packages/merchant/`). Company →
Brand → Merchant → Location data model, Companies-House-shaped. UK company
sync interface (`companies_house.py`) — structural only, same pattern as the
Monzo provider: a documented no-op without a real API key rather than a
silent failure. 33-merchant seed directory across groceries, online
shopping, restaurants/fast food, delivery, fuel, streaming, utilities,
transport, and pharmacy, each with realistic statement-description aliases.
Matching pipeline (`matching.py`) runs the spec's exact stage order — exact
→ alias → normalised → identifier → MCC → fuzzy → user mapping → AI — with
identifier/MCC as structural pass-throughs (CSV imports don't supply
either) and AI intentionally left for Part 9. The merchant module talks to
the finance module only through the Part 2 event bus (subscribes to
`transaction.imported`), so neither module hard-imports the other; verified
end-to-end that importing a statement auto-matches Tesco/Netflix via alias
while leaving a salary payment correctly unmatched. User corrections
("always map this description to merchant") are remembered and verified to
auto-match identical future descriptions. Spending stats (today/week/
month/year/all-time), top merchants by period, 12-month per-merchant
history, and merchant search registered with the global search registry.
Degrades gracefully to a standalone directory (verified) if the Finance
module isn't installed.

### Part 8 — Fuel module
Ships as a real installed module (`module_packages/fuel/`). Vehicles
(multi-vehicle, make/model/year/registration/fuel type). Fuel entries
(date, odometer, litres, cost, full-tank flag, notes). MPG and
cost-per-mile via the standard fill-to-full method (`calculations.py`):
distance and litres/cost are summed across every entry between two
full-tank fills, converted through the UK gallon (4.54609 L) — verified
end-to-end against hand-calculated figures. Fuel spending stats
(today/week/month/year/all-time) reuse the merchant module's
fuel-station-brand merchants (Shell/BP/Esso, seeded in Part 7 with
merchant_type='fuel_station') rather than re-implementing matching —
`stats.py` just filters the same MerchantTransactionLink data Part 7
already produces. Verified end-to-end: importing a statement with a Shell
transaction auto-matches via the merchant module and shows up in fuel
spending stats with no fuel-module-specific matching code. Degrades
gracefully (vehicle/MPG tracking still works, spending stats show an
explanatory message) if Finance and/or Merchant aren't installed.

### Part 10 (partial) — backups, export, PWA, security/perf polish
Real SMTP email delivery (`app/core/email/service.py`) replacing the Part 2
console-log stub — configure `SMTP_HOST`/`SMTP_PORT`/`SMTP_USERNAME`/
`SMTP_PASSWORD`/`SMTP_FROM_ADDRESS`; falls back to logging if unset.
Rate limiting on signup/login/forgot-password/reset-password
(Flask-Limiter, in-memory — needs Redis for multi-worker deployments).
Backups (`app/core/backup/`): manual + daily-scheduled, zips the SQLite DB
+ module metadata + uploaded files; download/delete/history in the UI.
Restore extracts to `app.db.restored` rather than swapping the live DB
file live (doing that crashes a running process — verified during
testing) — stop the app, replace `app.db`, restart. Data export
(`app/core/export/`): a registry each module (checklist/finance/merchant/
fuel) registers a CSV/JSON exporter into, plus a one-click full-system ZIP.
PWA: real icons, install-to-home-screen prompt, a service worker caching
static assets and a narrow safe-page whitelist (dashboard/checklist/
notifications) — explicitly never caches or syncs anything under
/finance, /merchant, /fuel, /backups, /export. A scoped offline queue for
checklist task-completion toggles specifically, replayed on reconnect.
Finance transactions list now paginates properly instead of a hard
300-row cap; merchant/alias lookups are cached in-process with a 5-minute
TTL. See `REMAINING_WORK.txt` for what's still open in Part 9 and the
rest of Part 10.

## Moving to a real database (MySQL/Postgres)

SQLite is fine for local development, but it's a single file that lives
inside this app's own directory. If your deployment process ever replaces
that directory — a fresh `git pull` into a new release folder, unzipping
a new build over the old one, redeploying to a new path — the SQLite file
effectively resets, because there's a new empty one sitting at whatever
path `DATABASE_URL` resolves to now. This isn't a bug in the app; it's
what file-based storage does when the file's location isn't guaranteed
stable across deploys.

For any public/production deployment, use a real database server instead
— it's a separate, persistent process your app connects to over the
network, so redeploying the app's code can never touch its data.

```bash
# one-time setup — creates a MySQL database + user, prints the DATABASE_URL
bash setup_mysql.sh

# put the printed line in .env, e.g.:
# DATABASE_URL=mysql+pymysql://platform_user:...@localhost/platform?charset=utf8mb4

# then run the normal installer — it creates tables in the new DB,
# your existing SQLite data is untouched (nothing is migrated automatically)
bash install.sh
```

Postgres works the same way — set `DATABASE_URL=postgresql+psycopg2://...`
instead (the `psycopg2-binary` driver is already in `requirements.txt`);
there's no `setup_postgres.sh` yet, so create the database/user manually
with `createdb`/`createuser` or your hosting provider's dashboard.

Backups (see below) automatically use `mysqldump`/`pg_dump` when you're on
MySQL/Postgres, producing a real SQL dump inside the backup ZIP — install
the `mysql-client` (or `postgresql-client`) package on the server if
`mysqldump`/`pg_dump` isn't already available.

## Run it
```
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env

export FLASK_APP=run.py
flask init-db
flask seed-nav
flask install-builtin-modules   # packages + installs checklist, finance, merchant, fuel

python run.py
```
Visit http://localhost:5000/signup

Uses SQLite by default (`app.db`). Set `DATABASE_URL` in `.env` for Postgres.

## Packaging your own module
```
python scripts/package_module.py path/to/your_module dist/
```
Then upload the resulting ZIP from the in-app Modules page.

## Known simplifications (tracked, not bugs)
- Background jobs run synchronously in-request; no real worker/queue yet.
- Module blueprints can't be hot-unregistered by Flask — disabling a module
  hides its nav but a full unload needs an app restart.
- Module dependencies install into the current environment (no per-module
  venv isolation).
- Bank sync is live for Monzo only (real OAuth); other UK banks are listed
  but not yet wired to a real provider — add those accounts manually.
- FINANCE_ENCRYPTION_KEY must be set for bank connection tokens (refresh
  tokens especially) to survive an app restart — without it, a random key
  is generated each process start and you'll need to reconnect Monzo.
- Monzo's own terms restrict their developer API to your own account or a
  small set of accounts you explicitly allow — this isn't a general
  multi-tenant bank integration.
- CSV import only; OFX/QFX/PDF parsers are not yet implemented.
- Two identical transactions on the same statement (same date/amount/
  description) are disambiguated within one import batch, but a *third*
  party's identical purchase on the same day as yours would need richer
  source data (an external transaction ID) to tell apart with certainty.
- Financial calendar is a month agenda view only — day/week/year grid views
  aren't built yet.
- Recurring payment detection runs synchronously when the Recurring page
  loads rather than as a scheduled background job.
- Merchant logos are fallback initials only — no real logo images.
- Merchant identifier and MCC matching stages are structural pass-throughs;
  they need a data source that actually supplies those fields (CSV doesn't).
- Rate limiting and the merchant lookup cache use in-memory storage —
  single-process only; a multi-worker deployment needs Redis for both.
- Backup restore only handles SQLite, and extracts to `app.db.restored`
  rather than replacing the live DB file (which would need the app
  stopped first — see Part 10 notes above).
- Offline queueing covers checklist task-completion toggles only, not
  every possible offline mutation.
- Data export is CSV/JSON only; no PDF export yet.

See `REMAINING_WORK.txt` for everything still to build.

