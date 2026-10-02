"""
IntentHandler -- detects keywords and returns fast structured responses
without needing an AI round-trip.
"""

import re
import discord
import aiohttp
from config import Config

CORRECTION_PATTERNS = [
    r"\bthat'?s wrong\b",
    r"\bincorrect\b",
    r"\bnot right\b",
    r"\bwrong answer\b",
    r"\bthat is wrong\b",
    r"\bnot correct\b",
]

APPLY_PATTERNS  = [r"\bapply\b", r"\bapplication\b", r"\bjoin.*role\b"]
PLAYER_REPORT   = [r"\breport.*player\b", r"\bplayer.*report\b"]
BUG_REPORT      = [r"\breport.*bug\b", r"\bbug.*report\b"]
CITY_COUNT      = [r"\bhow many.*city\b", r"\bplayers.*online\b",
                   r"\bwho.*in the city\b", r"\bserver.*count\b"]
SERVER_STATUS   = [r"\bserver.*status\b", r"\bis.*server.*up\b",
                   r"\bserver.*online\b", r"\bserver.*down\b",
                   r"\bfivem.*status\b", r"\bconnect\b", r"\bjoin.*server\b"]


class IntentHandler:
    def is_correction(self, text: str) -> bool:
        text = text.lower()
        return any(re.search(p, text) for p in CORRECTION_PATTERNS)

    def detect(self, text: str) -> str | None:
        text = text.lower()
        if any(re.search(p, text) for p in SERVER_STATUS):
            return "server_status"
        if any(re.search(p, text) for p in APPLY_PATTERNS):
            return "apply"
        if any(re.search(p, text) for p in PLAYER_REPORT):
            return "report_player"
        if any(re.search(p, text) for p in BUG_REPORT):
            return "report_bug"
        if any(re.search(p, text) for p in CITY_COUNT):
            return "city_count"
        return None

    async def respond(self, message: discord.Message, intent: str):
        if intent == "server_status":
            await self._send_server_status(message)
        elif intent == "apply":
            await self._send_apply_menu(message)
        elif intent == "report_player":
            await message.reply(
                f"Report a player here: {Config.REPORT_PLAYER_URL}",
                mention_author=False,
            )
        elif intent == "report_bug":
            await message.reply(
                f"Report a bug here: {Config.REPORT_BUG_URL}",
                mention_author=False,
            )
        elif intent == "city_count":
            await self._send_city_count(message)

    # -- Helpers ---------------------------------------------------------------

    async def _send_server_status(self, message: discord.Message):
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(Config.FIVEM_API_URL,
                                 timeout=aiohttp.ClientTimeout(total=8)) as r:
                    if r.status != 200:
                        raise Exception(f"HTTP {r.status}")
                    data = await r.json(content_type=None)

            srv  = data.get("Data", {})
            name = srv.get("sv_projectName") or srv.get("hostname", "CFRP")
            players   = len(srv.get("players", []))
            max_p     = srv.get("sv_maxclients", "?")
            # Strip colour codes like ^1, ^7 from FiveM server names
            name = re.sub(r'\^\d', '', name).strip()

            await message.reply(
                f"🟢 **{name}** is online\n"
                f"👥 {players}/{max_p} players\n"
                f"🎮 [Join now]({Config.FIVEM_CONNECT_URL})",
                mention_author=False,
            )

        except Exception:
            await message.reply(
                f"🔴 Server appears offline or unreachable.\n"
                f"🌐 {Config.CFRP_WEBSITE}",
                mention_author=False,
            )

    async def _send_apply_menu(self, message: discord.Message):
        lines = ["**What are you applying for?**\n"]
        for num, (name, url) in Config.APPLICATION_LINKS.items():
            lines.append(f"`{num}.` [{name}]({url})")
        await message.reply("\n".join(lines), mention_author=False)

    async def _send_city_count(self, message: discord.Message):
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(Config.FIVEM_API_URL,
                                 timeout=aiohttp.ClientTimeout(total=8)) as r:
                    data = await r.json(content_type=None)
            players = len(data.get("Data", {}).get("players", []))
            max_p   = data.get("Data", {}).get("sv_maxclients", "?")
            await message.reply(
                f"👥 **{players}/{max_p}** players currently in the city.",
                mention_author=False,
            )
        except Exception:
            await message.reply(
                "Couldn't fetch the player count right now. Try again shortly.",
                mention_author=False,
            )
