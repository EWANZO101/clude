"""Best-effort Discord webhook notifications. One webhook URL for the
whole deployment (Settings.discord_webhook_url) - not per-community yet,
see api_docs.html's roadmap note.

Every function here is fire-and-forget: a slow or unreachable Discord
never blocks or fails the caller (evidence ingestion, alert ingestion,
BOLO publishing all still succeed if Discord is down). Failures are
logged, never raised.
"""

import json
import urllib.error
import urllib.request

from flask import current_app

from .models import Settings

_COLOR_INFO = 0x22D3EE
_COLOR_ALERT = 0xEF4444
_COLOR_BOLO = 0xF59E0B


def _send(url, embed):
    if not embed.get("url"):
        embed.pop("url", None)  # Discord expects a real URL or no key at all, never null
    body = json.dumps({"embeds": [embed]}).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        urllib.request.urlopen(req, timeout=5)
    except (urllib.error.URLError, TimeoutError) as e:
        current_app.logger.warning("Discord webhook post failed: %s", e)


def _portal_url(path):
    base = current_app.config.get("PORTAL_PUBLIC_URL", "").rstrip("/")
    return f"{base}{path}" if base else None


def notify_evidence(evidence):
    settings = Settings.get()
    if not settings.discord_webhook_url or not settings.discord_notify_evidence:
        return
    _send(
        settings.discord_webhook_url,
        {
            "title": "New evidence submitted",
            "description": evidence.caption or "(no caption)",
            "color": _COLOR_INFO,
            "url": _portal_url(f"/evidence/{evidence.id}"),
            "fields": [{"name": "Officer", "value": evidence.submitter_name or "Unknown", "inline": True}],
        },
    )


def notify_alert(alert):
    settings = Settings.get()
    if not settings.discord_webhook_url or not settings.discord_notify_alerts:
        return
    _send(
        settings.discord_webhook_url,
        {
            "title": f"\N{WARNING SIGN} {alert.alert_type.replace('_', ' ').title()}",
            "description": alert.message or "",
            "color": _COLOR_ALERT,
            "url": _portal_url("/live"),
            "fields": [{"name": "Unit", "value": alert.recorder_name or alert.recorder_id, "inline": True}],
        },
    )


def notify_bolo(bolo):
    settings = Settings.get()
    if not settings.discord_webhook_url or not settings.discord_notify_bolos:
        return
    _send(
        settings.discord_webhook_url,
        {
            "title": f"BOLO: {bolo.subject}",
            "description": bolo.details or "",
            "color": _COLOR_BOLO,
            "url": _portal_url("/assistant"),
            "fields": [{"name": "Published by", "value": bolo.author or "Unknown", "inline": True}],
        },
    )
