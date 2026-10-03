from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash
from flask_login import login_user, logout_user, login_required, current_user

from app.extensions import db
from app.models import LocalUser, Settings

bp = Blueprint("auth", __name__, url_prefix="/auth")


@bp.route("/login", methods=["GET", "POST"])
def login():
    settings = Settings.get()
    if not settings.auth_enabled:
        return redirect(url_for("dashboard.index"))
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        user = LocalUser.query.filter_by(username=username).first()
        if user is None or not user.is_active or not user.check_password(password):
            flash("Incorrect username or password.", "danger")
            return render_template("auth/login.html")

        login_user(user)
        user.last_login_at = datetime.utcnow()
        db.session.commit()
        return redirect(url_for("dashboard.index"))

    return render_template("auth/login.html")


@bp.route("/signup", methods=["GET", "POST"])
def signup():
    settings = Settings.get()
    no_users_yet = LocalUser.query.count() == 0
    if not settings.auth_enabled or not (settings.signup_enabled or no_users_yet):
        return redirect(url_for("auth.login"))
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        confirm = request.form.get("confirm", "")
        if not username or not password:
            flash("Username and password are required.", "danger")
            return render_template("auth/signup.html")
        if password != confirm:
            flash("Passwords don't match.", "danger")
            return render_template("auth/signup.html")
        if LocalUser.query.filter_by(username=username).first() is not None:
            flash(f"Username '{username}' is already taken.", "danger")
            return render_template("auth/signup.html")

        # First-ever account becomes admin regardless of the signup toggle
        # (bootstrap) — every account after that is regular staff.
        role = "admin" if no_users_yet else "staff"
        user = LocalUser(username=username, role=role)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        login_user(user)
        user.last_login_at = datetime.utcnow()
        db.session.commit()
        flash(f"Account created — welcome, {username}.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("auth/signup.html", no_users_yet=no_users_yet)


@bp.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("auth.login"))
