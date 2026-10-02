"""Link a web account to Discord with a one-time code, and test bot DMs."""
from flask import Blueprint, jsonify
from flask_login import login_required, current_user

from ..models import DiscordLinkCode
from ..models_admin import Setting
from ..discord_dm import bot_call

discord_link_bp = Blueprint("discord_link", __name__)

DEFAULT_INVITE = "https://discord.gg/6FtYZj7RMc"


def invite_url():
    return (Setting.get("DISCORD_GUILD_URL") or "").strip() or DEFAULT_INVITE


def _status_payload():
    return {
        "ok": True,
        "linked": bool(current_user.discord_id),
        "discord_username": current_user.discord_username,
        "invite_url": invite_url(),
    }


@discord_link_bp.route("/account/discord/status")
@login_required
def status():
    resp = jsonify(_status_payload())
    resp.headers["Cache-Control"] = "no-store"
    return resp


@discord_link_bp.route("/account/discord/code", methods=["POST"])
@login_required
def code():
    row = DiscordLinkCode.issue(current_user)
    pretty = f"{row.code[:4]}-{row.code[4:]}"
    data = _status_payload()
    data.update({"code": pretty, "expires_minutes": DiscordLinkCode.TTL_MINUTES,
                 "command": f"/link-account code:{pretty}"})
    resp = jsonify(data)
    resp.headers["Cache-Control"] = "no-store"
    return resp


@discord_link_bp.route("/account/discord/test-dm", methods=["POST"])
@login_required
def test_dm():
    if not current_user.discord_id:
        return jsonify({"ok": False, "error": "Link your Discord account first."}), 400
    status_code, data = bot_call("/discord/dm/test", {"discord_id": current_user.discord_id})
    if status_code == 0:
        return jsonify({"ok": False, "error": "The Discord bot is offline right now. Please try again shortly."}), 503
    data = data or {}
    return jsonify({
        "ok": bool(data.get("dm_ok")),
        "in_guild": bool(data.get("in_guild")),
        "dm_ok": bool(data.get("dm_ok")),
        "error": data.get("error"),
        "invite_url": invite_url(),
    })
