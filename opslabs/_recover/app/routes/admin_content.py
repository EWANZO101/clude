"""Homepage content editor — /admin/content/

Lets admins edit each homepage section live, with a preview in a side
panel. Saves into the SiteContent table (key = section name, value = JSON).
"""
from functools import wraps
from flask import Blueprint, render_template, request, jsonify, redirect, url_for, abort
from flask_login import login_required, current_user
from .. import db
from ..models_admin import SiteContent

content_bp = Blueprint("content", __name__)


def admin_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if not getattr(current_user, 'is_admin', False):
            abort(403)
        return f(*a, **kw)
    return wrapper


# Section schemas — drives the form rendering. Each section has:
#   title  — human title for the editor
#   icon   — SVG path string for the section icon
#   fields — ordered list of {key, label, kind, help?, placeholder?}
#   list   — if set, this section is a list-of-items (services, FAQ, steps)
SECTION_SCHEMA = {
    "hero": {
        "title": "Hero",
        "desc": "The big headline area at the very top of the homepage.",
        "fields": [
            {"key": "eyebrow",    "label": "Eyebrow chip",  "kind": "text",
             "help": "Small chip above the headline.", "placeholder": "Live · Web · FiveM · …"},
            {"key": "headline_a", "label": "Headline part 1", "kind": "text",
             "placeholder": "Build. Support."},
            {"key": "headline_b", "label": "Headline part 2 (gradient)", "kind": "text",
             "help": "Shown in the brand colour gradient.",
             "placeholder": "Scale."},
            {"key": "headline_c", "label": "Headline part 3", "kind": "text",
             "placeholder": "Together."},
            {"key": "subhead",    "label": "Subheadline", "kind": "textarea",
             "help": "Main descriptive paragraph under the headline.",
             "rows": 3},
            {"key": "small",      "label": "Small caption", "kind": "text",
             "help": "Smaller line under the subheadline."},
            {"key": "stat_a_value", "label": "Stat 1 — value", "kind": "text", "placeholder": "6"},
            {"key": "stat_a_label", "label": "Stat 1 — label", "kind": "text", "placeholder": "Service Lines"},
            {"key": "stat_b_value", "label": "Stat 2 — value", "kind": "text", "placeholder": "≤5s"},
            {"key": "stat_b_label", "label": "Stat 2 — label", "kind": "text", "placeholder": "Live Sync"},
            {"key": "stat_c_value", "label": "Stat 3 — value", "kind": "text", "placeholder": "24/7"},
            {"key": "stat_c_label", "label": "Stat 3 — label", "kind": "text", "placeholder": "Always-On Bot"},
        ],
    },

    "metrics": {
        "title": "Metrics strip",
        "desc": "Four numbers under the hero — tickets handled, response time, etc.",
        "fields": [
            {"key": "a_label", "label": "Stat 1 — label", "kind": "text"},
            {"key": "a_value", "label": "Stat 1 — value", "kind": "text"},
            {"key": "a_sub",   "label": "Stat 1 — caption", "kind": "text"},
            {"key": "b_label", "label": "Stat 2 — label", "kind": "text"},
            {"key": "b_value", "label": "Stat 2 — value", "kind": "text"},
            {"key": "b_sub",   "label": "Stat 2 — caption", "kind": "text"},
            {"key": "c_label", "label": "Stat 3 — label", "kind": "text"},
            {"key": "c_value", "label": "Stat 3 — value", "kind": "text"},
            {"key": "c_sub",   "label": "Stat 3 — caption", "kind": "text"},
            {"key": "d_label", "label": "Stat 4 — label", "kind": "text"},
            {"key": "d_value", "label": "Stat 4 — value", "kind": "text"},
            {"key": "d_sub",   "label": "Stat 4 — caption", "kind": "text"},
        ],
    },

    "services_intro": {
        "title": "Services — intro",
        "desc": "Heading + tagline above the services grid.",
        "fields": [
            {"key": "eyebrow",  "label": "Eyebrow chip", "kind": "text"},
            {"key": "headline", "label": "Heading", "kind": "text"},
            {"key": "subhead",  "label": "Subheading", "kind": "textarea", "rows": 2},
        ],
    },

    "services": {
        "title": "Services list",
        "desc": "The 6 service cards on the homepage. Reorder, edit, add or remove.",
        "list": True,
        "item_fields": [
            {"key": "name",        "label": "Service name", "kind": "text"},
            {"key": "desc",        "label": "Description",  "kind": "textarea", "rows": 2},
            {"key": "tech",        "label": "Tech-stack tags",
             "kind": "tags",
             "help": "Comma-separated. Shown as small pills under the description."},
            {"key": "highlighted", "label": "Highlight this card",
             "kind": "bool",
             "help": "Tints the card in brand colour (use for the catch-all)."},
        ],
    },

    "how_it_works": {
        "title": "How it works",
        "desc": "The three-step flow with numbered cards.",
        "fields": [
            {"key": "eyebrow",  "label": "Eyebrow chip", "kind": "text"},
            {"key": "headline", "label": "Heading", "kind": "text"},
            {"key": "subhead",  "label": "Subheading", "kind": "text"},
        ],
        "sublist_key": "steps",
        "sublist_title": "Steps",
        "sublist_fields": [
            {"key": "n",     "label": "Step number", "kind": "int"},
            {"key": "title", "label": "Title", "kind": "text"},
            {"key": "body",  "label": "Description", "kind": "textarea", "rows": 2},
        ],
    },

    "why_us": {
        "title": "Why us",
        "desc": "The longer pitch section with bullets + feature cards.",
        "fields": [
            {"key": "eyebrow",  "label": "Eyebrow chip", "kind": "text"},
            {"key": "headline", "label": "Heading", "kind": "text"},
            {"key": "lead",     "label": "Lead paragraph", "kind": "textarea", "rows": 2},
            {"key": "body",     "label": "Body paragraph", "kind": "textarea", "rows": 3},
        ],
        "multi_sublists": [
            {
                "key": "bullets",
                "title": "Checked bullet list",
                "fields": [{"key": "_str", "label": "Bullet (markdown ok)", "kind": "text"}],
                "scalar": True,
            },
            {
                "key": "features",
                "title": "Feature cards",
                "fields": [
                    {"key": "title", "label": "Card title", "kind": "text"},
                    {"key": "body",  "label": "Card body",  "kind": "textarea", "rows": 2},
                ],
            },
        ],
    },

    "faq": {
        "title": "FAQ",
        "desc": "Expandable question / answer pairs at the bottom of the page.",
        "fields": [
            {"key": "eyebrow",  "label": "Eyebrow chip", "kind": "text"},
            {"key": "headline", "label": "Heading", "kind": "text"},
        ],
        "sublist_key": "items",
        "sublist_title": "Questions",
        "sublist_fields": [
            {"key": "q", "label": "Question", "kind": "text"},
            {"key": "a", "label": "Answer", "kind": "textarea", "rows": 3},
        ],
    },

    "cta": {
        "title": "Bottom CTA",
        "desc": "The call-to-action card at the bottom of the homepage.",
        "fields": [
            {"key": "headline", "label": "Heading", "kind": "text"},
            {"key": "body",     "label": "Body", "kind": "textarea", "rows": 2},
        ],
    },
}

SECTION_ORDER = [
    "hero", "metrics", "services_intro", "services",
    "how_it_works", "why_us", "faq", "cta",
]


# ════════════════════════════════════════════════════════════════════════
@content_bp.route("/")
@admin_required
def editor():
    section = request.args.get("section", "hero")
    if section not in SECTION_SCHEMA:
        section = "hero"

    schema = SECTION_SCHEMA[section]
    data = SiteContent.get_data(section, {})

    return render_template(
        "admin/content_editor.html",
        section=section,
        schema=schema,
        data=data,
        sections=[(k, SECTION_SCHEMA[k]["title"]) for k in SECTION_ORDER],
    )


@content_bp.route("/save/<section>", methods=["POST"])
@admin_required
def save(section):
    if section not in SECTION_SCHEMA:
        return jsonify({"error": "unknown section"}), 400

    schema = SECTION_SCHEMA[section]
    body = request.get_json(silent=True) or {}
    if not isinstance(body, dict):
        return jsonify({"error": "expected JSON object"}), 400

    # Validate and coerce per schema
    clean = {}
    for f in schema.get("fields", []):
        clean[f["key"]] = _coerce(body.get(f["key"]), f["kind"])

    if schema.get("list"):
        items_in = body.get("items", [])
        clean["items"] = [_coerce_item(i, schema["item_fields"]) for i in items_in if i]

    if schema.get("sublist_key"):
        k = schema["sublist_key"]
        items_in = body.get(k, [])
        clean[k] = [_coerce_item(i, schema["sublist_fields"]) for i in items_in if i]

    for sub in schema.get("multi_sublists", []):
        items_in = body.get(sub["key"], [])
        if sub.get("scalar"):
            # list of strings
            clean[sub["key"]] = [str(i).strip() for i in items_in if str(i).strip()]
        else:
            clean[sub["key"]] = [_coerce_item(i, sub["fields"]) for i in items_in if i]

    SiteContent.set_data(section, clean, user_id=current_user.id)
    return jsonify({"ok": True, "saved_at": SiteContent.get(section).updated_at.isoformat()})


# ════════════════════════════════════════════════════════════════════════
def _coerce(val, kind: str):
    if val is None:
        return "" if kind in ("text", "textarea") else val
    if kind == "bool":
        return val in (True, "true", "1", "on", "yes")
    if kind == "int":
        try: return int(val)
        except (TypeError, ValueError): return 0
    if kind == "tags":
        if isinstance(val, list):
            return [str(s).strip() for s in val if str(s).strip()]
        if isinstance(val, str):
            return [s.strip() for s in val.split(",") if s.strip()]
        return []
    return str(val).strip()


def _coerce_item(item: dict, fields: list[dict]) -> dict:
    if not isinstance(item, dict):
        # scalar list — value comes as a string under "_str"
        return {"_str": str(item).strip()}
    out = {}
    for f in fields:
        out[f["key"]] = _coerce(item.get(f["key"]), f["kind"])
    return out
