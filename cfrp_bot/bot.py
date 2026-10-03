"""
Cape Flats Roleplay Discord Bot - Main Entry Point
"""

import discord
from discord.ext import commands
from discord import app_commands
import asyncio
import logging
from config import Config

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
log = logging.getLogger("goldenshoresrp_bot")

intents = discord.Intents.default()
intents.message_content = True
intents.members = True

bot = commands.Bot(command_prefix="!", intents=intents)

_handler = None
_scraper = None


@bot.event
async def on_ready():
    global _handler, _scraper
    log.info(f"Logged in as {bot.user} (ID: {bot.user.id})")

    # 1. Auto-create database and all tables
    log.info("Initialising database...")
    try:
        from database.db_manager import db
        db.initialise()
        log.info("Database ready.")
    except Exception as e:
        log.error(f"Database init failed: {e}")
        log.error("Check DB_HOST / DB_USER / DB_PASSWORD in your .env")

    # 2. Message handler
    from handlers.message_handler import MessageHandler
    _handler = MessageHandler(bot)

    # 3. Ticket system cog
    from handlers.ticket_handler import TicketCog
    await bot.add_cog(TicketCog(bot))
    log.info("Ticket system loaded.")

    # 3b. Ticket setup panel cog
    from handlers.ticket_setup_panel import TicketSetupPanelCog
    await bot.add_cog(TicketSetupPanelCog(bot))
    log.info("Ticket setup panel loaded.")

    # 4. Knowledge base
    log.info("Loading knowledge base...")
    from knowledge.scraper import KnowledgeScraper
    _scraper = KnowledgeScraper(bot)
    asyncio.create_task(_scraper.initial_load())
    log.info("Knowledge base loading in background.")

    # 5. Sync slash commands
    await bot.tree.sync()
    log.info("Slash commands synced.")

    log.info("Bot fully ready.")

    # Register bot instance with report webhook so it can send DMs
    from web.report_webhook import set_bot as _set_webhook_bot
    _set_webhook_bot(bot)
    log.info("Report webhook bot reference set.")


@bot.event
async def on_message(message: discord.Message):
    if message.author.bot or _handler is None:
        return
    await _handler.process(message)
    await bot.process_commands(message)


@bot.event
async def on_close():
    if _handler is not None:
        await _handler.ollama.close()


# ── AI Sync Commands ───────────────────────────────────────────────────────────

@bot.tree.command(name="ai-sync", description="Manually re-scrape website, API and Discord channels into the AI knowledge base")
@app_commands.describe(source="Which source to sync (default: all)")
@app_commands.choices(source=[
    app_commands.Choice(name="All sources",           value="all"),
    app_commands.Choice(name="Discord channels only", value="discord"),
    app_commands.Choice(name="Website pages only",    value="website"),
    app_commands.Choice(name="Web API only",          value="api"),
])
@app_commands.checks.has_any_role("Admin", "Staff", "Management")
async def ai_sync(interaction: discord.Interaction, source: str = "all"):
    await interaction.response.defer(ephemeral=True)

    if _scraper is None:
        await interaction.followup.send("❌ Scraper not initialised yet — try again in a few seconds.", ephemeral=True)
        return

    results = []

    if source in ("all", "website"):
        await _scraper._scrape_website()
        results.append("✅ Website pages scraped")

    if source in ("all", "discord"):
        await _scraper._index_discord_channels()
        results.append("✅ Discord channels indexed")

    if source in ("all", "api"):
        await _scraper._scrape_api()
        results.append("✅ Web API endpoints fetched")

    embed = discord.Embed(
        title="🧠 AI Knowledge Base — Sync Complete",
        description="\n".join(results),
        color=0x57F287,
    )
    embed.set_footer(text="AI will use this updated knowledge on the next question.")
    await interaction.followup.send(embed=embed, ephemeral=True)


@bot.tree.command(name="ai-sync-status", description="Show AI knowledge base sync status")
async def ai_sync_status(interaction: discord.Interaction):
    if _scraper is None:
        await interaction.response.send_message("❌ Scraper not ready yet.", ephemeral=True)
        return

    kb = _scraper.kb
    pages    = len(kb.pages)    if hasattr(kb, "pages")    else "?"
    channels = len(kb.channels) if hasattr(kb, "channels") else "?"

    embed = discord.Embed(
        title="🧠 AI Knowledge Base — Status",
        color=0x6366F1,
    )
    embed.add_field(name="Website pages",      value=str(pages),    inline=True)
    embed.add_field(name="Discord channels",   value=str(channels), inline=True)
    embed.add_field(name="Auto-refresh",       value="Every 60 min", inline=True)
    embed.add_field(
        name="Sources",
        value=(
            f"🌐 `{Config.goldenshoresrp_WEBSITE}`\n"
            f"🌐 `{Config.goldenshoresrp_WEBSITE}/rules`\n"
            f"🌐 `{Config.goldenshoresrp_WEBSITE}/applications`\n"
            f"🌐 `{Config.goldenshoresrp_WEBSITE}/about`\n"
            f"📡 API: `/api/analytics/summary`, `/api/roles`, `/api/analytics/leaderboard`\n"
            f"💬 All accessible Discord channels"
        ),
        inline=False,
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)


# ── Web server ─────────────────────────────────────────────────────────────────

def _start_web_server():
    import threading, os
    os.makedirs("transcripts", exist_ok=True)
    from web.transcript_server import app, WEB_PORT
    from web.report_webhook import report_webhook
    app.register_blueprint(report_webhook)
    t = threading.Thread(
        target=lambda: app.run(host="0.0.0.0", port=WEB_PORT, debug=False, use_reloader=False),
        daemon=True,
    )
    t.start()
    log.info(f"Transcript web server started on port {WEB_PORT}")


if __name__ == "__main__":
    _start_web_server()
    bot.run(Config.DISCORD_TOKEN)