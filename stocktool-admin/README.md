# StockTool Admin (frontend)

Pure frontend. **No database connection anywhere in this codebase** —
every page load, form submit, and search calls stocktool-api over HTTP.
See `adminapp/utils/api_client.py` — that module is the entire boundary
to the backend; nothing else talks to the network or a database.

## Deploy

```bash
cd stocktool-admin
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt

export SECRET_KEY="something-random"           # signs this app's own session cookie
export API_BASE_URL="http://127.0.0.1:5000"     # where stocktool-api is running
export PORT=8000

python run.py
```

`API_BASE_URL` is server-to-server (this app's Python backend calling the
API). Barcode `<img>` tags are loaded directly by the *browser*, so if
`API_BASE_URL` isn't reachable from users' browsers under that same
address (different reverse-proxy path, internal-only hostname, etc.), set
`API_PUBLIC_URL` separately to whatever address the browser *can* reach.

## How login works here

There's no user table in this app. `POST /login` forwards the
username/password straight to `stocktool-api`'s `/api/auth/login`, and the
JWT it returns is stashed in this app's own session cookie
(`session['api_token']`). Every subsequent request in
`adminapp/__init__.py`'s `before_request` hook calls the API's
`/api/auth/me` with that token to find out who's logged in and whether
they're still an admin — so a permission change made anywhere else in the
system takes effect on this session's very next page load, not whenever
an 8-hour token happens to expire.

## Known simplifications vs. the old direct-DB version

- **Dashboard**: simplified to match what `/api/reports/summary` returns
  (totals + 10 most recent audit entries) rather than the old version's
  low-stock item list / recent-checkouts table. Easy to extend — add
  fields to that API endpoint and this template — but I didn't want to
  guess at exactly what breakdown you want without checking first.
- **Audit log / tool history pagination**: real pagination now lives in
  the API (`page`/`per_page` params, 50/page) rather than
  Flask-SQLAlchemy's `.paginate()` being called directly in this app,
  since this app can't touch the DB to do that itself anymore.

## Structure

```
config.py                    API_BASE_URL / API_PUBLIC_URL / SECRET_KEY
adminapp/
  utils/api_client.py        the ONLY thing that makes HTTP calls
  utils/decorators.py        login_required / admin_required (checks g.current_user)
  utils/formatting.py        turns API's ISO datetime strings back into
                              real datetime objects so templates can keep
                              calling .strftime() like they always did
  routes/                    auth, dashboard, items, tools, projects,
                              admin (users), barcode, logs, settings
  templates/                 unchanged Flowbite-dark-theme templates from
                              before, patched to read flat API JSON shapes
                              instead of SQLAlchemy relationship objects
```
