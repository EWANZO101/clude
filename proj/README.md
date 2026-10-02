# Claude Multi-Account Manager

Flask + Tailwind (dark mode default) web dashboard for managing multiple
Claude accounts/teams and their Claude Code CLI sessions from one place.

## Layout
- `app/` — Flask app (`app.py`, `config.py`, `models.py`, `session_manager.py`, templates, static)
- `install.sh` — provisions Ubuntu, venv, Tailwind build, systemd + nginx
- `wsgi.py` — entrypoint for gunicorn/manual runs
- `.env.example` — copy to `.env` for local/manual runs (install.sh generates its own on deploy)

## Deploy
```
sudo bash install.sh [install_dir] [domain] [port]
# defaults: /opt/claude-manager, no domain, 5057
```
Prints the generated admin username/password once at the end.

## Local dev
```
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # edit SECRET_KEY/ADMIN_PASS
npx tailwindcss -i app/static/css/input.css -o app/static/css/output.css --watch
cd app && flask --app app run --debug
```

## How sessions work
Each account gets its own `screen` session (`claude_acct_<id>`) running the
`claude` CLI in its configured project path, with an isolated
`CLAUDE_CONFIG_DIR` (and optional `ANTHROPIC_API_KEY`). Start/stop/status/log
are all driven from the dashboard — no manual terminal use needed day to day.

Install the `claude` CLI itself separately, then authenticate each account
once via `CLAUDE_CONFIG_DIR=<dir> claude login` (or set an API key in the
dashboard) before starting its session. You can also do this straight from
the dashboard: open an account's **Console**, hit **Start**, and once the
login URL/code prompt appears, paste the code back into the console's input
box — this works because the console can both view (`screen hardcopy`) and
type into (`screen -X stuff`) the live session.

## Running a session as a dedicated Linux user

By default every account is isolated only by its `CLAUDE_CONFIG_DIR`, all
running under the app's own service user. An account can instead run under
its own separate Linux user (its own home dir, its own OS-level file
permissions) by setting **Run session as** on the account form. This
requires two things set up ahead of time, once per target user:

1. The target user must exist and have `claude` on its `PATH` (a system-wide
   copy at `/usr/local/bin/claude` works for every user).
2. The app's service user needs a narrowly scoped, passwordless sudo rule
   letting it run `screen` (and nothing else) as that one user:
   ```
   # /etc/sudoers.d/claude-manager-<user>
   claude-manager ALL=(<user>) NOPASSWD: /usr/bin/screen
   ```
3. List the user in `ALLOWED_OS_USERS` in `.env` (comma-separated) — this is
   a second, application-level allowlist checked before any sudo call is
   made, so a stray/unexpected DB value can never reach sudo.

This keeps the blast radius of any one account's session contained to that
account's own Linux user — never root, never any other account.
