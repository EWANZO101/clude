# ClientHub — Client Document & Project Manager

A simple, professional Flask app for keeping every client's documents, contracts,
projects, notes and files organised in one dedicated dashboard per client.

Includes a light/dark theme switch (Tailwind CSS, remembers your preference).

## Features

- **Login required** — every page and every action requires a signed-in
  account. Passwords are hashed with Werkzeug's `generate_password_hash`
  (salted, never stored in plain text).
- **Sign up** page to create accounts; optionally gate signup behind an
  invite code (see Security below).
- **CSRF protection** on every form (Flask-WTF `CSRFProtect`) — every POST
  request must carry a valid per-session token, or it's rejected with a 400.
- One dashboard per client, with all their information in one place
- Upload files into 12 built-in categories (documents, contracts, PDFs, Word
  files, project files, images/photos, videos, IT files, quotes/invoices,
  project information, completed work, other)
- Notes per client (pin important ones)
- Projects per client with status (Planning / Active / On Hold / Completed) and due dates
- Global search across clients, files, notes and projects
- Dashboard filter/search by client name, company or status
- Dark / light theme toggle (top right), saved in your browser
- Files are stored on disk under `uploads/<client_id>/<category>/`, indexed in a
  local SQLite database (`client_manager.db`) — no external services required

## Requirements

- Python 3.9+

## Setup

```bash
cd client_manager

# create a virtual environment (recommended)
python3 -m venv venv
source venv/bin/activate      # Windows: venv\Scripts\activate

# install dependencies
pip install -r requirements.txt

# run the app
python app.py
```

Then open **http://localhost:5000** in your browser.

The database and uploads folder are created automatically on first run.

## Project structure

```
client_manager/
├── app.py                 # Flask app & routes
├── models.py               # SQLAlchemy models (Client, FileItem, Note, Project)
├── requirements.txt
├── client_manager.db        # SQLite database (created on first run)
├── uploads/                 # Uploaded files, organised by client/category
├── static/
│   └── js/theme.js          # Dark/light theme toggle
└── templates/
    ├── base.html            # Layout, sidebar, topbar, theme setup
    ├── index.html           # Dashboard (all clients)
    ├── client_form.html     # New / edit client
    ├── client_detail.html   # Per-client dashboard (Overview/Files/Notes/Projects tabs)
    └── search_results.html  # Global search results
```

## Security

This app now includes authentication and CSRF protection, but a few things
are on **you** to set up properly before using it beyond your own laptop:

- **Set a real `SECRET_KEY`.** The app falls back to a dev key if you don't.
  Anyone who knows that key could forge sessions. Set it as an environment
  variable before running:
  ```bash
  export SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  ```
- **Restrict signup.** By default, anyone who can reach `/signup` can create
  an account and see every client's files. If you'll expose this beyond your
  own machine, set an invite code so only people you share it with can sign up:
  ```bash
  export SIGNUP_CODE="something-only-you-share"
  ```
  For a fully closed system, remove the public signup route entirely and
  create accounts yourself via a Python shell (`flask shell` or a small script
  using `User(...)` / `user.set_password(...)`).
- **Use HTTPS in production**, and set `SESSION_COOKIE_SECURE=true` once you
  do, so session cookies are never sent over plain HTTP:
  ```bash
  export SESSION_COOKIE_SECURE=true
  ```
- **Run behind a real WSGI server** for anything beyond local use — the built-in
  Flask dev server (`app.run(debug=True)`) is not hardened for production.
  Use `gunicorn app:app` (or similar) behind a reverse proxy (nginx/Caddy)
  that terminates TLS.
- **All logged-in users currently share one workspace** — every account can
  see every client, file, note and project. This suits a small team working
  from the same client base. If you need per-user access control (e.g. some
  staff should only see certain clients), that would need to be added — ask
  and it can be built in.
- Max upload size is set to 512MB per request in `app.py`
  (`MAX_CONTENT_LENGTH`) — adjust as needed.
- Back up the `client_manager.db` file and the `uploads/` folder together —
  the database stores account and metadata info; the actual files live on disk.

## Customising

- Colours: edit the `brand` palette in the `tailwind.config` block inside
  `templates/base.html`.
- Categories: edit the `CATEGORIES` list in `models.py` to add, rename or
  remove file categories.
