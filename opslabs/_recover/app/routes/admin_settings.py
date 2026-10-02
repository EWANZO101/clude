"""Global settings editor — /admin/settings/

Categorised key/value page. Categories: brand, flags, integrations.
Reads from and writes to the Setting model.
"""
from functools import wraps
from flask import Blueprint, render_template, request, jsonify, redirect, url_for, abort
from flask_login import login_required, current_user
from .. import db
from ..models_admin import Setting

settings_bp = Blueprint("settings", __name__)


def admin_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if not getattr(current_user, 'is_admin', False):
            abort(403)
        return f(*a, **kw)
    return wrapper


# Friendly labels + helps per key — keeps presentation out of the data.
SETTING_META = {
    # ── Brand
    "BRAND_NAME":         ("brand", "Brand name",
                           "Shown in headers, page titles, and embeds."),
    "BRAND_TAGLINE":      ("brand", "Tagline",
                           "Short slogan under your brand."),
    "BRAND_LOGO_URL":     ("brand", "Logo URL",
                           "Public URL of your logo (PNG/SVG). Leave blank to skip."),
    "BRAND_ACCENT_COLOR": ("brand", "Accent colour",
                           "Hex like #2196f3 — used as the primary brand colour."),
    "BRAND_SUPPORT_EMAIL":("brand", "Support email",
                           "Address shown on receipts, password resets, etc."),

    # ── Flags
    "MAINTENANCE_MODE":         ("flags", "Maintenance mode",
                                 "When enabled, non-admin visitors see the maintenance page."),
    "MAINTENANCE_MESSAGE":      ("flags", "Maintenance message",
                                 "Shown to visitors when maintenance mode is on."),
    "BANNER_ENABLED":           ("flags", "Show site banner",
                                 "Top-of-page banner across the public site."),
    "BANNER_TEXT":              ("flags", "Banner text",
                                 "What the banner says."),
    "BANNER_LINK":              ("flags", "Banner link",
                                 "Optional URL the banner opens when clicked."),
    "DISCORD_AUTO_CREATE_USERS":("flags", "Auto-create Discord users",
                                 "When a Discord user clicks a ticket button without "
                                 "linking, automatically create a placeholder account."),
    "ALLOW_PUBLIC_SIGNUP":      ("flags", "Allow public signup",
                                 "Turn off to require admin-created accounts."),

    # ── Integrations
    "DISCORD_GUILD_URL":        ("integrations", "Discord invite URL",
                                 "Public invite link to your Discord server."),
    "DISCORD_BOT_URL":          ("integrations", "Discord bot URL (internal)",
                                 "Where Flask reaches the bot's HTTP API. Usually http://127.0.0.1:5005"),
}

CATEGORY_TITLES = {
    "brand":        ("Brand", "Names, colours, and logo across the site."),
    "flags":        ("Site flags", "Toggles that change how the public site behaves."),
    "integrations": ("Integrations", "Discord, email, and other external services."),
}

CATEGORY_ORDER = ["brand", "flags", "integrations"]


# ════════════════════════════════════════════════════════════════════════
@settings_bp.route("/")
@admin_required
def index():
    active = request.args.get("category", "brand")
    if active not in CATEGORY_TITLES:
        active = "brand"

    grouped = Setting.all_by_category()
    # Attach metadata to each setting object for the template
    for cat, rows in grouped.items():
        for s in rows:
            meta = SETTING_META.get(s.key)
            s.display_label = meta[1] if meta else s.key.replace("_", " ").title()
            s.help_text = meta[2] if meta else ""

    return render_template(
        "admin/ops_settings.html",
        grouped=grouped,
        category_titles=CATEGORY_TITLES,
        category_order=CATEGORY_ORDER,
        active=active,
    )


@settings_bp.route("/save", methods=["POST"])
@admin_required
def save():
    payload = request.get_json(silent=True) or {}
    items = payload.get("items") or []
    if not isinstance(items, list):
        return jsonify({"error": "expected items list"}), 400

    for it in items:
        key = (it.get("key") or "").strip()
        if not key:
            continue
        existing = Setting.query.filter_by(key=key).first()
        kind = (existing.kind if existing else "string")
        cat  = (existing.category if existing else "general")
        Setting.set(key=key, value=it.get("value"), kind=kind, category=cat)

    return jsonify({"ok": True})
