"""Admin panel routes."""
from datetime import datetime
import re
from functools import wraps
from flask import (Blueprint, render_template, request, redirect, url_for,
                   flash, abort, jsonify, current_app)
from flask_login import login_required, current_user
from flask_mail import Message
from .. import db, mail
from ..models import User, Company, TicketCategory, Ticket, PasswordResetToken, TicketMessage
from ..rbac import (require_admin_page, ADMIN_PAGES, outranks, canonical_role, FOUNDER,
                    MANAGEABLE_ROLES, ROLE_LABELS, role_default_pages, set_role_default_pages)

admin_bp = Blueprint("admin", __name__)


def admin_required(f):
    """Legacy blanket admin gate — kept for any external references, but every
    route below now uses require_admin_page() for granular, per-page access."""
    @wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if not getattr(current_user, 'is_admin', False):
            abort(403)
        return f(*a, **kw)
    return wrapper


def staff_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if not getattr(current_user, 'is_staff', False):
            abort(403)
        return f(*a, **kw)
    return wrapper


def _slugify(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s or "company"


# =================================================================
# Dashboard
# =================================================================
@admin_bp.route("/")
@require_admin_page("dashboard")
def dashboard():
    stats = {
        "users": User.query.count(),
        "admins": User.query.filter_by(role="admin").count(),
        "staff": User.query.filter_by(role="staff").count(),
        "tickets_open": Ticket.query.filter_by(status="open").count(),
        "tickets_pending": Ticket.query.filter_by(status="pending").count(),
        "tickets_closed": Ticket.query.filter_by(status="closed").count(),
        "companies": Company.query.filter_by(is_active=True).count(),
    }
    recent_tickets = Ticket.query.order_by(Ticket.created_at.desc()).limit(8).all()
    recent_users = User.query.order_by(User.created_at.desc()).limit(8).all()
    return render_template("admin/ops_dashboard.html", stats=stats,
                           recent_tickets=recent_tickets, recent_users=recent_users)


# =================================================================
# Users
# =================================================================
@admin_bp.route("/users")
@require_admin_page("users")
def users():
    q = request.args.get("q", "").strip()
    query = User.query
    if q:
        like = f"%{q}%"
        query = query.filter((User.username.ilike(like)) |
                             (User.email.ilike(like)) |
                             (User.discord_username.ilike(like)))
    all_users = query.order_by(User.created_at.desc()).limit(500).all()
    return render_template("admin/ops_users.html", users=all_users, q=q)


@admin_bp.route("/users/new", methods=["GET", "POST"])
@require_admin_page("users")
def user_new():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        role = request.form.get("role", "user")
        if role not in ("user", "staff", "admin", "founder"):
            role = "user"
        if role == "founder" and not current_user.is_founder:
            flash("Only a Founder can grant the Founder role.", "error")
            role = "staff"
        if not username or not email or not password:
            flash("All fields are required.", "error")
            return render_template("admin/user_form.html", user=None)
        if User.query.filter((User.username == username) | (User.email == email)).first():
            flash("Username or email already exists.", "error")
            return render_template("admin/user_form.html", user=None)
        u = User(username=username, email=email, role=role, is_active=True)
        if role not in ("admin", "founder"):
            granted = [p for p in request.form.getlist("permissions") if p in ADMIN_PAGES]
            u.permissions = ",".join(granted)
        u.set_password(password)
        db.session.add(u)
        db.session.commit()
        flash(f"User '{username}' created.", "success")
        return redirect(url_for("admin.users"))
    return render_template("admin/user_form.html", user=None, admin_pages=ADMIN_PAGES)


@admin_bp.route("/users/<int:uid>", methods=["GET", "POST"])
@require_admin_page("users")
def user_edit(uid):
    u = User.query.get_or_404(uid)
    # Founder overrules Admin: an Admin (who isn't a Founder) can't touch a
    # Founder's account at all.
    if u.is_founder and not current_user.is_founder:
        flash("Only a Founder can edit a Founder account.", "error")
        return redirect(url_for("admin.users"))
    if request.method == "POST":
        u.username = request.form.get("username", u.username).strip()
        u.email = request.form.get("email", u.email).strip().lower()
        new_role = request.form.get("role", u.role)
        if new_role == "founder" and not current_user.is_founder:
            flash("Only a Founder can grant the Founder role.", "error")
            new_role = u.role
        if new_role in ("user", "staff", "admin", "founder"):
            # Prevent demoting yourself out of admin/founder
            if u.id == current_user.id and new_role not in ("admin", "founder"):
                flash("You can't demote yourself.", "error")
            else:
                u.role = new_role
        if u.role not in ("admin", "founder"):
            granted = [p for p in request.form.getlist("permissions") if p in ADMIN_PAGES]
            u.permissions = ",".join(granted)
        u.is_active = request.form.get("is_active") == "on"
        u.discord_id = request.form.get("discord_id", "").strip() or None
        u.discord_username = request.form.get("discord_username", "").strip() or None
        db.session.commit()
        flash("User updated.", "success")
        return redirect(url_for("admin.users"))
    return render_template("admin/user_form.html", user=u, admin_pages=ADMIN_PAGES)


@admin_bp.route("/users/<int:uid>/reset-password", methods=["POST"])
@require_admin_page("users")
def user_reset_password(uid):
    """Manual or email reset."""
    u = User.query.get_or_404(uid)
    if u.is_founder and not current_user.is_founder:
        flash("Only a Founder can reset a Founder's password.", "error")
        return redirect(url_for("admin.users"))
    mode = request.form.get("mode", "manual")

    if mode == "manual":
        new_pw = request.form.get("new_password", "").strip()
        if len(new_pw) < 4:
            flash("Password too short.", "error")
            return redirect(url_for("admin.user_edit", uid=uid))
        u.set_password(new_pw)
        db.session.commit()
        flash(f"Password for '{u.username}' set manually.", "success")

    elif mode == "email":
        tok = PasswordResetToken.create_for(u)
        reset_url = url_for("auth.reset", token=tok.token, _external=True)
        try:
            if current_app.config.get("MAIL_USERNAME"):
                msg = Message(
                    subject="Ops Labs — Password reset (admin-initiated)",
                    recipients=[u.email],
                    body=(f"Hi {u.username},\n\n"
                          f"An admin initiated a password reset for your account.\n"
                          f"Use this link (expires in 2 hours):\n{reset_url}\n\n— Ops Labs"),
                )
                mail.send(msg)
                flash(f"Reset email sent to {u.email}.", "success")
            else:
                current_app.logger.info(f"[DEV] Admin reset link for {u.username}: {reset_url}")
                flash(f"Mail not configured — link logged to console: {reset_url}", "info")
        except Exception as e:
            current_app.logger.error(f"Reset mail failed: {e}")
            flash(f"Mail send failed: {e}. Link: {reset_url}", "error")

    return redirect(url_for("admin.user_edit", uid=uid))


@admin_bp.route("/users/<int:uid>/delete", methods=["POST"])
@require_admin_page("users")
def user_delete(uid):
    u = User.query.get_or_404(uid)
    if u.id == current_user.id:
        flash("You can't delete yourself.", "error")
        return redirect(url_for("admin.users"))
    if u.is_founder and not current_user.is_founder:
        flash("Only a Founder can delete a Founder account.", "error")
        return redirect(url_for("admin.users"))
    db.session.delete(u)
    db.session.commit()
    flash(f"User '{u.username}' deleted.", "success")
    return redirect(url_for("admin.users"))


# =================================================================
# Companies (the "form builder" — add new service providers)
# =================================================================
@admin_bp.route("/companies")
@require_admin_page("companies")
def companies():
    cs = Company.query.order_by(Company.created_at.desc()).all()
    return render_template("admin/companies.html", companies=cs)


@admin_bp.route("/companies/new", methods=["GET", "POST"])
@require_admin_page("companies")
def company_new():
    if request.method == "POST":
        return _save_company(None)
    return render_template("admin/company_form.html", company=None)


@admin_bp.route("/companies/<int:cid>", methods=["GET", "POST"])
@require_admin_page("companies")
def company_edit(cid):
    c = Company.query.get_or_404(cid)
    if request.method == "POST":
        return _save_company(c)
    return render_template("admin/company_form.html", company=c)


def _save_company(c):
    name = request.form.get("name", "").strip()
    slug = request.form.get("slug", "").strip() or _slugify(name)
    if not name:
        flash("Name is required.", "error")
        return render_template("admin/company_form.html", company=c)

    existing = Company.query.filter_by(slug=slug).first()
    if existing and (not c or existing.id != c.id):
        flash("Slug already in use.", "error")
        return render_template("admin/company_form.html", company=c)

    if c is None:
        c = Company(slug=slug)
        db.session.add(c)
    c.name = name
    c.slug = slug
    c.tagline = request.form.get("tagline", "").strip() or None
    c.description = request.form.get("description", "").strip() or None
    c.logo_url = request.form.get("logo_url", "").strip() or None
    c.accent_color = request.form.get("accent_color", "#2196f3").strip()
    c.is_active = request.form.get("is_active") == "on"
    db.session.commit()

    # Categories from the form-builder block (one per line: "Name | Description")
    cat_lines = request.form.get("categories", "").strip().splitlines()
    if cat_lines:
        # Replace existing categories
        TicketCategory.query.filter_by(company_id=c.id).delete()
        for line in cat_lines:
            line = line.strip()
            if not line:
                continue
            if "|" in line:
                cname, cdesc = [s.strip() for s in line.split("|", 1)]
            else:
                cname, cdesc = line, None
            db.session.add(TicketCategory(name=cname, description=cdesc,
                                          company_id=c.id, is_active=True))
        db.session.commit()

    flash(f"Company '{c.name}' saved.", "success")
    return redirect(url_for("admin.companies"))


@admin_bp.route("/companies/<int:cid>/deactivate", methods=["POST"])
@require_admin_page("companies")
def company_deactivate(cid):
    """Hide the company everywhere — tickets and history preserved."""
    c = Company.query.get_or_404(cid)
    c.is_active = False
    # Also deactivate its categories so they don't show up in pickers
    for cat in c.categories.all() if c.categories.__class__.__name__ == "AppenderQuery" else (c.categories or []):
        cat.is_active = False
    db.session.commit()
    flash(f"'{c.name}' deactivated. Tickets and history preserved.", "success")
    return redirect(url_for("admin.companies"))


@admin_bp.route("/companies/<int:cid>/reassign", methods=["POST"])
@require_admin_page("companies")
def company_reassign(cid):
    """Move all this company's tickets to a fallback (default = OpsLabs / first
    active company), then delete the company. Tickets and messages preserved."""
    c = Company.query.get_or_404(cid)

    fallback = (
        Company.query.filter(Company.id != c.id, Company.is_active.is_(True))
        .filter(Company.name.in_(["OpsLabs", "OpsLab Systems", "OpsLabs Systems"]))
        .first()
        or Company.query.filter(Company.id != c.id, Company.is_active.is_(True))
        .order_by(Company.id).first()
    )
    if not fallback:
        flash("No fallback company exists to receive the tickets. Create another company first.", "error")
        return redirect(url_for("admin.companies"))

    moved = (Ticket.query.filter_by(company_id=c.id)
             .update({"company_id": fallback.id, "category_id": None},
                     synchronize_session=False))
    # Drop the categories belonging to the deleted company
    TicketCategory.query.filter_by(company_id=c.id).delete(synchronize_session=False)
    db.session.delete(c)
    db.session.commit()
    flash(f"Reassigned {moved} ticket{'s' if moved != 1 else ''} from '{c.name}' to '{fallback.name}', then deleted '{c.name}'.", "success")
    return redirect(url_for("admin.companies"))


@admin_bp.route("/companies/<int:cid>/wipe", methods=["POST"])
@require_admin_page("companies")
def company_wipe(cid):
    """Nuke the company, all its tickets, and all messages. DESTRUCTIVE."""
    c = Company.query.get_or_404(cid)
    name = c.name

    ticket_ids = [t.id for t in Ticket.query.filter_by(company_id=c.id).all()]
    msg_count = 0
    if ticket_ids:
        msg_count = (TicketMessage.query
                     .filter(TicketMessage.ticket_id.in_(ticket_ids))
                     .delete(synchronize_session=False))
        Ticket.query.filter(Ticket.id.in_(ticket_ids)).delete(synchronize_session=False)
    TicketCategory.query.filter_by(company_id=c.id).delete(synchronize_session=False)
    db.session.delete(c)
    db.session.commit()

    flash(
        f"Wiped '{name}' — {len(ticket_ids)} ticket(s) and {msg_count} message(s) permanently deleted.",
        "success",
    )
    return redirect(url_for("admin.companies"))


@admin_bp.route("/companies/<int:cid>/delete", methods=["POST"])
@require_admin_page("companies")
def company_delete(cid):
    """Legacy route — kept for backwards compatibility. Refuses if tickets exist."""
    c = Company.query.get_or_404(cid)
    if c.tickets.count() > 0:
        flash("Can't delete — company has tickets. Use Deactivate, Reassign, or Wipe.", "error")
        return redirect(url_for("admin.companies"))
    db.session.delete(c)
    db.session.commit()
    flash("Company deleted.", "success")
    return redirect(url_for("admin.companies"))


# =================================================================
# All tickets (staff view)
# =================================================================
@admin_bp.route("/tickets")
@require_admin_page("tickets")
def tickets():
    q = Ticket.query.order_by(Ticket.updated_at.desc())
    status = request.args.get("status")
    if status in ("open", "pending", "closed"):
        q = q.filter_by(status=status)
    return render_template("admin/tickets.html", tickets=q.limit(500).all(),
                           current_status=status)


# =================================================================
# API Keys (for the REST API)
# =================================================================
@admin_bp.route("/api-keys")
@require_admin_page("api_keys")
def api_keys():
    from ..models_api import ApiKey
    keys = ApiKey.query.order_by(ApiKey.created_at.desc()).all()
    return render_template("admin/api_keys.html", keys=keys)


@admin_bp.route("/api-keys/new", methods=["POST"])
@require_admin_page("api_keys")
def api_key_new():
    from ..models_api import ApiKey
    label = request.form.get("label", "").strip() or "Unnamed key"
    scope = request.form.get("scope", "read")
    if scope not in ("read", "write", "admin"):
        scope = "read"
    key, plain = ApiKey.create(label=label, scope=scope, owner_id=current_user.id)
    flash(f"API key created. Copy it now — it won't be shown again: {plain}", "success")
    return redirect(url_for("admin.api_keys"))


@admin_bp.route("/api-keys/<int:kid>/revoke", methods=["POST"])
@require_admin_page("api_keys")
def api_key_revoke(kid):
    from ..models_api import ApiKey
    k = ApiKey.query.get_or_404(kid)
    k.is_active = False
    db.session.commit()
    flash("Key revoked.", "success")
    return redirect(url_for("admin.api_keys"))


# ── Role default pages ───────────────────────────────────────────────────────
# Separate from per-user page access (see user_new/user_edit above). Every
# account of a given role starts with whatever's set here; individual users
# can still be granted extra pages on top via their own account.
@admin_bp.route("/roles", methods=["GET", "POST"])
@require_admin_page("role_perms")
def role_perms():
    if request.method == "POST":
        role = request.form.get("role", "")
        if role not in MANAGEABLE_ROLES:
            flash("Unknown role.", "error")
            return redirect(url_for("admin.role_perms"))
        granted = request.form.getlist("permissions")
        set_role_default_pages(role, granted)
        flash(f"Default pages updated for {ROLE_LABELS.get(role, role)}.", "success")
        return redirect(url_for("admin.role_perms"))
    roles = [(r, ROLE_LABELS.get(r, r), role_default_pages(r)) for r in MANAGEABLE_ROLES]
    return render_template("admin/role_perms.html", roles=roles, admin_pages=ADMIN_PAGES)
