# GSRP Whitelist System

A full-featured Flask whitelist application for FiveM servers with Discord integration, analytics, and an admin panel.

## Features

- **Auth**: Login, register, 2FA (TOTP), password management
- **Discord OAuth2**: Connect accounts, auto-join guild, role sync
- **Applications**: Dynamic form builder, multi-type support, cooldowns
- **Admin Panel**: User management, role assignment, application review, webhook builder
- **API**: Full REST API with API key auth and scopes
- **Analytics**: Live player tracking, playtime leaderboard, kill feed, crash diagnostics, economy overview
- **Webhooks**: Discord webhook builder with per-event triggers and embed customization
- **FiveM Integration**: Heartbeat system, kill/death tracking, session logging

---

## Quick Start

### 1. Clone & Install

```bash
pip install -r requirements.txt
```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env with your Discord app credentials, bot token, etc.
```

### 3. Set Up Discord Application

1. Go to https://discord.com/developers/applications
2. Create a new application
3. Under **OAuth2**: add redirect URI → `http://localhost:5000/auth/discord/callback`
4. Copy **Client ID** and **Client Secret** → paste into `.env`
5. Under **Bot**: create a bot, copy token → `DISCORD_BOT_TOKEN` in `.env`
6. Invite bot to your server with `Manage Roles` + `Manage Members` permissions

### 4. Run the App

```bash
python run.py
```

### 5. Create Admin User

```bash
python create_admin.py
```

---

## FiveM Integration

Place the resources from `ewanapi/` in your FiveM server's resources folder.

### cfrp_playtime

Edit `config.lua` and set:
```lua
local API_URL = "https://your-domain.com/api/server/heartbeat"
local API_KEY = "your_fivem_api_key_from_env"
```

Add to `server.cfg`:
```
ensure cfrp_playtime
ensure cfrp_stats
```

### cfrp_stats

Sends kill/death events to `/api/server/stats`. Uses the same API key.

---

## API Reference

Base URL: `/api`  
Auth: `X-API-Key: your_key` header, `Authorization: Bearer <key>`, `Authorization: ApiKey <key>`, or `?api_key=` query param

| Endpoint | Method | Scope | Description |
|---|---|---|---|
| `/api/health` | GET | — | Health check |
| `/api/analytics/live` | GET | read | Live player count |
| `/api/analytics/summary` | GET | read | Server summary |
| `/api/analytics/leaderboard` | GET | read | Playtime leaderboard |
| `/api/analytics/killfeed` | GET | read | Recent kills |
| `/api/analytics/crashes` | GET | read | Crash/disconnect stats |
| `/api/applications` | GET | read | List applications |
| `/api/applications/:id` | GET | read | Get application |
| `/api/applications/:id/status` | PATCH | write | Update status |
| `/api/users` | GET | admin | List users |
| `/api/users/:id` | GET | read | Get user |
| `/api/users/discord/:id` | GET | read | Get by Discord ID |
| `/api/users/:id/sync-discord` | POST | admin | Sync Discord roles |
| `/api/users/:id/roles` | POST | admin | Assign/remove role |
| `/api/roles` | GET | read | List roles |
| `/api/webhooks/trigger` | POST | write | Trigger webhook |
| `/api/server/heartbeat` | POST | write | FiveM heartbeat |
| `/api/server/disconnect` | POST | write | FiveM disconnect |
| `/api/server/stats` | POST | write | FiveM kill/death |
| `/api/docs` | GET | — | API docs JSON |

### Example: Discord bot pulling application data

```python
import requests

headers = {"X-API-Key": "your_api_key"}
r = requests.get("https://your-site.com/api/applications?status=pending", headers=headers)
apps = r.json()["applications"]

for app in apps:
    print(f"{app['user']['username']} applied for {app['type']['name']}")
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `SECRET_KEY` | Flask secret key |
| `DATABASE_URL` | SQLite or PostgreSQL URL |
| `DISCORD_CLIENT_ID` | Discord OAuth2 client ID |
| `DISCORD_CLIENT_SECRET` | Discord OAuth2 client secret |
| `DISCORD_REDIRECT_URI` | OAuth2 callback URL |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `DISCORD_GUILD_ID` | Your Discord server ID (1213807920635052043) |
| `FIVEM_API_KEY` | API key used by FiveM resources |

---

## Production Deployment

```bash
# Use gunicorn
gunicorn -w 4 -b 0.0.0.0:5000 "app:create_app()"

# Or with PostgreSQL
DATABASE_URL=postgresql://user:pass@localhost/whitelist python run.py
```

Use **nginx** as a reverse proxy and set `SESSION_COOKIE_SECURE=True`.

---

## Discord Guild ID

This system is pre-configured for guild: **1213807920635052043**
