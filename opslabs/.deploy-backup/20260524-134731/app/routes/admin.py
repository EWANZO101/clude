"""Admin panel routes."""
from datetime import datetime
import re
from functools import wraps
from flask import (Blueprint, render_template, request, redirect, url_for,
                   flash, abort, jsonify, current_app)
from flask_login import login_required, current_user
from flask_mail import Message
from .. import db, mail
from ..models import User, Company, TicketCategory, Ticket, PasswordResetToken

admin_bp = Blueprint("admin", __name__)


def admin_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if not current_user.is_admin:
            abort(403)
        return f(*a, **kw)
    return wrapper


def staff_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if not current_user.is_staff:
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
@staff_required
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
    return render_template("admin/dashboard.html", stats=stats,
                           recent_tickets=recent_tickets, recent_users=recent_users)


# =================================================================
# Users
# =================================================================
@admin_bp.route("/users")
@admin_required
def users():
    q = request.args.get("q", "").strip()
    query = User.query
    if q:
        like = f"%{q}%"
        query = query.filter((User.username.ilike(like)) |
                             (User.email.ilike(like)) |
                             (User.discord_username.ilike(like)))
    all_users = query.order_by(User.created_at.desc()).limit(500).all()
    return render_template("admin/users.html", users=all_users, q=q)


@admin_bp.route("/users/new", methods=["GET", "POST"])
@admin_required
def user_new():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        role = request.form.get("role", "user")
        if role not in ("user", "staff", "admin"):
            role = "user"
        if not username or not email or not password:
            flash("All fields are required.", "error")
            return render_template("admin/user_form.html", user=None)
        if User.query.filter((User.username == username) | (User.email == email)).first():
            flash("Username or email already exists.", "error")
            return render_template("admin/user_form.html", user=None)
        u = User(username=username, email=email, role=role, is_active=True)
        u.set_password(password)
        db.session.add(u)
        db.session.commit()
        flash(f"User '{username}' created.", "success")
        return redirect(url_for("admin.users"))
    return render_template("admin/user_form.html", user=None)


@admin_bp.route("/users/<int:uid>", methods=["GET", "POST"])
@admin_required
def user_edit(uid):
    u = User.query.get_or_404(uid)
    if request.method == "POST":
        u.username = request.form.get("username", u.username).strip()
        u.email = request.form.get("email", u.email).strip().lower()
        new_role = request.form.get("role", u.role)
        if new_role in ("user", "staff", "admin"):
            # Prevent demoting yourself
            if u.id == current_user.id and new_role != "admin":
                flash("You can't demote yourself.", "error")
            else:
                u.role = new_role
        u.is_active = request.form.get("is_active") == "on"
        u.discord_id = request.form.get("discord_id", "").strip() or None
        u.discord_username = request.form.get("discord_username", "").strip() or None
        db.session.commit()
        flash("User updated.", "success")
        return redirect(url_for("admin.users"))
    return render_template("admin/user_form.html", user=u)


@admin_bp.route("/users/<int:uid>/reset-password", methods=["POST"])
@admin_required
def user_reset_password(uid):
    """Manual or email reset."""
    u = User.query.get_or_404(uid)
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
@admin_required
def user_delete(uid):
    u = User.query.get_or_404(uid)
    if u.id == current_user.id:
        flash("You can't delete yourself.", "error")
        return redirect(url_for("admin.users"))
    db.session.delete(u)
    db.session.commit()
    flash(f"User '{u.username}' deleted.", "success")
    return redirect(url_for("admin.users"))


# =================================================================
# Companies (the "form builder" — add new service providers)
# =================================================================
@admin_bp.route("/companies")
@admin_required
def companies():
    cs = Company.query.order_by(Company.created_at.desc()).all()
    return render_template("admin/companies.html", companies=cs)


@admin_bp.route("/companies/new", methods=["GET", "POST"])
@admin_required
def company_new():
    if request.method == "POST":
        return _save_company(None)
    return render_template("admin/company_form.html", company=None)


@admin_bp.route("/companies/<int:cid>", methods=["GET", "POST"])
@admin_required
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


@admin_bp.route("/companies/<int:cid>/delete", methods=["POST"])
@admin_required
def company_delete(cid):
    c = Company.query.get_or_404(cid)
    if c.tickets.count() > 0:
        flash("Can't delete — company has tickets. Deactivate instead.", "error")
        return redirect(url_for("admin.companies"))
    db.session.delete(c)
    db.session.commit()
    flash("Company deleted.", "success")
    return redirect(url_for("admin.companies"))


# =================================================================
# All tickets (staff view)
# =================================================================
@admin_bp.route("/tickets")
@staff_required
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
@admin_required
def api_keys():
    from ..models_api import ApiKey
    keys = ApiKey.query.order_by(ApiKey.created_at.desc()).all()
    return render_template("admin/api_keys.html", keys=keys)


@admin_bp.route("/api-keys/new", methods=["POST"])
@admin_required
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
@admin_required
def api_key_revoke(kid):
    from ..models_api import ApiKey
    k = ApiKey.query.get_or_404(kid)
    k.is_active = False
    db.session.commit()
    flash("Key revoked.", "success")
    return redirect(url_for("admin.api_keys"))
