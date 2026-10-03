# OpsLab Systems — Discord Bot

> **One roof. One team. One ticket system.**
> [web.opslabsystems.cloud](https://web.opslabsystems.cloud/)

A full Discord server builder + ticket system + live site watcher for OpsLab Systems.

---

## What it does

### 🏗️ One-command server build (`/setup-server`)
Creates a complete, professionally branded server:

- **20+ roles** in a clean hierarchy — Founder, Operations Director, Lead Engineer, specialist tags, client tiers, etc.
- **8 categories, 40+ channels** — Information, Client Portal, Web Dev, FiveM Dev, Hosting & Infrastructure, Community, Voice, and a private Staff Operations area.
- **Seeded content** — Welcome message, full rules embed, FAQ/knowledge base, services overview, and pricing/process explainer all posted automatically.

### 🎫 Pro ticket system
- Big embed panel with both a **dropdown** and **6 quick-action buttons** (one per service).
- Each ticket opens a **modal form** with service-specific intake questions.
- New channel auto-created with **per-service permissions** — only the user, staff, and the relevant specialist role can see it.
- Each ticket has **Claim / Transcript / Close** buttons.
- Close flow archives a **full text transcript** to `🗂️・ticket-archive` and DMs the user.
- Sequential ticket IDs (`#0001`, `#0002`, …).
- `/add-user` and `/remove-user` for staff to manage ticket participants.

### 📡 Live site watcher
Polls `web.opslabsystems.cloud` every 15 minutes (configurable). When the page changes:

- Posts a clean embed to `📡・site-updates`.
- Highlights **new headings/sections** detected.
- Includes the page title, meta description, and a direct link.
- Persists state to `data/site_state.json` so it survives restarts and won't double-post.
- Run `/site-check` to force a manual poll.

### Other touches
- Persistent views — buttons keep working after the bot restarts.
- Auto-role + welcome DM + public welcome message on join.
- Branded embeds throughout (configurable colours, logo, footer).
- Sensible defaults but everything is in `.env`.

---

## Service catalogue

| Emoji | Service               | What it covers                                 |
|-------|-----------------------|------------------------------------------------|
| 🌐    | Website Development   | Custom websites and updates                    |
| 🎮    | FiveM Development     | Scripts, maps, resources, and more             |
| 🛠️    | Tech Support          | Fix issues and get the help you need           |
| ☁️    | Hosting Support       | Reliable hosting solutions                     |
| ⚙️    | System Setup          | Setup and optimize your systems                |
| ✨    | General Enquiry       | Anything tech related                          |

---

## Setup

### 1. Create the Discord application
1. Go to <https://discord.com/developers/applications> → **New Application**.
2. Sidebar → **Bot** → **Reset Token** → copy it.
3. Under **Privileged Gateway Intents**, enable:
   - ✅ Server Members Intent
   - ✅ Message Content Intent
4. Sidebar → **OAuth2 → URL Generator** → tick **`bot`** + **`applications.commands`**.
5. Under **Bot Permissions**, give it **Administrator** (easiest for a setup bot), or at minimum:
   `Manage Channels`, `Manage Roles`, `Send Messages`, `Embed Links`, `Attach Files`,
   `Read Message History`, `Manage Messages`, `Use Application Commands`, `Mention Everyone`.
6. Copy the generated URL and invite the bot to your server.

### 2. Configure
```bash
cp .env.example .env
# edit .env — set DISCORD_TOKEN and GUILD_ID
```

To get your `GUILD_ID`: in Discord, **User Settings → Advanced → Developer Mode (on)**, then right-click your server icon → **Copy Server ID**.

### 3. Install + run
```bash
pip install -r requirements.txt
python bot.py
```

### 4. Build the server
In your Discord server, run:

```
/setup-server                 ← builds roles, categories, channels, seeds content
/post-ticket-panel #channel   ← drops the public ticket panel
/post-services    #channel    ← drops the services embed
```

Then drag the bot's role above all others in **Server Settings → Roles** so it can manage them.

---

## File structure

```
discord_setup_bot/
├── bot.py              ← everything: blueprint + commands + ticket system + site watcher
├── requirements.txt
├── .env.example        ← copy to .env and fill in
├── README.md
└── data/
    └── site_state.json ← auto-created; tracks site changes
```

---

## Slash commands

| Command              | Who           | Purpose                                                   |
|----------------------|---------------|-----------------------------------------------------------|
| `/setup-server`      | Admin         | Build the entire server. Idempotent — safe to re-run.     |
| `/post-ticket-panel` | Admin         | Publish the ticket panel.                                 |
| `/post-services`     | Admin         | Publish the services embed.                               |
| `/site-check`        | Admin         | Force a site check now.                                   |
| `/add-user`          | Staff         | Add a user to the current ticket.                         |
| `/remove-user`       | Staff         | Remove a user from the current ticket.                    |
| `/ping`              | Everyone      | Latency check.                                            |

Ticket controls (inside each ticket): **✋ Claim**, **📄 Transcript**, **🔒 Close**.

---

## Customising

All branding lives in `.env`:

| Variable                  | Default                                    | Purpose                                  |
|---------------------------|--------------------------------------------|------------------------------------------|
| `BRAND_NAME`              | `OpsLab Systems`                           | Used in embeds, footers, presence.       |
| `BRAND_TAGLINE`           | `One roof. One team. One ticket system.`   | Footer tagline.                          |
| `BRAND_URL`               | `https://web.opslabsystems.cloud/`         | Main site link in embeds.                |
| `BRAND_SERVICES_URL`      | `https://web.opslabsystems.cloud/#services`| Services anchor.                         |
| `BRAND_LOGO_URL`          | _(empty)_                                  | URL of your logo for embed thumbnails.   |
| `BRAND_ICON_URL`          | _(empty)_                                  | Small icon for embed footers.            |
| `BRAND_COLOUR`            | `0x4F46E5` (indigo)                        | Main embed colour.                       |
| `ACCENT_COLOUR`           | `0x10B981` (emerald)                       | Success / accent colour.                 |
| `DANGER_COLOUR`           | `0xEF4444` (red)                           | Danger / close colour.                   |
| `WARNING_COLOUR`          | `0xF59E0B` (amber)                         | Warnings.                                |
| `SITE_WATCH_ENABLED`      | `true`                                     | Turn the live watcher on/off.            |
| `SITE_WATCH_URL`          | `https://web.opslabsystems.cloud/`         | Page to monitor.                         |
| `SITE_WATCH_INTERVAL_MIN` | `15`                                       | Poll interval (min, minimum 5).          |
| `SITE_WATCH_CHANNEL`      | `📡・site-updates`                         | Where updates are posted.                |

To change the **server structure**, edit `ROLES` and `SERVER_STRUCTURE` near the top of `bot.py`. To change **ticket services and intake questions**, edit the `SERVICES` dict.

---

## Notes

- `/setup-server` is **idempotent**: re-running it won't duplicate existing roles, categories, or channels. It will fill in anything missing.
- The bot needs its role positioned **above** any role it has to assign (Discord limitation).
- The site watcher does its first poll **silently** to establish a baseline — it only posts when content actually changes after that.
- All buttons use `custom_id`s and persistent views, so they keep working after restarts.

---

Built for **OpsLab Systems** — _One roof. One team. One ticket system._
