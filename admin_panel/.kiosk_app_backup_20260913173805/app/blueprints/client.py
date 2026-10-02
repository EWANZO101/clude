"""Local Client Portal — a LAN-reachable management entry point onto this
kiosk's own local data (Local Users, Roles, Sidebar, Inventory, Tools/
Equipment, Audit Log). All of that already lives in this same local
database and is already fully implemented under /admin, /tools,
/inventory, etc. — this blueprint does NOT duplicate that business logic,
it only adds a second, separately-secured entry point onto it, at a path
(/client/login) matching the Admin Panel's own cloud client_portal, for
the "sell the kiosk, customer runs it fully on their own LAN, no cloud
dependency for day-to-day use" deployment mode. Served on its own port
(see Config.CLIENT_PORTAL_PORT / run.py) bound to all interfaces, unlike
the kiosk's own POS port which stays loopback-only.

Deliberately its own login view rather than calling auth.login() as-is:
/auth/login is intentionally loopback-only-safe (an account with no
password set can log in with badge/username alone — see
LocalUser.check_password) because nothing outside this machine can ever
reach it. This login WILL be reachable from the customer's LAN, so it
must not inherit that same relaxed default — it requires the account to
(a) be an admin-capable role and (b) actually have a password set,
rejecting badge-only accounts outright regardless of what
check_password() would otherwise allow on its own.
"""
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, abort
from flask_login import login_user, logout_user, login_required, current_user

from app.extensions import db
from app.models import LocalUser
from app.permissions import ADMIN_ROLES
from app.blueprints.auth import _role_login_enabled

bp = Blueprint("client", __name__, url_prefix="/client")


@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated and current_user.role in ADMIN_ROLES:
        return redirect(url_for("client.dashboard"))

    if request.method == "POST":
        identifier = request.form.get("identifier", "").strip()
        password = request.form.get("password", "")

        user = LocalUser.query.filter(
            db.func.lower(LocalUser.badge_code) == identifier.lower()
        ).first()
        if user is None:
            user = LocalUser.query.filter_by(username=identifier).first()

        # One generic message no matter which check below actually failed
        # — never reveal to a LAN-side visitor whether an account exists,
        # lacks client-portal access, has no password set, or just typed
        # the wrong one.
        invalid = (
            user is None
            or not user.is_active
            or user.role not in ADMIN_ROLES
            or user.password_hash is None
            or not _role_login_enabled(user.role)
            or not user.check_password(password)
        )
        if invalid:
            flash("Invalid username or password.", "danger")
            return render_template("client/login.html")

        login_user(user)
        user.last_login_at = datetime.utcnow()
        db.session.commit()
        return redirect(url_for("client.dashboard"))

    return render_template("client/login.html")


@bp.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("client.login"))


@bp.route("/")
@login_required
def dashboard():
    if current_user.role not in ADMIN_ROLES:
        abort(403)
    # The existing /admin area already covers local users, roles, sidebar,
    # and audit log; /inventory and /tools cover inventory/equipment. This
    # portal's own distinct dashboard/visual skin is follow-up work — for
    # now this just lands an authenticated client-portal user on the real
    # thing instead of duplicating it.
    return redirect(url_for("admin.index"))
