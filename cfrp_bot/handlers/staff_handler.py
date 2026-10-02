"""
StaffHandler — staff commands and silence overrides.

Fixes vs original:
  - Silence overrides stored in the database (not a JSON file).
  - In-memory cache for fast is_silenced() checks, populated from DB on first
    access and kept in sync on every write.
  - Accepts live ollama and kb references from MessageHandler so AI management
    commands work immediately — no circular "from bot import _handler" import.
  - AI Management commands:
      !bot ai model <name>  — change the Ollama model at runtime
      !bot ai url <url>     — change the Ollama base URL at runtime
      !bot ai test          — send a test prompt and report latency
      !bot reload-kb        — reload the knowledge base from disk
      !bot status           — silence counts + AI config + KB info + ticket counts
      !bot help             — list all staff commands
"""

import discord
import logging
import time
from config import Config
from database.db_manager import db

log = logging.getLogger("cfrp_bot.staff_handler")


class StaffHandler:
    def __init__(self, ollama=None, kb=None):
        # Live references injected by MessageHandler — no circular imports needed
        self._ollama = ollama
        self._kb     = kb
        # In-memory cache, lazy-loaded from DB on first is_silenced() call
        self._cache: dict | None = None

    # ── Cache helpers ─────────────────────────────────────────────────────────

    def _load(self) -> dict:
        try:
            data = db.get_silenced()
        except Exception as e:
            log.warning(f"StaffHandler: could not load silenced from DB: {e}")
            data = {"silenced_users": [], "silenced_channels": []}
        return {
            "silenced_users":    set(data.get("silenced_users", [])),
            "silenced_channels": set(data.get("silenced_channels", [])),
        }

    @property
    def _overrides(self) -> dict:
        if self._cache is None:
            self._cache = self._load()
        return self._cache

    # ── Public API ────────────────────────────────────────────────────────────

    def is_staff(self, member: discord.Member) -> bool:
        if not isinstance(member, discord.Member):
            return False
        return any(r.id == Config.STAFF_ROLE_ID for r in member.roles)

    def is_silenced(self, user_id: int, channel_id: int) -> bool:
        return (user_id    in self._overrides["silenced_users"] or
                channel_id in self._overrides["silenced_channels"])

    async def handle(self, message: discord.Message) -> bool:
        """
        Returns True if the message was a recognised staff command.

        Silence commands:
          !bot silence user <@mention>
          !bot unsilence user <@mention>
          !bot silence channel
          !bot unsilence channel

        AI management:
          !bot ai model <name>   — hot-swap Ollama model
          !bot ai url <url>      — hot-swap Ollama base URL
          !bot ai test           — test prompt with latency report

        KB management:
          !bot reload-kb         — hot-reload knowledge base from disk

        Info:
          !bot status            — full status embed
          !bot help              — list commands
        """
        content = message.content.strip()
        if not content.lower().startswith("!bot"):
            return False

        parts  = content.split()
        lparts = [p.lower() for p in parts]

        # ── !bot silence user <@mention> ──────────────────────────────────────
        if len(lparts) >= 3 and lparts[1] == "silence" and lparts[2] == "user":
            targets = message.mentions
            if not targets:
                await message.reply("Please mention a user to silence.")
                return True
            for t in targets:
                db.silence("user", t.id, message.author.id)
                self._overrides["silenced_users"].add(t.id)
            await message.reply(f"✅ Silenced: {', '.join(t.mention for t in targets)}")
            return True

        # ── !bot unsilence user <@mention> ────────────────────────────────────
        if len(lparts) >= 3 and lparts[1] == "unsilence" and lparts[2] == "user":
            targets = message.mentions
            for t in targets:
                db.unsilence("user", t.id)
                self._overrides["silenced_users"].discard(t.id)
            await message.reply(f"✅ Unsilenced: {', '.join(t.mention for t in targets)}")
            return True

        # ── !bot silence channel ───────────────────────────────────────────────
        if len(lparts) >= 3 and lparts[1] == "silence" and lparts[2] == "channel":
            cid = message.channel.id
            db.silence("channel", cid, message.author.id)
            self._overrides["silenced_channels"].add(cid)
            await message.reply("✅ I will no longer respond in this channel.")
            return True

        # ── !bot unsilence channel ────────────────────────────────────────────
        if len(lparts) >= 3 and lparts[1] == "unsilence" and lparts[2] == "channel":
            cid = message.channel.id
            db.unsilence("channel", cid)
            self._overrides["silenced_channels"].discard(cid)
            await message.reply("✅ I will now respond in this channel again.")
            return True

        # ── !bot ai model <name> ──────────────────────────────────────────────
        if len(lparts) >= 3 and lparts[1] == "ai" and lparts[2] == "model":
            if len(parts) < 4:
                await message.reply(
                    "Usage: `!bot ai model <model-name>`\n"
                    "Example: `!bot ai model llama3.2`"
                )
                return True
            new_model = parts[3]
            old_model = Config.OLLAMA_MODEL
            Config.OLLAMA_MODEL = new_model
            if self._ollama:
                self._ollama.model = new_model
            await message.reply(
                f"✅ Ollama model changed: `{old_model}` → `{new_model}`\n"
                f"*Takes effect on the next AI message.*"
            )
            log.info(f"AI model changed '{old_model}' → '{new_model}' by {message.author}")
            return True

        # ── !bot ai url <url> ─────────────────────────────────────────────────
        if len(lparts) >= 3 and lparts[1] == "ai" and lparts[2] == "url":
            if len(parts) < 4:
                await message.reply(
                    "Usage: `!bot ai url <base-url>`\n"
                    "Example: `!bot ai url http://localhost:11434`"
                )
                return True
            new_url = parts[3].rstrip("/")
            old_url = Config.OLLAMA_BASE_URL
            Config.OLLAMA_BASE_URL = new_url
            if self._ollama:
                self._ollama.base_url = new_url
            await message.reply(f"✅ Ollama URL changed: `{old_url}` → `{new_url}`")
            log.info(f"AI URL changed '{old_url}' → '{new_url}' by {message.author}")
            return True

        # ── !bot ai test ──────────────────────────────────────────────────────
        if len(lparts) >= 3 and lparts[1] == "ai" and lparts[2] == "test":
            if not self._ollama:
                await message.reply("❌ AI client not available yet — try again in a moment.")
                return True
            async with message.channel.typing():
                try:
                    t0      = time.monotonic()
                    reply   = await self._ollama.chat("Say 'CFRP AI test OK' and nothing else.")
                    elapsed = time.monotonic() - t0
                    await message.reply(
                        f"🤖 **AI Test Result**\n"
                        f"Model: `{Config.OLLAMA_MODEL}`\n"
                        f"URL: `{Config.OLLAMA_BASE_URL}`\n"
                        f"Latency: `{elapsed:.2f}s`\n"
                        f"Response: {reply[:300]}"
                    )
                except Exception as e:
                    await message.reply(f"❌ AI test failed: `{e}`")
            return True

        # ── !bot reload-kb ────────────────────────────────────────────────────
        if len(lparts) >= 2 and lparts[1] == "reload-kb":
            if not self._kb:
                await message.reply("❌ Knowledge base not available yet — try again in a moment.")
                return True
            try:
                self._kb.reload()
                doc_count = len(self._kb._docs) if hasattr(self._kb, "_docs") else "?"
                await message.reply(f"✅ Knowledge base reloaded — `{doc_count}` entries in memory.")
            except Exception as e:
                await message.reply(f"❌ Reload failed: `{e}`")
            return True

        # ── !bot status ───────────────────────────────────────────────────────
        if len(lparts) >= 2 and lparts[1] == "status":
            su = len(self._overrides["silenced_users"])
            sc = len(self._overrides["silenced_channels"])

            ai_model = Config.OLLAMA_MODEL
            ai_url   = Config.OLLAMA_BASE_URL

            kb_docs = "?"
            if self._kb and hasattr(self._kb, "_docs"):
                kb_docs = len(self._kb._docs)

            open_tickets = "?"
            type_count   = "?"
            try:
                open_tickets = len(db.get_all_open_tickets())
                type_count   = len(db.get_all_types())
            except Exception:
                pass

            embed = discord.Embed(title="🤖 Bot Status", colour=discord.Colour.blurple())
            embed.add_field(name="Silenced Users",    value=f"`{su}`",           inline=True)
            embed.add_field(name="Silenced Channels", value=f"`{sc}`",           inline=True)
            embed.add_field(name="Open Tickets",      value=f"`{open_tickets}`", inline=True)
            embed.add_field(name="Ticket Types",      value=f"`{type_count}`",   inline=True)
            embed.add_field(name="AI Model",          value=f"`{ai_model}`",     inline=True)
            embed.add_field(name="AI URL",            value=f"`{ai_url}`",       inline=True)
            embed.add_field(name="KB Entries",        value=f"`{kb_docs}`",      inline=True)
            embed.set_footer(text="Use !bot help to see all staff commands")
            await message.reply(embed=embed)
            return True

        # ── !bot help ─────────────────────────────────────────────────────────
        if len(lparts) >= 2 and lparts[1] == "help":
            embed = discord.Embed(
                title="🛡️ Staff Bot Commands",
                colour=discord.Colour.blurple(),
                description=(
                    "**Silence / Unsilence**\n"
                    "`!bot silence user @mention` — stop AI responding to a user\n"
                    "`!bot unsilence user @mention`\n"
                    "`!bot silence channel` — stop AI responding in this channel\n"
                    "`!bot unsilence channel`\n\n"
                    "**AI Management**\n"
                    "`!bot ai model <name>` — switch Ollama model (e.g. `llama3.2`)\n"
                    "`!bot ai url <url>` — change Ollama base URL\n"
                    "`!bot ai test` — send a test prompt and measure latency\n"
                    "`!bot reload-kb` — hot-reload the knowledge base\n\n"
                    "**Info**\n"
                    "`!bot status` — show silence counts, AI config & KB info\n"
                    "`!bot help` — this message"
                ),
            )
            await message.reply(embed=embed)
            return True

        return False
