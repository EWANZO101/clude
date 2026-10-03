"""
AppDB — HTTP API connector to the CFRP web application.
Replaces the old direct MySQL connection with calls to the REST API.
Only used for application-type tickets (whitelist, police, ems etc).

Authentication: X-API-Key header  (set WHITELIST_API_KEY in .env)
Base URL:       WHITELIST_API_URL  (e.g. https://web.goldenshoresrp.com)
"""

import json
import logging
import os
import requests
from requests.exceptions import RequestException

log = logging.getLogger("cfrp_bot.app_db")

API_BASE_URL: str = os.getenv("WHITELIST_API_URL", "https://web.goldenshoresrp.com").rstrip("/")
API_KEY:      str = os.getenv("WHITELIST_API_KEY", "")

APPLICATION_TICKET_KEYS = {
    "whitelist", "dispatch", "east-customs",
    "ems", "fire", "ls-customs", "police", "tuner-shop",
}

# Hardcoded field label maps per application type.
# Keys match whatever the API sends (field_0, field_1, etc. OR named keys).
# Add/edit these to match your actual form questions.
FIELD_LABELS: dict[str, dict[str, str]] = {
    "whitelist": {
        "field_0":  "Real First Name or Nickname",
        "field_1":  "Age",
        "field_2":  "Banned from another RP server?",
        "field_3":  "How long have you been playing FiveM?",
        "field_4":  "Types of RP servers played before",
        "field_5":  "Favourite role and why",
        "field_6":  "What makes good RP different from bad RP?",
        "field_7":  "Best roleplay experience",
        "field_8":  "What is RDM?",
        "field_9":  "What is VDM?",
        "field_10": "What is Metagaming?",
        "field_11": "What is Powergaming?",
        "field_12": "What is Fail RP?",
        "field_13": "What is New Life Rule?",
        "field_14": "Why is random trolling harmful to a serious RP server?",
    },
    "police": {
        "field_0": "Full Name",
        "field_1": "Age",
        "field_2": "Why do you want to join SAPS?",
        "field_3": "Previous LEO Experience",
        "field_4": "Hours in FiveM",
        "field_5": "RP Style",
        "field_6": "What is Metagaming?",
        "field_7": "What is RDM?",
        "field_8": "What is VDM?",
        "field_9": "Scenario Answer",
    },
    "ems": {
        "field_0": "Full Name",
        "field_1": "Age",
        "field_2": "Why do you want to join EMS?",
        "field_3": "Previous EMS Experience",
        "field_4": "Hours in FiveM",
        "field_5": "What is Metagaming?",
        "field_6": "What is RDM?",
        "field_7": "Scenario Answer",
    },
}

def _headers() -> dict:
    return {"X-API-Key": API_KEY, "Accept": "application/json"}

def _get(path: str, params: dict = None) -> dict | None:
    url = f"{API_BASE_URL}/api{path}"
    try:
        r = requests.get(url, headers=_headers(), params=params, timeout=10)
        if r.status_code == 200:
            return r.json()
        log.warning("AppDB GET %s -> %s: %s", path, r.status_code, r.text[:200])
        return None
    except RequestException as exc:
        log.warning("AppDB GET %s failed: %s", path, exc)
        return None

def _normalise_discord_id(raw) -> str:
    """Strip 'discord:' prefix if present, return plain snowflake string."""
    s = str(raw or "").strip()
    return s[len("discord:"):] if s.startswith("discord:") else s

def _ids_match(api_id, member_id) -> bool:
    return _normalise_discord_id(api_id) == str(member_id).strip()

def _normalise(app: dict, search_slug: str = "") -> dict:
    user      = app.get("user", {}) or {}
    app_type  = app.get("type", {}) or {}
    responses = app.get("responses") or {}
    # Use the slug we searched with as the reliable key; fall back to what the API returns
    api_slug  = app_type.get("slug", "") or app_type.get("key", "") or ""
    slug      = search_slug or api_slug
    return {
        "id":               app.get("id"),
        "status":           app.get("status"),
        "form_data":        json.dumps(responses),
        "denial_reason":    app.get("review_note"),
        "created_at":       app.get("submitted_at"),
        "updated_at":       app.get("reviewed_at") or app.get("submitted_at"),
        "slug":             slug,
        "api_slug":         api_slug,
        "type_name":        app_type.get("name", ""),
        "type_form_fields": json.dumps(app_type.get("fields", [])),
        "username":         user.get("username") or user.get("discord_username", "?"),
        "email":            user.get("email", ""),
        "discord_id":       _normalise_discord_id(user.get("discord_id", "")),
    }

def _search_type(discord_id: str, slug: str, all_matches: bool = False) -> list:
    found = []
    for page in range(1, 6):
        data = _get("/applications", {"type": slug, "page": page})
        if not data:
            break
        apps = data.get("applications", [])
        if not apps:
            break
        for app in apps:
            uid = (app.get("user") or {}).get("discord_id", "")
            if _ids_match(uid, discord_id):
                # Pass the slug we searched with so label lookup is always reliable
                found.append(_normalise(app, search_slug=slug))
                if not all_matches:
                    return found
        if page >= data.get("pages", 1):
            break
    return found

# ── Public API ────────────────────────────────────────────────────────────────

def is_application_type(app_key: str) -> bool:
    return app_key in APPLICATION_TICKET_KEYS

def is_user_linked(discord_id) -> bool:
    """Check if this Discord user is linked on the website.
    Tries both the raw snowflake and the 'discord:' prefixed form,
    since the API may store the ID in either format.
    Falls back to scanning applications if the /users endpoint returns nothing.
    """
    if not API_KEY:
        return False
    raw = str(discord_id).strip()
    # Try raw snowflake
    if _get(f"/users/discord/{raw}") is not None:
        return True
    # Try with discord: prefix (some API versions store it this way)
    if _get(f"/users/discord/discord:{raw}") is not None:
        return True
    # Final fallback: if any application exists for this user the ID is linked
    for slug in list(APPLICATION_TICKET_KEYS):
        results = _search_type(raw, slug, all_matches=False)
        if results:
            return True
    return False

def get_application(discord_id, app_slug: str) -> dict | None:
    if not API_KEY:
        log.error("WHITELIST_API_KEY not set")
        return None
    results = _search_type(str(discord_id), app_slug, all_matches=False)
    return results[0] if results else None

def get_all_applications(discord_id) -> list:
    if not API_KEY:
        log.error("WHITELIST_API_KEY not set")
        return []
    results = []
    for slug in APPLICATION_TICKET_KEYS:
        results.extend(_search_type(str(discord_id), slug, all_matches=True))
    results.sort(key=lambda a: a.get("created_at") or "", reverse=True)
    return results

def _field_sort_key(key: str) -> int:
    """Sort field_0, field_1 … field_14 numerically instead of lexically."""
    try:
        return int(key.split("_")[-1])
    except (ValueError, IndexError):
        return 999


def format_application_embed(app: dict) -> tuple[str, list[tuple]]:
    if not app:
        return "", []

    slug = app.get("slug", "")

    # Build label map: try API-provided field defs first
    try:
        field_defs = json.loads(app.get("type_form_fields") or "[]")
        label_map  = {f["name"]: f["label"] for f in field_defs if "name" in f and "label" in f}
    except Exception:
        label_map = {}

    # Always overlay our hardcoded labels on top — they are more human-readable
    # than whatever the API might return, and fill in any gaps
    hardcoded = FIELD_LABELS.get(slug, {})
    if hardcoded:
        label_map = {**label_map, **hardcoded}

    # If we still have nothing, try matching by app_key stored during search
    if not label_map:
        api_slug = app.get("api_slug", "")
        hardcoded2 = FIELD_LABELS.get(api_slug, {})
        if hardcoded2:
            label_map = hardcoded2
            log.debug("format_embed: used api_slug '%s' for label lookup", api_slug)

    log.debug("format_embed: slug='%s' label_map keys=%s", slug, list(label_map.keys())[:5])

    try:
        form_data = json.loads(app["form_data"]) if app.get("form_data") else {}
    except Exception:
        form_data = {}

    header = (
        f"**Application #{app['id']}** — {app['type_name']}\n"
        f"Submitted by **{app.get('username', '?')}**"
        + (f" ({app.get('email', '')})" if app.get("email") else "")
        + f"\nSubmitted: {str(app['created_at'] or '')[:10]}"
    )

    fields = []
    # Sort keys numerically so field_0 … field_14 appear in the right order
    for key in sorted(form_data.keys(), key=_field_sort_key):
        value = form_data[key]
        if not value:
            continue
        label = label_map.get(key) or key.replace("_", " ").title()
        value_str = str(value)[:1020] + ("…" if len(str(value)) > 1020 else "")
        fields.append((label, value_str))

    if app.get("denial_reason"):
        fields.append(("❌ Denial Reason", str(app["denial_reason"])))

    return header, fields


def get_user_limits(discord_id: str) -> list[dict]:
    """
    Fetch all active UserLimit records for a Discord user from the web app API.

    Calls GET /api/users/discord/<discord_id>/limits
    Returns a list of limit dicts (may be empty). Never raises.

    Each dict contains at minimum:
        id, label, source, no_firearm, no_create_priority,
        no_join_priority, notes, expires_at, created_at, is_active
    """
    if not API_KEY:
        log.warning("get_user_limits: WHITELIST_API_KEY not set")
        return []

    raw = str(discord_id).strip().lstrip("discord:")

    # Try raw snowflake first, then prefixed form
    for attempt in (raw, f"discord:{raw}"):
        data = _get(f"/users/discord/{attempt}/limits", params={"active": "1"})
        if data is not None:
            limits = data if isinstance(data, list) else data.get("limits", [])
            log.debug("get_user_limits: found %d limits for discord_id=%s", len(limits), raw)
            return limits

    log.debug("get_user_limits: no limits found for discord_id=%s", raw)
    return []