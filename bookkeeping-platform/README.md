# Bookkeeping Platform — Phase 1: Foundation

This is Phase 1 of a multi-phase build. It contains a real, runnable Flask
application (not a mockup) implementing:

- Application factory + blueprint architecture (`app/`)
- User accounts (register/login/logout, hashed passwords, Flask-Login)
- Multiple businesses per user, with strict per-business membership/roles
  (owner, admin, accountant, bookkeeper, manager, employee, read-only)
- A real double-entry accounting engine (`app/accounting/engine.py`):
  every posting goes through `post_journal_entry`, which enforces that
  debits == credits and that accounts belong to the business being posted
  to. Nothing bypasses this.
- A default chart of accounts created for every new business
- A trial balance report
- Tailwind UI with light/dark theme (persisted via localStorage, respects
  system preference on first load)
- Automated tests for the accounting engine and auth/business isolation

## Running it

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # edit SECRET_KEY for anything beyond local dev
python scripts/init_db.py   # creates instance/app.db
python run.py                # http://127.0.0.1:5000
```

Or with Flask-Migrate instead of the dev-convenience script:

```bash
flask db init
flask db migrate -m "initial schema"
flask db upgrade
```

## Running tests

```bash
pytest
```

## UI overhaul v2 (dark-first, premium polish)

Run `build_ui_overhaul_v2.sh` after `build_ui_overhaul.sh`. Makes dark the default first-visit theme, replaces every emoji (🌓 🔔 ☰) with a real inline SVG icon set (`app/templates/_icons.html`) including one icon per sidebar item, adds layered elevation (three surface levels, shadows tuned separately for light vs. dark so dark-mode cards get a faint inner top-highlight instead of reading flat), a subtle fixed ambient gradient behind the app shell in dark mode, buttons with real depth, and a proper avatar + dropdown menu in place of a bare Logout link. The dashboard is hand-rebuilt with icon stat cards. 34/34 tests still pass, and all 35 routes in the app were swept again to confirm nothing broke.

## What's intentionally NOT in Phase 1

This phase is the foundation only: auth, businesses, roles, the accounting
core, and a minimal UI. Invoicing, expenses, banking, PWA/offline, backups,
audit trail, reporting suite, and integrations are separate phases, built on
top of this same engine so the accounting core never has to be rewritten.
