"""
═══════════════════════════════════════════════════════════════════════════
  admin_seeds.py — default homepage content + settings
═══════════════════════════════════════════════════════════════════════════
  Drop in /root/opslabs/app/. Called once from app/__init__.py during
  _seed_defaults so the new admin tables get content out of the box.
═══════════════════════════════════════════════════════════════════════════
"""
from .models_admin import SiteContent, Setting


def seed_admin_defaults(db):
    """Idempotent — only inserts rows that don't exist yet."""

    # ─── Homepage content ─────────────────────────────────────────────
    defaults = {
        "hero": {
            "eyebrow": "Live · Web · FiveM · Hosting · Infrastructure",
            "headline_a": "Build. Support.",
            "headline_b": "Scale.",
            "headline_c": "Together.",
            "subhead":   "From custom websites to FiveM scripts, hosting to system setup — under one roof, one team, one ticket system.",
            "small":     "Open a ticket on the web or in Discord. The other side opens automatically — and stays in sync, live.",
            "stat_a_value": "6",      "stat_a_label": "Service Lines",
            "stat_b_value": "≤5s",    "stat_b_label": "Live Sync",
            "stat_c_value": "24/7",   "stat_c_label": "Always-On Bot",
        },

        "metrics": {
            "a_label": "Tickets handled",      "a_value": "1,000+",  "a_sub": "Across all services",
            "b_label": "Avg first response",   "b_value": "< 1hr",   "b_sub": "Business hours",
            "c_label": "Uptime",               "c_value": "99.9%",   "c_sub": "Past 90 days",
            "d_label": "Services online",      "d_value": "All systems", "d_sub": "Updated just now",
        },

        "services_intro": {
            "eyebrow":  "— What we do —",
            "headline": "Everything your community needs.",
            "subhead":  "Six service lines, one team, one ticket system. No more chasing freelancers across five different platforms.",
        },

        "services": {
            "items": [
                {"key": "web",     "name": "Website Development",  "desc": "Custom sites, dashboards, landing pages, e-commerce, and ongoing maintenance.",
                 "tech": ["React", "Next.js", "Flask", "Wordpress"]},
                {"key": "fivem",   "name": "FiveM Development",    "desc": "Scripts, MLOs, custom maps, and full server builds for QBCore / ESX / standalone.",
                 "tech": ["QBCore", "ESX", "Lua", "MLO"]},
                {"key": "tech",    "name": "Tech Support",         "desc": "Debugging, troubleshooting, and rapid fixes for any tech problem. Real engineers, fast.",
                 "tech": ["Debugging", "Log analysis", "Triage"]},
                {"key": "hosting", "name": "Hosting Support",      "desc": "VPS, dedicated, and game-server hosting. Provisioning, migration, ongoing management.",
                 "tech": ["VPS", "Dedicated", "Game servers"]},
                {"key": "setup",   "name": "System Setup",         "desc": "Provisioning, OS installation, hardening, monitoring, and performance tuning.",
                 "tech": ["Linux", "Windows Server", "Hardening"]},
                {"key": "other",   "name": "And More — Anything Tech",
                 "desc": "Doesn't fit a category? Open a ticket and we'll route you to the right specialist.",
                 "tech": ["Custom request"], "highlighted": True},
            ],
        },

        "how_it_works": {
            "eyebrow":  "— How it works —",
            "headline": "From request to resolution, fast.",
            "subhead":  "A real workflow — not a generic contact form.",
            "steps": [
                {"n": 1, "title": "Open a ticket",
                 "body": "Pick a service, answer a few short questions. On the web or in Discord — your call."},
                {"n": 2, "title": "Private channel opens",
                 "body": "Locked-down Discord channel, mirrored to the web dashboard. Both stay in sync, live."},
                {"n": 3, "title": "Done — and archived",
                 "body": "Resolved, transcripts saved, searchable forever. Reopen any time if it comes back."},
            ],
        },

        "why_us": {
            "eyebrow":  "— Why OpsLab Systems —",
            "headline": "Built for real conversations.",
            "lead":     "Not a contact form. Not a chatbot loop. Not \"we'll get back to you in 5–7 business days.\"",
            "body":     "A live, two-way connection between you and our team — on whichever platform you actually use. Every ticket gets a private Discord channel, mirrored to a web dashboard, with replies syncing within seconds.",
            "bullets": [
                "**No middlemen.** Talk to the engineer doing the work.",
                "**Private by default.** Your ticket channel is locked to you + staff.",
                "**Always-on bot.** 24/7 channel creation. Specialist routing.",
                "**Searchable history.** Every transcript saved + indexed.",
            ],
            "features": [
                {"title": "Two-way sync",       "body": "Reply on web — it lands in Discord. Reply in Discord — it appears on the web. Within 5 seconds."},
                {"title": "Private channels",   "body": "Each ticket gets a locked Discord channel — visible only to you and the assigned specialists."},
                {"title": "Specialist routing", "body": "FiveM tickets ping FiveM engineers. Hosting tickets ping sysadmins. No \"let me check with someone…\""},
                {"title": "Full transcripts",   "body": "Every ticket archived in full — both web messages and Discord ones — even after closing."},
            ],
        },

        "faq": {
            "eyebrow":  "— FAQ —",
            "headline": "Common questions.",
            "items": [
                {"q": "How do I get started?",
                 "a": "Click \"Get Started Free\" — register in 30 seconds, then open your first ticket. Free quote, no card."},
                {"q": "How quickly do you respond?",
                 "a": "Most tickets get a first response within an hour during business hours. The Discord bot creates the channel instantly, 24/7."},
                {"q": "Do you do free work?",
                 "a": "Quotes are always free. Custom work is paid — we scope it together in the ticket so there are no surprises."},
                {"q": "Can I just chat in Discord without using the website?",
                 "a": "You can — but every ticket lives on both. If you only use Discord, that's fine; the web dashboard becomes a permanent searchable record."},
                {"q": "How do you handle confidentiality?",
                 "a": "Every ticket channel is locked to you and the assigned specialist. We sign NDAs for any project where you need formal confidentiality."},
                {"q": "What payment methods do you accept?",
                 "a": "We'll discuss options in your ticket once we've scoped the work. Bank transfer, card, crypto — we're flexible."},
            ],
        },

        "cta": {
            "headline": "Ready to build with us?",
            "body":     "Join OpsLab Systems and get connected to a network that actually responds. Free to sign up. No card required.",
        },
    }

    for section, data in defaults.items():
        if not SiteContent.query.filter_by(section=section).first():
            row = SiteContent(section=section)
            row.data = data
            db.session.add(row)

    # ─── Settings ─────────────────────────────────────────────────────
    setting_defaults = [
        # Brand
        ("BRAND_NAME",         "OpsLab Systems",                          "string", "brand"),
        ("BRAND_TAGLINE",      "Build. Support. Scale. Together.",        "string", "brand"),
        ("BRAND_LOGO_URL",     "",                                        "string", "brand"),
        ("BRAND_ACCENT_COLOR", "#2196f3",                                 "color",  "brand"),
        ("BRAND_SUPPORT_EMAIL","support@example.com",                     "string", "brand"),

        # Feature flags
        ("MAINTENANCE_MODE",       "0",                "bool", "flags"),
        ("MAINTENANCE_MESSAGE",    "We're doing scheduled maintenance. Back soon.", "string", "flags"),
        ("BANNER_ENABLED",         "0",                "bool", "flags"),
        ("BANNER_TEXT",            "",                 "string", "flags"),
        ("BANNER_LINK",            "",                 "string", "flags"),
        ("DISCORD_AUTO_CREATE_USERS","1",              "bool", "flags"),
        ("ALLOW_PUBLIC_SIGNUP",    "1",                "bool", "flags"),

        # Integrations (display-only; the secrets live in .env)
        ("DISCORD_GUILD_URL",      "",                 "string", "integrations"),
        ("DISCORD_BOT_URL",        "http://127.0.0.1:5005", "string", "integrations"),
    ]
    for key, val, kind, cat in setting_defaults:
        if not Setting.query.filter_by(key=key).first():
            Setting.set(key=key, value=val, kind=kind, category=cat)

    db.session.commit()
