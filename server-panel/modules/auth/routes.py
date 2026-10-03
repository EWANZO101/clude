from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash, request, session
from flask_login import login_user, logout_user, login_required, current_user

from database import db
from models.user import User
from models.role import Role, ROLE_OWNER
from modules.auth.forms import SetupForm, LoginForm

auth_bp = Blueprint("auth", __name__, template_folder="templates")


def _any_users_exist():
    return db.session.query(User.id).first() is not None


@auth_bp.before_app_request
def _enforce_setup_redirect():
    """If no users exist yet, force every request to the setup wizard."""
    if request.endpoint is None:
        return None

    exempt_endpoints = {"auth.setup", "static"}
    if request.endpoint in exempt_endpoints:
        return None

    if not _any_users_exist() and request.endpoint != "auth.setup":
        return redirect(url_for("auth.setup"))
    return None


@auth_bp.route("/setup", methods=["GET", "POST"])
def setup():
    # Once an admin exists, the setup wizard is locked out.
    if _any_users_exist():
        return redirect(url_for("auth.login"))

    form = SetupForm()
    if form.validate_on_submit():
        existing = User.query.filter(
            (User.username == form.username.data) | (User.email == form.email.data)
        ).first()
        if existing:
            flash("That username or email is already taken.", "error")
            return render_template("setup.html", form=form)

        Role.seed_defaults()
        owner_role = Role.query.filter_by(name=ROLE_OWNER).first()

        user = User(
            username=form.username.data.strip(),
            email=form.email.data.strip().lower(),
            role=owner_role,
            is_super_admin=True,
        )
        user.set_password(form.password.data)
        db.session.add(user)
        db.session.commit()

        login_user(user)
        session.permanent = True
        flash("Administrator account created. Welcome to OpsLab Server Panel.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("setup.html", form=form)


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    form = LoginForm()
    if form.validate_on_submit():
        user = User.query.filter_by(username=form.username.data.strip()).first()
        if user and user.check_password(form.password.data) and user.is_active:
            session.permanent = True  # activates PERMANENT_SESSION_LIFETIME instead of a
                                       # browser-session-only cookie that dies on restart
            login_user(user, remember=form.remember_me.data)
            user.last_login_at = datetime.utcnow()
            db.session.commit()
            next_url = request.args.get("next")
            return redirect(next_url or url_for("dashboard.index"))
        flash("Invalid username or password.", "error")

    return render_template("login.html", form=form)


@auth_bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("You have been logged out.", "info")
    return redirect(url_for("auth.login"))
