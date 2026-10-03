"""
Ops Labs Public REST API (v1)
=============================

Auth: send `Authorization: Bearer <api_key>` (or `X-API-Key: <api_key>`).
Create keys in Admin → API Keys. Scopes: read, write, admin.

All responses are JSON. Errors look like:
    { "error": "human readable", "code": "snake_case_code" }

Endpoints
---------
GET    /api/v1/health
GET    /api/v1/me
GET    /api/v1/companies
POST   /api/v1/companies                (admin)
GET    /api/v1/companies/<id>
PATCH  /api/v1/companies/<id>           (admin)
DELETE /api/v1/companies/<id>           (admin)
GET    /api/v1/companies/<id>/categories
POST   /api/v1/companies/<id>/categories (admin)

GET    /api/v1/users                    (admin)
POST   /api/v1/users                    (admin)
GET    /api/v1/users/<id>               (admin)
PATCH  /api/v1/users/<id>               (admin)
DELETE /api/v1/users/<id>               (admin)
POST   /api/v1/users/<id>/reset-password (admin)

GET    /api/v1/tickets                  (read)
POST   /api/v1/tickets                  (write)
GET    /api/v1/tickets/<id>             (read)
PATCH  /api/v1/tickets/<id>             (write)
DELETE /api/v1/tickets/<id>             (admin)
GET    /api/v1/tickets/<id>/messages    (read)
POST   /api/v1/tickets/<id>/messages    (write)
"""
from datetime import datetime
from functools import wraps
from flask import Blueprint, request, jsonify, g, current_app
from .. import db
from ..models import (User, Company, TicketCategory,
                      Ticket, TicketMessage, PasswordResetToken)
from ..models_api import ApiKey

api_bp = Blueprint("api", __name__)


# ---------------------------------------------------------------------------
# Auth + helpers
# ---------------------------------------------------------------------------
def _extract_key():
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth.split(None, 1)[1].strip()
    return request.headers.get("X-API-Key", "").strip()


def require_scope(scope):
    def deco(f):
        @wraps(f)
        def wrapper(*a, **kw):
            raw = _extract_key()
            if not raw:
                return err("Missing API key", "missing_key", 401)
            key = ApiKey.verify(raw)
            if not key:
                return err("Invalid or revoked API key", "invalid_key", 401)
            if not key.can(scope):
                return err(f"Scope '{scope}' required (key has '{key.scope}')",
                           "insufficient_scope", 403)
            g.api_key = key
            return f(*a, **kw)
        return wrapper
    return deco


def err(msg, code="error", status=400):
    return jsonify({"error": msg, "code": code}), status


def ok(payload=None, status=200):
    if payload is None:
        payload = {"ok": True}
    return jsonify(payload), status


def _notify_bot(endpoint, payload):
    """Best-effort notify the Discord bot bridge."""
    import requests
    url = current_app.config["DISCORD_BOT_URL"].rstrip("/") + endpoint
    headers = {"X-Bridge-Key": current_app.config["DISCORD_BRIDGE_KEY"]}
    try:
        r = requests.post(url, json=payload, headers=headers, timeout=6)
        if r.ok:
            return r.json()
    except requests.RequestException:
        pass
    return None


# ---------------------------------------------------------------------------
# Health + identity
# ---------------------------------------------------------------------------
@api_bp.route("/health")
def health():
    return ok({"status": "ok", "service": "opslabs-api",
               "version": "1.0", "time": datetime.utcnow().isoformat()})


@api_bp.route("/me")
@require_scope("read")
def me():
    k = g.api_key
    return ok({
        "key_id": k.id,
        "label": k.label,
        "scope": k.scope,
        "owner": k.owner_id,
        "request_count": k.request_count,
        "last_used_at": k.last_used_at.isoformat() if k.last_used_at else None,
    })


# ---------------------------------------------------------------------------
# Companies
# ---------------------------------------------------------------------------
def _company_dict(c):
    return {
        "id": c.id, "name": c.name, "slug": c.slug,
        "tagline": c.tagline, "description": c.description,
        "logo_url": c.logo_url, "accent_color": c.accent_color,
        "is_active": c.is_active,
        "created_at": c.created_at.isoformat() if c.created_at else None,
    }


@api_bp.route("/companies", methods=["GET"])
@require_scope("read")
def list_companies():
    cs = Company.query.order_by(Company.name).all()
    return ok({"companies": [_company_dict(c) for c in cs]})


@api_bp.route("/companies", methods=["POST"])
@require_scope("admin")
def create_company():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    slug = (data.get("slug") or "").strip()
    if not name or not slug:
        return err("name and slug are required", "validation")
    if Company.query.filter_by(slug=slug).first():
        return err("slug already exists", "duplicate_slug", 409)
    c = Company(
        name=name, slug=slug,
        tagline=data.get("tagline"),
        description=data.get("description"),
        logo_url=data.get("logo_url"),
        accent_color=data.get("accent_color", "#2196f3"),
        is_active=bool(data.get("is_active", True)),
    )
    db.session.add(c)
    db.session.commit()
    return ok(_company_dict(c), 201)


@api_bp.route("/companies/<int:cid>", methods=["GET"])
@require_scope("read")
def get_company(cid):
    c = Company.query.get_or_404(cid)
    return ok(_company_dict(c))


@api_bp.route("/companies/<int:cid>", methods=["PATCH"])
@require_scope("admin")
def update_company(cid):
    c = Company.query.get_or_404(cid)
    data = request.get_json(silent=True) or {}
    for field in ("name", "tagline", "description", "logo_url", "accent_color"):
        if field in data:
            setattr(c, field, data[field])
    if "is_active" in data:
        c.is_active = bool(data["is_active"])
    if "slug" in data and data["slug"] != c.slug:
        if Company.query.filter_by(slug=data["slug"]).first():
            return err("slug already exists", "duplicate_slug", 409)
        c.slug = data["slug"]
    db.session.commit()
    return ok(_company_dict(c))


@api_bp.route("/companies/<int:cid>", methods=["DELETE"])
@require_scope("admin")
def delete_company(cid):
    c = Company.query.get_or_404(cid)
    if c.tickets.count() > 0:
        return err("company has tickets; deactivate instead", "has_tickets", 409)
    db.session.delete(c)
    db.session.commit()
    return ok({"deleted": cid})


@api_bp.route("/companies/<int:cid>/categories", methods=["GET"])
@require_scope("read")
def list_categories(cid):
    Company.query.get_or_404(cid)
    cats = TicketCategory.query.filter_by(company_id=cid).all()
    return ok({"categories": [
        {"id": k.id, "name": k.name, "description": k.description,
         "is_active": k.is_active} for k in cats
    ]})


@api_bp.route("/companies/<int:cid>/categories", methods=["POST"])
@require_scope("admin")
def create_category(cid):
    Company.query.get_or_404(cid)
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return err("name required", "validation")
    cat = TicketCategory(
        company_id=cid,
        name=name,
        description=data.get("description"),
        is_active=bool(data.get("is_active", True)),
    )
    db.session.add(cat)
    db.session.commit()
    return ok({"id": cat.id, "name": cat.name,
               "description": cat.description, "is_active": cat.is_active}, 201)


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------
def _user_dict(u):
    return {
        "id": u.id, "username": u.username, "email": u.email,
        "role": u.role, "is_active": u.is_active,
        "discord_id": u.discord_id, "discord_username": u.discord_username,
        "created_at": u.created_at.isoformat() if u.created_at else None,
        "last_login_at": u.last_login_at.isoformat() if u.last_login_at else None,
    }


@api_bp.route("/users", methods=["GET"])
@require_scope("admin")
def list_users():
    us = User.query.order_by(User.username).all()
    return ok({"users": [_user_dict(u) for u in us]})


@api_bp.route("/users", methods=["POST"])
@require_scope("admin")
def create_user():
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    email = (data.get("email") or "").strip().lower()
    password = data.get("password") or ""
    if not (username and email and password):
        return err("username, email, password required", "validation")
    if User.query.filter((User.username == username) | (User.email == email)).first():
        return err("username or email already exists", "duplicate", 409)
    u = User(
        username=username, email=email,
        role=data.get("role", "user"),
        is_active=bool(data.get("is_active", True)),
        discord_id=data.get("discord_id") or None,
        discord_username=data.get("discord_username") or None,
    )
    u.set_password(password)
    db.session.add(u)
    db.session.commit()
    return ok(_user_dict(u), 201)


@api_bp.route("/users/<int:uid>", methods=["GET"])
@require_scope("admin")
def get_user(uid):
    u = User.query.get_or_404(uid)
    return ok(_user_dict(u))


@api_bp.route("/users/<int:uid>", methods=["PATCH"])
@require_scope("admin")
def update_user(uid):
    u = User.query.get_or_404(uid)
    data = request.get_json(silent=True) or {}
    if "username" in data:
        u.username = data["username"].strip()
    if "email" in data:
        u.email = data["email"].strip().lower()
    if "role" in data and data["role"] in ("user", "staff", "admin"):
        u.role = data["role"]
    if "is_active" in data:
        u.is_active = bool(data["is_active"])
    if "discord_id" in data:
        u.discord_id = data["discord_id"] or None
    if "discord_username" in data:
        u.discord_username = data["discord_username"] or None
    if "password" in data and data["password"]:
        u.set_password(data["password"])
    db.session.commit()
    return ok(_user_dict(u))


@api_bp.route("/users/<int:uid>", methods=["DELETE"])
@require_scope("admin")
def delete_user(uid):
    u = User.query.get_or_404(uid)
    db.session.delete(u)
    db.session.commit()
    return ok({"deleted": uid})


@api_bp.route("/users/<int:uid>/reset-password", methods=["POST"])
@require_scope("admin")
def api_reset_password(uid):
    """mode=manual {password} or mode=token (returns reset token)."""
    u = User.query.get_or_404(uid)
    data = request.get_json(silent=True) or {}
    mode = data.get("mode", "token")
    if mode == "manual":
        pw = data.get("password", "")
        if len(pw) < 4:
            return err("password too short", "validation")
        u.set_password(pw)
        db.session.commit()
        return ok({"mode": "manual", "user": u.username})
    elif mode == "token":
        tok = PasswordResetToken.create_for(u)
        return ok({"mode": "token", "token": tok.token,
                   "expires_at": tok.expires_at.isoformat(),
                   "user": u.username})
    return err("bad mode (manual|token)", "validation")


# ---------------------------------------------------------------------------
# Tickets
# ---------------------------------------------------------------------------
@api_bp.route("/tickets", methods=["GET"])
@require_scope("read")
def list_tickets():
    q = Ticket.query
    status = request.args.get("status")
    if status in ("open", "pending", "closed"):
        q = q.filter_by(status=status)
    company_id = request.args.get("company_id", type=int)
    if company_id:
        q = q.filter_by(company_id=company_id)
    user_id = request.args.get("user_id", type=int)
    if user_id:
        q = q.filter_by(user_id=user_id)
    limit = min(int(request.args.get("limit", 50)), 500)
    offset = int(request.args.get("offset", 0))
    total = q.count()
    items = q.order_by(Ticket.updated_at.desc()).offset(offset).limit(limit).all()
    return ok({
        "tickets": [t.to_dict() for t in items],
        "total": total, "limit": limit, "offset": offset,
    })


@api_bp.route("/tickets", methods=["POST"])
@require_scope("write")
def api_create_ticket():
    data = request.get_json(silent=True) or {}
    user_id = data.get("user_id")
    subject = (data.get("subject") or "").strip()
    body = (data.get("body") or "").strip()
    company_id = data.get("company_id")
    category_id = data.get("category_id")
    priority = data.get("priority", "normal")

    if not (user_id and subject and body and company_id):
        return err("user_id, subject, body, company_id required", "validation")
    user = User.query.get(user_id)
    if not user:
        return err("user_id not found", "not_found", 404)
    if not Company.query.get(company_id):
        return err("company_id not found", "not_found", 404)

    t = Ticket(
        user_id=user_id, company_id=company_id,
        category_id=category_id, subject=subject,
        priority=priority, status="open",
    )
    db.session.add(t)
    db.session.flush()
    db.session.add(TicketMessage(
        ticket_id=t.id, user_id=user_id,
        source="api", body=body,
    ))
    db.session.commit()

    # Tell the bot
    result = _notify_bot("/discord/ticket/create", {
        "ticket_id": t.id,
        "subject": subject,
        "category": t.category.name if t.category else "General",
        "company": t.company.name if t.company else "OpsLab Systems",
        "owner": user.username,
        "owner_discord_id": user.discord_id,
        "priority": priority,
        "initial_message": body,
    })
    if result and result.get("channel_id"):
        t.discord_channel_id = result["channel_id"]
        db.session.commit()

    from ..discord_dm import notify_staff
    notify_staff(t, kind="new", body=body, author=user.username, via="Discord panel")

    # ── FIX: build response AFTER discord_channel_id is saved so the bot
    # (and any API caller) sees it on creation.
    return ok(t.to_dict(include_messages=True), 201)


@api_bp.route("/tickets/<int:tid>", methods=["GET"])
@require_scope("read")
def api_get_ticket(tid):
    t = Ticket.query.get_or_404(tid)
    return ok(t.to_dict(include_messages=True))


@api_bp.route("/tickets/<int:tid>", methods=["PATCH"])
@require_scope("write")
def api_update_ticket(tid):
    t = Ticket.query.get_or_404(tid)
    data = request.get_json(silent=True) or {}
    changed = False
    if "subject" in data:
        t.subject = data["subject"].strip(); changed = True
    if "priority" in data and data["priority"] in ("low", "normal", "high", "urgent"):
        t.priority = data["priority"]; changed = True
    if "status" in data and data["status"] in ("open", "pending", "closed"):
        t.status = data["status"]
        t.closed_at = datetime.utcnow() if data["status"] == "closed" else None
        changed = True
        if t.discord_channel_id:
            _notify_bot("/discord/ticket/status", {
                "channel_id": t.discord_channel_id,
                "ticket_id": t.id,
                "status": t.status,
                "actor": "api",
            })
    if "assigned_to_id" in data:
        t.assigned_to_id = data["assigned_to_id"] or None; changed = True
    if "category_id" in data:
        t.category_id = data["category_id"] or None; changed = True
    if changed:
        t.updated_at = datetime.utcnow()
        db.session.commit()
    return ok(t.to_dict())


@api_bp.route("/tickets/<int:tid>", methods=["DELETE"])
@require_scope("admin")
def api_delete_ticket(tid):
    t = Ticket.query.get_or_404(tid)
    db.session.delete(t)
    db.session.commit()
    return ok({"deleted": tid})


# ---------------------------------------------------------------------------
# Ticket messages
# ---------------------------------------------------------------------------
@api_bp.route("/tickets/<int:tid>/messages", methods=["GET"])
@require_scope("read")
def api_list_messages(tid):
    t = Ticket.query.get_or_404(tid)
    since_id = request.args.get("since_id", type=int, default=0)
    include_internal = request.args.get("include_internal") == "1"
    q = TicketMessage.query.filter(
        TicketMessage.ticket_id == t.id,
        TicketMessage.id > since_id,
    )
    if not include_internal:
        q = q.filter(TicketMessage.is_internal.is_(False))
    msgs = q.order_by(TicketMessage.id.asc()).all()
    return ok({"ticket_id": t.id,
               "messages": [m.to_dict() for m in msgs]})


@api_bp.route("/tickets/<int:tid>/messages", methods=["POST"])
@require_scope("write")
def api_post_message(tid):
    t = Ticket.query.get_or_404(tid)
    if t.status == "closed":
        return err("ticket is closed", "closed", 400)
    data = request.get_json(silent=True) or {}
    body = (data.get("body") or "").strip()
    if not body:
        return err("body required", "validation")
    user_id = data.get("user_id")
    is_internal = bool(data.get("is_internal", False))
    author_label = data.get("author") or "api"

    m = TicketMessage(
        ticket_id=t.id, user_id=user_id,
        source="api",
        body=body,
        is_internal=is_internal,
        discord_author=author_label if not user_id else None,
    )
    db.session.add(m)
    t.updated_at = datetime.utcnow()
    db.session.commit()

    if not is_internal and t.discord_channel_id:
        author = author_label
        author_role = "api"
        if user_id:
            u = User.query.get(user_id)
            if u:
                author = u.username
                author_role = u.role
        _notify_bot("/discord/ticket/message", {
            "channel_id": t.discord_channel_id,
            "ticket_id": t.id,
            "author": author,
            "author_role": author_role,
            "body": body,
        })

    return ok(m.to_dict(), 201)