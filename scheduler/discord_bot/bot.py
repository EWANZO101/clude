"""Entrypoint for the Scheduler Discord notification bot.

Run it as its own long-running process, separate from gunicorn:

    python -m discord_bot.bot

(from the project root, with the venv active and DISCORD_BOT_TOKEN set —
see discord_bot/README.md for the systemd unit.)

It logs in, then polls the database every POLL_INTERVAL_SECONDS (default
60) for anything that needs a DM: new bookings, cancellations, the
day-start digest, and the 1-hour / 15-minute reminders. See notifier.py
for the actual logic.
"""

import logging
import os
import sys

# So `python discord_bot/bot.py` works too, not just `python -m discord_bot.bot`.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import discord
from discord.ext import tasks
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("discord_bot")

TOKEN = os.environ.get("DISCORD_BOT_TOKEN")
POLL_INTERVAL_SECONDS = int(os.environ.get("DISCORD_POLL_INTERVAL_SECONDS", "60"))
FLASK_ENV = os.environ.get("FLASK_ENV", "production")

if not TOKEN:
    logger.error("DISCORD_BOT_TOKEN is not set (check your .env). Exiting.")
    sys.exit(1)

from app import create_app  # noqa: E402 - needs sys.path fixed up first
from discord_bot import views  # noqa: E402
from discord_bot.notifier import poll, resume_active_ping_views, run_ping_tick  # noqa: E402

app = create_app(FLASK_ENV)
views.flask_app = app

intents = discord.Intents.default()
client = discord.Client(intents=intents)

PING_CHECK_SECONDS = int(os.environ.get("DISCORD_PING_CHECK_SECONDS", "5"))


@tasks.loop(seconds=POLL_INTERVAL_SECONDS)
async def poll_loop():
    await poll(app, client)


@tasks.loop(seconds=PING_CHECK_SECONDS)
async def ping_loop():
    await run_ping_tick(app, client)


@poll_loop.before_loop
async def before_poll_loop():
    await client.wait_until_ready()


@ping_loop.before_loop
async def before_ping_loop():
    await client.wait_until_ready()


@client.event
async def on_ready():
    logger.info("Logged in as %s (id=%s). Polling every %ss, pings checked every %ss.",
                client.user, client.user.id, POLL_INTERVAL_SECONDS, PING_CHECK_SECONDS)
    await resume_active_ping_views(app, client)
    if not poll_loop.is_running():
        poll_loop.start()
    if not ping_loop.is_running():
        ping_loop.start()


def main():
    client.run(TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
