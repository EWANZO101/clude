"""
KnowledgeScraper — auto-loads goldenshoresrp website pages, Discord channels,
and the web API into the KnowledgeBase on startup, and re-scrapes periodically.
"""

import asyncio
import aiohttp
import logging
import discord
from bs4 import BeautifulSoup
from config import Config
from knowledge.knowledge_base import KnowledgeBase

log = logging.getLogger("goldenshoresrp_bot.scraper")

# Pages to scrape from the goldenshoresrp website
PAGES_TO_SCRAPE = [
    Config.goldenshoresrp_WEBSITE,
    f"{Config.goldenshoresrp_WEBSITE}/applications",
    f"{Config.goldenshoresrp_WEBSITE}/rules",
    f"{Config.goldenshoresrp_WEBSITE}/about",
]

# API endpoints to pull into KB
API_ENDPOINTS = [
    "/api/analytics/summary",
    "/api/analytics/leaderboard?period=weekly",
    "/api/analytics/live",
    "/api/analytics/crashes",
    "/api/roles",
    "/api/applications",
]

RESCRAPE_INTERVAL = 3600  # re-scrape every hour


class KnowledgeScraper:
    def __init__(self, bot: discord.Client):
        self.bot = bot
        self.kb  = KnowledgeBase()

    async def initial_load(self):
        """Called once on bot ready."""
        log.info("Starting initial knowledge scrape...")
        await self._scrape_website()
        await self._index_discord_channels()
        await self._scrape_api()
        log.info("Initial knowledge load complete.")
        # Schedule periodic refresh
        asyncio.create_task(self._periodic_refresh())

    # ── Website scraping ───────────────────────────────────────────────────────

    async def _scrape_website(self):
        async with aiohttp.ClientSession() as session:
            for url in PAGES_TO_SCRAPE:
                try:
                    async with session.get(
                        url, timeout=aiohttp.ClientTimeout(total=10)
                    ) as resp:
                        if resp.status == 200:
                            html = await resp.text()
                            text = self._extract_text(html)
                            self.kb.upsert_page(url, text)
                            log.info(f"Scraped: {url} ({len(text)} chars)")
                        else:
                            log.warning(f"Skipped {url} — HTTP {resp.status}")
                except Exception as e:
                    log.error(f"Failed to scrape {url}: {e}")

    @staticmethod
    def _extract_text(html: str) -> str:
        soup = BeautifulSoup(html, "html.parser")
        for tag in soup(["script", "style", "nav", "footer"]):
            tag.decompose()
        return " ".join(soup.get_text(separator=" ").split())[:4000]

    # ── Web API scraping ───────────────────────────────────────────────────────

    async def _scrape_api(self):
        api_key = Config.WHITELIST_API_KEY
        base    = Config.WHITELIST_API_URL

        if not api_key:
            log.warning("WHITELIST_API_KEY not set — skipping API scrape")
            return

        headers = {"X-API-Key": api_key}
        async with aiohttp.ClientSession() as session:
            for ep in API_ENDPOINTS:
                url = f"{base}{ep}"
                try:
                    async with session.get(
                        url, headers=headers, timeout=aiohttp.ClientTimeout(total=10)
                    ) as resp:
                        if resp.status == 200:
                            text = await resp.text()
                            self.kb.upsert_page(f"api:{ep}", text[:3000])
                            log.info(f"API scraped: {ep} ({len(text)} chars)")
                        else:
                            log.warning(f"API skipped {ep} — HTTP {resp.status}")
                except Exception as e:
                    log.error(f"API scrape failed {ep}: {e}")

    # ── Discord channel indexing ───────────────────────────────────────────────

    async def _index_discord_channels(self):
        for guild in self.bot.guilds:
            for channel in guild.text_channels:
                try:
                    messages = [
                        m.content async for m in channel.history(limit=50)
                        if not m.author.bot and m.content
                    ]
                    if messages:
                        summary = (
                            f"Channel: #{channel.name} | "
                            f"Topic: {channel.topic or 'None'}\n"
                            + "\n".join(messages[:20])
                        )
                        self.kb.upsert_channel(str(channel.id), summary)
                except discord.Forbidden:
                    pass  # Bot doesn't have access to this channel
                except Exception as e:
                    log.error(f"Failed to index #{channel.name}: {e}")

    # ── Periodic refresh ───────────────────────────────────────────────────────

    async def _periodic_refresh(self):
        while True:
            await asyncio.sleep(RESCRAPE_INTERVAL)
            log.info("Periodic knowledge refresh starting...")
            await self._scrape_website()
            await self._index_discord_channels()
            await self._scrape_api()
            log.info("Periodic knowledge refresh done.")