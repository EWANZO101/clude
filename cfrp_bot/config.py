"""
Configuration -- edit values here or use a .env file.
"""

import os
from dotenv import load_dotenv

load_dotenv()


class Config:
    # Discord
    DISCORD_TOKEN: str = os.getenv("DISCORD_TOKEN", "YOUR_DISCORD_BOT_TOKEN")
    STAFF_ROLE_ID: int = int(os.getenv("STAFF_ROLE_ID", "1501614137984155790"))

    # Conversation
    CONVERSATION_TIMEOUT: int = 30

    # Ollama
    OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
    OLLAMA_MODEL: str = os.getenv("OLLAMA_MODEL", "llama3.2")

    # CFRP
    goldenshoresrp_WEBSITE: str = "https://web.goldenshoresrp.com"
    CFRP_PLAYTIME_URL: str = "http://169.239.180.43:30120/cfrp_playtime"

    # Whitelist App REST API (replaces direct MySQL connection)
    # WHITELIST_API_URL  — base URL of the whitelist web app, e.g. https://web.goldenshoresrp.com
    # WHITELIST_API_KEY  — an API key with at minimum the "read" scope
    WHITELIST_API_URL: str = os.getenv("WHITELIST_API_URL", "https://web.goldenshoresrp.com")
    WHITELIST_API_KEY: str = os.getenv("WHITELIST_API_KEY", "")

    # FiveM Server
    FIVEM_CFX_CODE: str = "3zdye8"
    FIVEM_CONNECT_URL: str = "https://cfx.re/join/3zdye8"
    FIVEM_API_URL: str = "https://servers-frontend.fivem.net/api/servers/single/3zdye8"

    # Application Links
    APPLICATION_LINKS: dict = {
        "1": ("Whitelist",    "https://web.goldenshoresrp.com/applications/apply/whitelist"),
        "2": ("Dispatch",     "https://web.goldenshoresrp.com/applications/apply/dispatch"),
        "3": ("East Customs", "https://web.goldenshoresrp.com/applications/apply/east-customs"),
        "4": ("EMS",          "https://web.goldenshoresrp.com/applications/apply/ems"),
        "5": ("Fire",         "https://web.goldenshoresrp.com/applications/apply/fire"),
        "6": ("LS Customs",   "https://web.goldenshoresrp.com/applications/apply/ls-customs"),
        "7": ("Police",       "https://web.goldenshoresrp.com/applications/apply/police"),
        "8": ("Tuner Shop",   "https://web.goldenshoresrp.com/applications/apply/tuner-shop"),
    }

    # Reports
    REPORT_PLAYER_URL: str = "https://web.goldenshoresrp.com/reports/new?type=player"
    REPORT_BUG_URL: str    = "https://web.goldenshoresrp.com/reports/new?type=bug"

    # Webhook secret — must match what the CFRP website sends in X-Webhook-Secret header
    WEBHOOK_SECRET: str = os.getenv("WEBHOOK_SECRET", "")

    # Persistence
    KNOWLEDGE_FILE: str  = "data/knowledge_base.json"
    FEEDBACK_FILE: str   = "data/feedback_corrections.json"
    OVERRIDES_FILE: str  = "data/staff_overrides.json"

    # Ticket System
    TICKET_CATEGORY_ID: int = 1501617058679357440
    TICKET_APP_FOLDER: str  = "/root/recovered_app/APP"
