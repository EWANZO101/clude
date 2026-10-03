# Ops Labs — Multi-Service Platform

**Build. Support. Scale. Together.**

A Flask web app + Discord bot for a multi-service community. Users open tickets on the website; the bot automatically opens a private Discord channel for each ticket; messages sync **both ways** with live refresh every 5 seconds.

## Features

- **Ticket system** — categories per company, priorities, statuses (open / pending / closed)
- **Discord bot integration** — auto-creates a private channel per ticket, mirrors all messages, slash commands (`/close`, `/reopen`)
- **Live refresh** — the ticket view polls every 5 seconds so messages from Discord appear on the web (and vice versa)
- **Admin panel** — manage users, roles (user/staff/admin), companies, categories
- **Password resets** — manual (admin sets password directly) or via emailed token link
- **Company builder** — add new companies offering services under Ops Labs, each with its own categories. The form-builder takes a simple `Name | Description` per line.
- **REST API v1** — full programmatic access with scoped API keys
- **Internal notes** — staff-only messages that don't get forwarded to Discord

## Quickstart

### 1. Install

```bash
cd opslabs
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # then edit
```

### 2. Run the site

```bash
python run.py
```

Visit `http://127.0.0.1:5000`. Default admin is `admin` / `admin` — **change this immediately**.

### 3. Run the Discord bot (separate terminal)

```bash
cd discord_bot
pip install -r requirements.txt
export DISCORD_TOKEN=...
export DISCORD_GUILD_ID=...
export BRIDGE_KEY=must-match-the-flask-DISCORD_BRIDGE_KEY
export WEB_URL=http://127.0.0.1:5000
python bot.py
```

The bot needs the **Message Content Intent** and **Server Members Intent** enabled in the Discord Developer Portal.

## Directory layout

```
opslabs/
├── app/
│   ├── __init__.py        # app factory + seed defaults
│   ├── models.py          # User, Company, TicketCategory, Ticket, TicketMessage, PasswordResetToken
│   ├── models_api.py      # ApiKey (REST API auth)
│   ├── routes/
│   │   ├── main.py        # home
│   │   ├── auth.py        # login, register, forgot/reset
│   │   ├── tickets.py     # create, view, reply, live poll, status
│   │   ├── admin.py       # users, companies, api keys, password resets
│   │   ├── bridge.py      # endpoints the BOT calls when Discord messages arrive
│   │   └── api.py         # public REST API v1
│   ├── templates/         # Jinja templates (base, auth/, admin/, tickets/)
│   └── static/css/main.css
├── discord_bot/
│   ├── bot.py             # the bot + internal aiohttp HTTP server
│   └── requirements.txt
├── instance/              # SQLite DB lives here
├── run.py
├── requirements.txt
└── .env.example
```

## How the Discord ↔ Web bridge works

```
   ┌────────────┐    POST /discord/ticket/create     ┌────────────┐
   │  Flask     │ ─────────────────────────────────▶ │  Bot HTTP  │
   │  /tickets/ │ ◀───────────────────────────────── │  :5005     │
   └────────────┘       returns channel_id           └────────────┘
        ▲                                                  │
        │ POST /bridge/discord/message                     │ creates channel
        │ (when Discord user posts)                        │ sends embeds
        │                                                  ▼
   ┌────────────┐                                  ┌────────────┐
   │  Flask     │                                  │  Discord   │
   │  /bridge/  │                                  │  channel   │
   └────────────┘                                  └────────────┘
```

Both sides share the **`DISCORD_BRIDGE_KEY`** as a secret in the `X-Bridge-Key` header.

The web client polls `/tickets/<id>/poll?since_id=N` every 5 seconds. Bot-relayed messages get inserted into the DB, so the next poll picks them up.

## REST API v1

### Authentication

Create a key in **Admin → API Keys**. The raw key is shown once — copy it.

Send the key as:

```
Authorization: Bearer ops_xxxxxxxxxxxx
```
or
```
X-API-Key: ops_xxxxxxxxxxxx
```

Scopes (hierarchy: `admin` > `write` > `read`):

| Scope | Can do |
|-------|--------|
| `read`  | list, get, poll |
| `write` | create / update tickets and messages |
| `admin` | full control — users, companies, deletions |

### Health & identity

```bash
curl http://localhost:5000/api/v1/health
curl -H "Authorization: Bearer $KEY" http://localhost:5000/api/v1/me
```

### Companies

```bash
GET    /api/v1/companies                # list (read)
POST   /api/v1/companies                # create (admin)
GET    /api/v1/companies/<id>           # one
PATCH  /api/v1/companies/<id>           # update (admin)
DELETE /api/v1/companies/<id>           # delete (admin)

GET    /api/v1/companies/<id>/categories
POST   /api/v1/companies/<id>/categories
```

Example:

```bash
curl -X POST http://localhost:5000/api/v1/companies \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"PixelForge","slug":"pixelforge","tagline":"Game UI specialists","accent_color":"#ff6b35"}'
```

### Users (admin scope)

```bash
GET    /api/v1/users?q=alice&role=staff&limit=50
POST   /api/v1/users    { username, email, password, role }
GET    /api/v1/users/<id>
PATCH  /api/v1/users/<id>
DELETE /api/v1/users/<id>
POST   /api/v1/users/<id>/reset-password   { mode: "manual", password: "..." }
POST   /api/v1/users/<id>/reset-password   { mode: "token" }   # returns reset token
```

### Tickets

```bash
GET    /api/v1/tickets?status=open&company_id=1&limit=50&offset=0
POST   /api/v1/tickets
  {
    "user_id": 5,
    "company_id": 1,
    "category_id": 3,
    "subject": "Site is down",
    "body": "Started 5 mins ago",
    "priority": "urgent"
  }
GET    /api/v1/tickets/<id>
PATCH  /api/v1/tickets/<id>     # { status, priority, assigned_to_id, category_id, subject }
DELETE /api/v1/tickets/<id>     # admin only

GET    /api/v1/tickets/<id>/messages?since_id=42&include_internal=1
POST   /api/v1/tickets/<id>/messages
  { "body": "Working on it", "user_id": 2, "is_internal": false }
```

When you create a ticket via the API, the bot is told to open a Discord channel — same flow as the web form.

### Error format

```json
{ "error": "human readable message", "code": "snake_case_code" }
```

Common codes: `missing_key`, `invalid_key`, `insufficient_scope`, `validation`, `not_found`, `duplicate`, `closed`.

## Adding a new company (the form builder)

Admin → Companies → **+ New Company**:

- **Name / Slug** — slug used in URLs
- **Tagline / Description** — shown on the homepage
- **Accent color** — for future per-company theming
- **Categories** — one per line, in the format `Name | Description`. Saving replaces all existing categories.

Or via API:

```bash
curl -X POST http://localhost:5000/api/v1/companies \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"NeonHost","slug":"neonhost","tagline":"VPS for FiveM"}'

curl -X POST http://localhost:5000/api/v1/companies/2/categories \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"VPS issue","description":"Server unreachable"}'
```

## Production notes

- Set `SECRET_KEY`, `DISCORD_BRIDGE_KEY` to long random strings.
- Use a real DB (`DATABASE_URL=postgresql://...`) and Gunicorn behind nginx:
  ```
  gunicorn -w 4 -b 127.0.0.1:5000 'app:create_app()'
  ```
- Run the bot as a systemd service (similar to your existing CFRP setup):
  ```ini
  [Unit]
  Description=Ops Labs Discord bot
  After=network.target

  [Service]
  WorkingDirectory=/opt/opslabs/discord_bot
  EnvironmentFile=/opt/opslabs/discord_bot/.env
  ExecStart=/opt/opslabs/discord_bot/venv/bin/python bot.py
  Restart=on-failure

  [Install]
  WantedBy=multi-user.target
  ```
- For SMTP password resets: set `MAIL_USERNAME` / `MAIL_PASSWORD`. If blank, links are logged to the console (fine for dev).

## Default credentials

- **Admin user:** `admin` / `admin` — change immediately after first login.

## License

MIT — do whatever, just don't blame us when it breaks. 🛠️
