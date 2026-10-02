from flask import Blueprint, flash, redirect, render_template, request, url_for
from flask_login import current_user, login_required, login_user, logout_user

from app.forms import LoginForm
from app.models.user import User
from app.services.security import clear_attempts, is_locked_out, record_failed_attempt

auth_bp = Blueprint("auth", __name__, url_prefix="/auth")


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("admin.dashboard"))

    form = LoginForm()
    throttle_key = request.remote_addr or "unknown"

    if form.validate_on_submit():
        if is_locked_out(throttle_key):
            flash("Too many attempts. Please wait a few minutes and try again.", "error")
            return render_template("auth/login.html", form=form), 429

        email = form.email.data.lower().strip()
        user = User.query.filter_by(email=email).first()

        if user and user.check_password(form.password.data):
            clear_attempts(throttle_key)
            login_user(user, remember=form.remember_me.data)
            next_url = request.args.get("next")
            # Only follow relative, in-app redirect targets to avoid open-redirect issues.
            if not next_url or not next_url.startswith("/"):
                next_url = url_for("admin.dashboard")
            return redirect(next_url)

        record_failed_attempt(throttle_key)
        flash("Incorrect email or password.", "error")

    return render_template("auth/login.html", form=form)


@auth_bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("You've been signed out.", "info")
    return redirect(url_for("auth.login"))
