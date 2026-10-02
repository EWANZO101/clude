"""
Local Admin AI — knowledge base (Part 1).

Spec section 11 asks for retrieval instead of stuffing the whole app
into the prompt, and section 6 asks the AI to answer from the app's
*actual* live configuration, not just static docs. This module does
both with no extra ML dependency (no embedding model, no vector DB) --
appropriate for a small CPU-only model on kiosk-grade hardware:

  - STATIC_DOCS: short, hand-written entries about what each area of
    the app does (this is what section 5 calls the "documentation").
    Scope note: this kiosk codebase is the Kiosk half of the spec only
    (Dashboard / Items / Tools / Low Stock / Projects / Welding Wire /
    Barcode scanning / Sync Log). Admin Panel concepts from the spec
    (Page Builder, Sidebar Builder, cross-app user/role management)
    live in the separate stocktool-admin service and aren't indexed
    here -- see app/ai_tools.py's docstring.
  - live_snapshot(): pulls real counts/status from the DB via the same
    read-only tools in ai_tools.py, so "what pages do we have" / "what's
    our stock situation" answers reflect this actual installation.
  - retrieve(): plain keyword scoring over both. No semantic search --
    deliberately simple so Part 1 has zero new failure modes; an
    embedding-based upgrade can slot in later behind the same
    retrieve() signature without touching callers.
"""
from __future__ import annotations

import re
import threading

from app import ai_tools

STATIC_DOCS: list[dict] = [
    {
        "id": "dashboard",
        "keywords": ["dashboard", "home", "overview"],
        "text": "The Dashboard is the kiosk's home screen. It shows quick counts "
                "(items, tools, projects) and shortcuts into Items, Tools, Low "
                "Stock, Projects, Welding Wire, and Barcode scanning.",
    },
    {
        "id": "items",
        "keywords": ["item", "items", "stock", "quantity", "consumable"],
        "text": "The Items page lists consumable stock (name, SKU, quantity, unit, "
                "category). Quantities are adjusted by barcode scan or manually; "
                "each adjustment can be tagged with who made it and which project "
                "it was for.",
    },
    {
        "id": "low_stock",
        "keywords": ["low stock", "reorder", "running low"],
        "text": "Low Stock shows items at or below the reorder threshold so staff "
                "can flag them for restocking.",
    },
    {
        "id": "tools",
        "keywords": ["tool", "tools", "checkout", "checked out", "maintenance"],
        "text": "The Tools page tracks individual tools/assets: status (available, "
                "checked out, maintenance), who has one checked out and for which "
                "project, purchase price, and maintenance history. Usage/maintenance "
                "hours and cost feed a replacement-candidate flag when a tool is "
                "costing more in upkeep than it's returning in use.",
    },
    {
        "id": "welding_wire",
        "keywords": ["wire", "welding", "coil", "spool"],
        "text": "Welding Wire tracks individual wire coils by barcode: initial vs "
                "current weight, who has one checked out, and which project it's "
                "being used on. A coil can't be checked out to two people at once.",
    },
    {
        "id": "projects",
        "keywords": ["project", "projects"],
        "text": "Projects group tool checkouts, wire usage, and item consumption so "
                "usage and variance can be reported per project.",
    },
    {
        "id": "barcode",
        "keywords": ["barcode", "scan", "scanning"],
        "text": "Barcode scanning is used throughout the kiosk to identify items, "
                "tools, and wire coils quickly at a touch screen instead of typing.",
    },
    {
        "id": "sync",
        "keywords": ["sync", "syncing", "cloud", "offline"],
        "text": "The kiosk works fully offline and syncs to the cloud API in the "
                "background when a connection is available. The Sync Log records "
                "every push/pull attempt, its status, and any error message.",
    },
    {
        "id": "users_roles",
        "keywords": ["user", "users", "role", "roles", "permission", "permissions", "login", "badge"],
        "text": "Kiosk users log in with a username or badge code (no password). "
                "Each user has a role (e.g. admin, stock_user); an admin can enable "
                "or disable login for a role, and only admin-role users can see "
                "sync logs or other users' permission settings.",
    },
    {
        "id": "backups",
        "keywords": ["backup", "backups", "restore"],
        "text": "The kiosk periodically uploads database backups to "
                "stocktoolsetup.opslabsystems.cloud once paired, so the install can "
                "be restored or migrated to a new machine.",
    },
    {
        "id": "ai_assistant",
        "keywords": ["ai", "assistant", "admin ai"],
        "text": "The Admin AI is a built-in, fully local assistant for this "
                "application only -- it has no general internet knowledge, runs "
                "entirely on this machine with no cloud AI account or API key, and "
                "in its default configuration can only read data, never change it.",
    },
]


def _score(text_lower: str, keywords: list[str], query_lower: str) -> int:
    score = sum(1 for kw in keywords if kw in query_lower)
    # light fallback so a query that only matches the body text (not a
    # curated keyword) still has a chance of surfacing
    if score == 0 and any(word in text_lower for word in re.findall(r"[a-z]{4,}", query_lower)):
        score = 1
    return score


# ── Automatic knowledge updates (Part 3 — spec section 12) ────────────
#
# This kiosk has no Page Builder/Sidebar Builder (that's an Admin Panel
# concept living in the separate stocktool-admin service), so "a new
# feature was created, index it automatically" maps onto this app's own
# admin-extensible configuration instead: the WireCode catalogue (spec
# items 7/8 -- admins add/rename/deactivate wire types live) and the
# per-level MaintenanceAlertThreshold settings. Both get turned into
# knowledge-base docs automatically, cached, and invalidated the moment
# an admin changes either -- nobody has to remember to "rebuild the AI"
# after adding a wire code, though section 16's manual rebuild is also
# wired up below for anyone who wants to force it (e.g. after a bulk
# import that doesn't go through the ORM event hooks).

_dynamic_cache_lock = threading.Lock()
_dynamic_cache: list[dict] | None = None  # None = needs rebuild


def invalidate_dynamic_index() -> None:
    global _dynamic_cache
    with _dynamic_cache_lock:
        _dynamic_cache = None


def _build_dynamic_docs() -> list[dict]:
    from app.models import WireCode, MaintenanceAlertThreshold

    docs = []

    active_codes = WireCode.query.filter_by(is_active=True).order_by(WireCode.name).all()
    if active_codes:
        names = ", ".join(c.name for c in active_codes)
        docs.append({
            "id": "dynamic_wire_codes",
            "keywords": ["wire code", "wire type", "wire codes"],
            "text": f"This installation's active welding-wire codes are: {names}. "
                    f"Admins manage this list from the wire codes screen -- deactivating "
                    f"a code keeps existing coils/history valid without deleting it.",
        })

    thresholds = MaintenanceAlertThreshold.query.order_by(MaintenanceAlertThreshold.level).all()
    if thresholds:
        lines = ", ".join(f"level {t.level}: {t.threshold_hours}h" for t in thresholds)
        docs.append({
            "id": "dynamic_maintenance_thresholds",
            "keywords": ["maintenance threshold", "overdue", "maintenance level"],
            "text": f"This installation's configured maintenance alert thresholds are: "
                    f"{lines}. A tool sitting in a maintenance level longer than its "
                    f"threshold is flagged as overdue for attention.",
        })

    return docs


def dynamic_docs() -> list[dict]:
    global _dynamic_cache
    with _dynamic_cache_lock:
        if _dynamic_cache is None:
            _dynamic_cache = _build_dynamic_docs()
        return _dynamic_cache


def register_auto_reindex_hooks() -> None:
    """Call once at app startup (see app/__init__.py). Anything that
    changes the two tables above -- through any code path, not just a
    specific route -- invalidates the cache, so the next retrieve()
    rebuilds it from the current DB state."""
    from sqlalchemy import event
    from app.models import WireCode, MaintenanceAlertThreshold

    def _dirty(*_args, **_kwargs):
        invalidate_dynamic_index()

    for model in (WireCode, MaintenanceAlertThreshold):
        event.listens_for(model, "after_insert")(_dirty)
        event.listens_for(model, "after_update")(_dirty)
        event.listens_for(model, "after_delete")(_dirty)


def retrieve(query: str, top_k: int = 3, context_page: str | None = None) -> list[str]:
    """context_page (spec section 13, "AI Help Everywhere"): the id of
    the Admin/Kiosk page the user was on when they clicked "Ask Admin
    AI" (e.g. "tools", "welding_wire") -- its doc is always included
    first, regardless of keyword match, since the question is likely
    about the screen in front of them even if they don't name it."""
    query_lower = query.lower()
    scored = []
    pinned_text = None
    all_docs = STATIC_DOCS + dynamic_docs()
    for doc in all_docs:
        if context_page and doc["id"] == context_page:
            pinned_text = doc["text"]
            continue
        s = _score(doc["text"].lower(), doc["keywords"], query_lower)
        if s > 0:
            scored.append((s, doc["text"]))
    scored.sort(key=lambda pair: pair[0], reverse=True)
    results = [text for _, text in scored[: top_k - 1 if pinned_text else top_k]]
    if pinned_text:
        results.insert(0, pinned_text)
    return results


def live_snapshot(role: str, db_access_level: str = "detail") -> str:
    """A short, always-current line about this installation, appended
    to every prompt regardless of the keyword match above -- this is
    the "system-aware" part of section 6, cheap enough to include on
    every request rather than trying to detect when it's relevant.
    Respects db_access_level=="none" (Part 5) by simply omitting itself."""
    try:
        ai_tools.check_db_access_level("get_kiosk_status", db_access_level)
        status = ai_tools.get_kiosk_status(role)
    except Exception:
        return ""
    return (
        f"This installation currently has {status['item_count']} stock items, "
        f"{status['tool_count']} tools, {status['project_count']} projects, and "
        f"{status['user_count']} active users."
    )
