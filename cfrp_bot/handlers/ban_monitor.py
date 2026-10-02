"""
BanMonitor — polls the QBCore bans table every 30 seconds.
When a new ban is detected it DMs the banned Discord user.

Required .env keys:
  QBCORE_DB_HOST     — MySQL host (often same as cfrp_bot DB host)
  QBCORE_DB_PORT     — MySQL port (default 3306)
  QBCORE_DB_NAME     — database name  (e.g. QBCore_8F603E)
  QBCORE_DB_USER     — MySQL username
  QBCORE_DB_PASSWORD — MySQL password

The QBCore bans table is expected to have at minimum:
  id        INT  PRIMARY KEY AUTO_INCREMENT
  name      VARCHAR  — in-game player name
  discord   VARCHAR  — "discord:123456789012345678"
  reason    TEXT     — ban reason
  expire    VARCHAR  — expiry timestamp or "never"  (nullable)
  bannedby  VARCHAR  — who banned the player

If your table uses different column names, adjust COLUMN_MAP below.
"""

import asyncio
import logging
import os
from datetime import datetime, timezone

import discord
import pymysql
from pymysql.cursors import DictCursor

log = logging.getLogger("cfrp_bot.ban_monitor")

# ── Config ─────────────────────────────────────────────────────────────────────

QBCORE_DB_HOST = os.getenv("QBCORE_DB_HOST", "localhost")
QBCORE_DB_PORT = int(os.getenv("QBCORE_DB_PORT", "3306"))
QBCORE_DB_NAME = os.getenv("QBCORE_DB_NAME", "QBCore_8F603E")
QBCORE_DB_USER = os.getenv("QBCORE_DB_USER", "csrp")
QBCORE_DB_PASS = os.getenv("QBCORE_DB_PASSWORD", "xhGM0NnDkvCouj8l")

POLL_INTERVAL = 30   # seconds between checks

# Map your actual column names here if they differ
COLUMN_MAP = {
    "id":       "id",
    "name":     "name",
    "discord":  "discord",    # stored as "discord:123456789..."
    "reason":   "reason",
    "expire":   "expire",
    "bannedby": "bannedby",
}


# ── DB helpers ─────────────────────────────────────────────────────────────────

def _connect():
    return pymysql.connect(
        host=QBCORE_DB_HOST,
        port=QBCORE_DB_PORT,
        db=QBCORE_DB_NAME,
        user=QBCORE_DB_USER,
        password=QBCORE_DB_PASS,
        cursorclass=DictCursor,
        connect_timeout=8,
        autocommit=True,
    )


def _get_new_bans(since_id: int) -> list[dict]:
    """Return all bans with id > since_id."""
    col = COLUMN_MAP
    try:
        conn = _connect()
        with conn.cursor() as cur:
            cur.execute(
                f"SELECT * FROM bans WHERE `{col['id']}` > %s ORDER BY `{col['id']}` ASC",
                (since_id,)
            )
            rows = cur.fetchall()
        conn.close()
        return rows
    except Exception as exc:
        log.warning(f"Ban DB query failed: {exc}")
        return []


def _get_latest_id() -> int:
    """Get the highest ban ID currently in the table (used as the starting watermark)."""
    col = COLUMN_MAP
    try:
        conn = _connect()
        with conn.cursor() as cur:
            cur.execute(f"SELECT MAX(`{col['id']}`) AS max_id FROM bans")
            row = cur.fetchone()
        conn.close()
        return int(row["max_id"] or 0)
    except Exception as exc:
        log.warning(f"Ban DB watermark query failed: {exc}")
        return 0


def _parse_discord_id(raw: str | None) -> str | None:
    """Extract numeric Discord ID from 'discord:123456789' format."""
    if not raw:
        return None
    raw = str(raw).strip()
    if raw.startswith("discord:"):
        return raw[len("discord:"):]
    # If it's already a plain snowflake return it
    if raw.isdigit():
        return raw
    return None


# ── DM builder ────────────────────────────────────────────────────────────────

def _build_ban_embed(row: dict) -> discord.Embed:
    col    = COLUMN_MAP
    name   = row.get(col["name"], "Unknown")
    reason = row.get(col["reason"]) or "No reason provided."
    expire = row.get(col["expire"])
    banned_by = row.get(col["bannedby"], "Staff")
    ban_id = row.get(col["id"], "—")

    # Format expiry
    if not expire or str(expire).lower() in ("never", "0", "", "null"):
        expire_str = "**Permanent**"
        color = 0xEF4444   # red
    else:
        expire_str = str(expire)
        color = 0xF97316   # orange — temporary

    embed = discord.Embed(
        title="🔨  You Have Been Banned",
        description=(
            "You have been banned from **Cape Flats Roleplay**.\n"
            "If you believe this ban was issued in error, you may appeal via the website."
        ),
        colour=color,
        timestamp=datetime.now(timezone.utc),
    )
    embed.add_field(name="👤  In-Game Name",  value=f"```{name}```",      inline=True)
    embed.add_field(name="🛡️  Banned By",    value=f"```{banned_by}```",  inline=True)
    embed.add_field(name="🔖  Ban ID",        value=f"```#{ban_id}```",   inline=True)
    embed.add_field(name="📋  Reason",        value=f"> {reason[:1000]}", inline=False)
    embed.add_field(name="⏱️  Expires",       value=expire_str,           inline=True)
    embed.add_field(
        name="📝  Appeal",
        value="[Submit a Ban Appeal](https://web.cfrp.co.za/reports/new?type=player)\n"
              "-# Appeals are reviewed by senior staff and may take up to 72 hours.",
        inline=False,
    )
    embed.set_footer(
        text="Cape Flats Roleplay  •  Ban System",
        icon_url="https://cdn.discordapp.com/embed/avatars/1.png",
    )
    return embed


# ── Background monitor ────────────────────────────────────────────────────────

class BanMonitorCog(discord.ext.commands.Cog):
    """Background task: polls QBCore bans table and DMs newly banned players."""

    def __init__(self, bot: discord.Client):
        self.bot        = bot
        self._last_id   = 0
        self._task      = None

    async def start(self):
        """Call this after the bot is ready — sets watermark and starts polling."""
        loop = asyncio.get_event_loop()
        self._last_id = await loop.run_in_executor(None, _get_latest_id)
        log.info(f"BanMonitor: started. Watermark = ban ID {self._last_id}")
        self._task = asyncio.create_task(self._poll_loop())

    async def _poll_loop(self):
        await asyncio.sleep(5)   # brief delay on first run
        while True:
            try:
                await self._check_bans()
            except Exception as exc:
                log.error(f"BanMonitor poll error: {exc}")
            await asyncio.sleep(POLL_INTERVAL)

    async def _check_bans(self):
        loop = asyncio.get_event_loop()
        rows = await loop.run_in_executor(None, _get_new_bans, self._last_id)
        if not rows:
            return

        col = COLUMN_MAP
        for row in rows:
            ban_id     = int(row.get(col["id"], 0))
            discord_raw = row.get(col["discord"])
            discord_id  = _parse_discord_id(discord_raw)

            log.info(f"BanMonitor: new ban #{ban_id} — player '{row.get(col['name'])}' discord={discord_id}")

            if discord_id:
                await self._dm_banned_user(discord_id, row)
            else:
                log.info(f"BanMonitor: ban #{ban_id} has no Discord ID — skipping DM")

            if ban_id > self._last_id:
                self._last_id = ban_id

    async def _dm_banned_user(self, discord_id: str, row: dict):
        try:
            user = await self.bot.fetch_user(int(discord_id))
        except discord.NotFound:
            log.warning(f"BanMonitor: Discord user {discord_id} not found")
            return
        except discord.HTTPException as e:
            log.warning(f"BanMonitor: fetch_user {discord_id} failed: {e}")
            return

        embed = _build_ban_embed(row)
        try:
            await user.send(embed=embed)
            log.info(f"BanMonitor: DM sent to {user} ({discord_id})")
        except discord.Forbidden:
            log.warning(f"BanMonitor: cannot DM {discord_id} — DMs disabled")
        except discord.HTTPException as e:
            log.error(f"BanMonitor: DM send failed for {discord_id}: {e}")
