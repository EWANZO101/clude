from datetime import datetime
from urllib.parse import urlparse

from email_validator import validate_email, EmailNotValidError
from flask import Blueprint, render_template, redirect, url_for, request, flash, current_app
from flask_login import login_user, logout_user, login_required, current_user

from app.extensions import db
from app.models import User, PlatformSetting, is_valid_pin_format, PIN_MIN_LENGTH, PIN_MAX_LENGTH
from app.tokens import (
    generate_email_verify_token, verify_email_verify_token,
    generate_password_reset_token, verify_password_reset_token,
)
from app.emails import send_verification_email, send_password_reset_email

bp = Blueprint("auth", __name__, url_prefix="/auth")


def _safe_next_url(next_url):
    """Guards against an open redirect via a crafted ?next= — a bare
    relative path is fine, but anything with a scheme or netloc
    (//evil.example, https://evil.example) would send a just-authenticated
    user off-site. Returns next_url if it's safe to use, else None."""
    if not next_url:
        return None
    parsed = urlparse(next_url)
    if parsed.scheme or parsed.netloc:
        return None
    if not next_url.startswith("/"):
        return None
    return next_url


@bp.route("/signup", methods=["GET", "POST"])
def signup():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if not PlatformSetting.get().signups_enabled:
        flash("New sign-ups are closed right now. Ask your administrator for an invite.", "warning")
        return redirect(url_for("auth.login"))

    if request.method == "POST":
        full_name = request.form.get("full_name", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        password_confirm = request.form.get("password_confirm", "")

        errors = []
        if not full_name:
            errors.append("Full name is required.")
        try:
            email = validate_email(email, check_deliverability=False).normalized
        except EmailNotValidError as e:
            errors.append(str(e))
        if len(password) < 10:
            errors.append("Password must be at least 10 characters.")
        if password != password_confirm:
            errors.append("Passwords do not match.")
        if not errors and User.query.filter_by(email=email).first() is not None:
            errors.append("An account with that email already exists.")

        if errors:
            for e in errors:
                flash(e, "danger")
            return render_template("auth/signup.html", full_name=full_name, email=email)

        user = User(email=email, full_name=full_name)
        user.set_password(password)
        user.email_verified = not current_app.config["REQUIRE_EMAIL_VERIFICATION"]
        db.session.add(user)
        db.session.commit()

        if current_app.config["REQUIRE_EMAIL_VERIFICATION"]:
            token = generate_email_verify_token(user.id)
            send_verification_email(user, token)
            flash("Account created. Check your email to verify your address before logging in.", "success")
        else:
            flash("Account created. You can now log in.", "success")

        return redirect(url_for("auth.login"))

    return render_template("auth/signup.html")


@bp.route("/verify-email/<token>")
def verify_email(token):
    uid = verify_email_verify_token(token, current_app.config["EMAIL_VERIFY_MAX_AGE"])
    if uid is None:
        flash("That verification link is invalid or has expired.", "danger")
        return redirect(url_for("auth.login"))
    user = User.query.get(uid)
    if user is None:
        flash("That verification link is invalid.", "danger")
        return redirect(url_for("auth.login"))
    user.email_verified = True
    db.session.commit()
    flash("Email verified. You can now log in.", "success")
    return redirect(url_for("auth.login"))


@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        remember = bool(request.form.get("remember"))

        user = User.query.filter_by(email=email).first()

        # Constant-shape response whether the account exists or not, to avoid
        # leaking which emails are registered.
        if user is None or not user.check_password(password):
            flash("Invalid email or password.", "danger")
            return render_template("auth/login.html", email=email)

        if not user.is_active:
            flash("This account has been disabled. Contact support.", "danger")
            return render_template("auth/login.html", email=email)

        if current_app.config["REQUIRE_EMAIL_VERIFICATION"] and not user.email_verified:
            flash("Please verify your email address before logging in.", "warning")
            return render_template("auth/login.html", email=email)

        login_user(user, remember=remember)
        user.last_login_at = datetime.utcnow()
        db.session.commit()

        next_url = _safe_next_url(request.args.get("next"))
        return redirect(next_url or url_for("dashboard.index"))

    return render_template("auth/login.html")


@bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("Logged out.", "info")
    return redirect(url_for("auth.login"))


@bp.route("/forgot-password", methods=["GET", "POST"])
def forgot_password():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        user = User.query.filter_by(email=email).first()
        if user is not None:
            token = generate_password_reset_token(user.id, user.password_hash)
            send_password_reset_email(user, token)
        # Same message regardless of whether the account exists.
        flash("If that email is registered, a reset link has been sent.", "info")
        return redirect(url_for("auth.login"))
    return render_template("auth/forgot_password.html")


@bp.route("/reset-password/<token>", methods=["GET", "POST"])
def reset_password(token):
    # We need the user id up front to check the token against their current hash,
    # but the token itself carries only a hash fragment, not the id in the clear
    # for lookup purposes — decode without verifying hash first to find the user.
    from app.tokens import _serializer
    try:
        raw = _serializer().loads(
            token, salt="password-reset", max_age=current_app.config["PASSWORD_RESET_MAX_AGE"]
        )
    except Exception:
        flash("That reset link is invalid or has expired.", "danger")
        return redirect(url_for("auth.forgot_password"))

    user = User.query.get(raw.get("uid"))
    if user is None:
        flash("That reset link is invalid.", "danger")
        return redirect(url_for("auth.forgot_password"))

    uid = verify_password_reset_token(
        token, current_app.config["PASSWORD_RESET_MAX_AGE"], user.password_hash
    )
    if uid is None:
        flash("That reset link is invalid or has already been used.", "danger")
        return redirect(url_for("auth.forgot_password"))

    if request.method == "POST":
        password = request.form.get("password", "")
        password_confirm = request.form.get("password_confirm", "")
        if len(password) < 10:
            flash("Password must be at least 10 characters.", "danger")
            return render_template("auth/reset_password.html", token=token)
        if password != password_confirm:
            flash("Passwords do not match.", "danger")
            return render_template("auth/reset_password.html", token=token)

        user.set_password(password)
        db.session.commit()
        flash("Password updated. You can now log in.", "success")
        return redirect(url_for("auth.login"))

    return render_template("auth/reset_password.html", token=token)


@bp.route("/profile", methods=["GET", "POST"])
@login_required
def profile():
    if request.method == "POST":
        full_name = request.form.get("full_name", "").strip()
        if full_name:
            current_user.full_name = full_name
            db.session.commit()
            flash("Profile updated.", "success")
        return redirect(url_for("auth.profile"))
    return render_template("auth/profile.html")


@bp.route("/pin-setup", methods=["GET", "POST"])
@login_required
def pin_setup():
    """Gate a user must pass before reaching anything else once
    needs_pin_setup() or pin_is_expired() is true (see the before_request
    hook in app/__init__.py) — covers first-ever login, an admin-triggered
    reset (pin_must_change), and ordinary rotation once the PIN has aged
    past the company's pin_expiry_days policy. Same form/route handles all
    three; only the messaging shown differs."""
    is_first_time = current_user.pin_hash is None
    is_forced_reset = not is_first_time and current_user.pin_must_change
    is_expired = not is_first_time and not is_forced_reset and current_user.pin_is_expired()

    if request.method == "POST":
        pin = request.form.get("pin", "").strip()
        pin_confirm = request.form.get("pin_confirm", "").strip()

        if not is_valid_pin_format(pin):
            flash(f"PIN must be {PIN_MIN_LENGTH} to {PIN_MAX_LENGTH} digits, numbers only.", "danger")
        elif pin != pin_confirm:
            flash("PINs do not match.", "danger")
        elif current_user.pin_was_used_before(pin):
            flash("That PIN has been used before. Please choose a different one.", "danger")
        else:
            current_user.set_pin(pin)
            db.session.commit()
            flash("PIN set.", "success")
            next_url = _safe_next_url(request.args.get("next"))
            return redirect(next_url or url_for("dashboard.index"))

    return render_template(
        "auth/pin_setup.html",
        is_first_time=is_first_time, is_forced_reset=is_forced_reset, is_expired=is_expired,
        pin_min_length=PIN_MIN_LENGTH, pin_max_length=PIN_MAX_LENGTH,
    )


@bp.route("/change-password", methods=["GET", "POST"])
@login_required
def change_password():
    if request.method == "POST":
        current_password = request.form.get("current_password", "")
        new_password = request.form.get("new_password", "")
        new_password_confirm = request.form.get("new_password_confirm", "")

        if not current_user.check_password(current_password):
            flash("Current password is incorrect.", "danger")
            return render_template("auth/change_password.html")
        if len(new_password) < 10:
            flash("New password must be at least 10 characters.", "danger")
            return render_template("auth/change_password.html")
        if new_password != new_password_confirm:
            flash("New passwords do not match.", "danger")
            return render_template("auth/change_password.html")

        current_user.set_password(new_password)
        db.session.commit()
        flash("Password changed.", "success")
        return redirect(url_for("auth.profile"))

    return render_template("auth/change_password.html")
