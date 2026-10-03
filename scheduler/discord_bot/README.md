# Scheduler Discord bot

Separate long-running process that DMs the admin about bookings. Talks to
the same database as the Flask app, but runs independently — it does not
need gunicorn, nginx, or the web app to be up (though obviously bookings
only happen if the web app is up).

Sends DMs for:
- **New booking** — as soon as the poll loop notices one
- **Cancellation**
- **Day-start digest** — one DM listing everything booked for today, sent
  once the date rolls over (or on the next poll if the bot was down at
  midnight)
- **1 hour before** each booking
- **15 minutes before** each booking
- **Spam ping** — for new bookings and out-of-hours bookings, keeps DMing
  every `DISCORD_PING_INTERVAL_SECONDS` (default 30) with a **Stop pings**
  button on the message. From the 2nd ping onward the previous ping is
  deleted right before the next one is sent, so only the latest is ever
  visible. It keeps going — no cap — until Stop is pressed, the booking
  is cancelled, or its start time arrives. Toggle it off entirely in
  Admin → Settings → Discord notifications.

All times are the admin's own timezone (Settings → Profile → Timezone).

## 1. Create the bot in Discord

1. https://discord.com/developers/applications → **New Application**
2. **Bot** tab → **Reset Token**, copy it → this is `DISCORD_BOT_TOKEN`
3. No privileged intents needed — it only sends DMs, never reads messages
4. **OAuth2 → URL Generator** → scope `bot`, no permissions needed → open
   the generated URL and add it to any server you're also in (Discord
   only lets a bot DM someone it shares a server with, or who has DM'd it
   first)

## 2. Get your Discord user ID

Discord app → Settings → Advanced → enable **Developer Mode**. Then
right-click your own name anywhere → **Copy User ID**. Paste that into
Admin → Settings → Discord notifications.

## 3. Configure

Add to `.env` (same file the Flask app uses):

```
DISCORD_BOT_TOKEN=<paste from step 1>
DISCORD_POLL_INTERVAL_SECONDS=60
DISCORD_APP_BASE_URL=https://scheduler.opslabsystems.cloud   # optional
DISCORD_PING_INTERVAL_SECONDS=30   # gap between spam pings
DISCORD_PING_CHECK_SECONDS=5       # how often the bot checks if a ping is due
```

## 4. Migrate and bootstrap

```
source venv/bin/activate
flask db upgrade
flask discord-bootstrap   # run once — stops the bot flooding you with
                           # "new booking" DMs for bookings that already existed
```

## 5. Run it

**Manually (to test):**

```
source venv/bin/activate
python -m discord_bot.bot
```

Then in Admin → Settings → Discord notifications, save your Discord user
ID and click **Send test DM**.

**As a systemd service** — copy `scheduler-discord-bot.service` below to
`/etc/systemd/system/`, adjusting `WorkingDirectory` and the venv path if
your deploy path isn't `/opt/scheduler`:

```ini
[Unit]
Description=Scheduler Discord notification bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/scheduler
EnvironmentFile=/opt/scheduler/.env
ExecStart=/opt/scheduler/venv/bin/python -m discord_bot.bot
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```
systemctl daemon-reload
systemctl enable --now scheduler-discord-bot
journalctl -u scheduler-discord-bot -f
```

## Redeploying

This is a live process, not something nginx serves — replacing the
files on disk does nothing until it's restarted:

```
systemctl restart scheduler-discord-bot
```

## Notes

- If `discord_user_id` is blank or "Send test DM" gives no result, check
  `journalctl -u scheduler-discord-bot` — a `discord.Forbidden` there
  means Discord is refusing the DM (not sharing a server / never DM'd
  the bot), not a bug.
- The bot and the gunicorn app share the same SQLite/Postgres database
  and the same `app/` models — no separate schema, no API between them.
- Every send-once action (new booking, cancellation, each reminder) is
  tracked by a boolean column on `Booking`, so a bot restart or a slow
  poll cycle never double-sends.
