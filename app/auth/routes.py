from datetime import datetime

import pyotp
from flask import Blueprint, render_template, redirect, url_for, flash, request, current_app, session
from flask_login import login_user, logout_user, login_required, current_user
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired

from app.extensions import db, limiter
from app.models import User, AuditLog
from app.auth.forms import (
    RegisterForm,
    LoginForm,
    RequestResetForm,
    ResetPasswordForm,
    Enable2FAForm,
)

auth_bp = Blueprint("auth", __name__, url_prefix="/auth")


def _serializer():
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"])


def log_action(user_id, action, detail=None):
    entry = AuditLog(
        user_id=user_id,
        action=action,
        detail=detail,
        ip_address=request.remote_addr,
    )
    db.session.add(entry)
    db.session.commit()


@auth_bp.route("/register", methods=["GET", "POST"])
def register():
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))

    form = RegisterForm()
    if form.validate_on_submit():
        existing = User.query.filter_by(email=form.email.data.lower()).first()
        if existing:
            flash("An account with that email already exists.", "danger")
            return render_template("auth/register.html", form=form)

        user = User(email=form.email.data.lower())
        user.set_password(form.password.data)

        if form.temporary.data:
            user.mark_temporary(current_app.config["TEMP_ACCOUNT_LIFETIME"])
            user.email_verified = True  # skip verification friction for temp sessions
        else:
            user.email_verified = False

        db.session.add(user)
        db.session.commit()
        log_action(user.id, "register", detail=f"temporary={user.is_temporary}")

        if not user.is_temporary:
            token = _serializer().dumps(user.email, salt="email-verify")
            verify_url = url_for("auth.verify_email", token=token, _external=True)
            # TODO: wire up mail sending; for now, surface the link directly.
            flash(f"Account created. Verify your email: {verify_url}", "info")
        else:
            flash("Temporary session created. It will expire in 12 hours.", "info")

        return redirect(url_for("auth.login"))

    return render_template("auth/register.html", form=form)


@auth_bp.route("/verify-email/<token>")
def verify_email(token):
    try:
        email = _serializer().loads(token, salt="email-verify", max_age=86400)
    except SignatureExpired:
        flash("Verification link expired. Please request a new one.", "danger")
        return redirect(url_for("auth.login"))
    except BadSignature:
        flash("Invalid verification link.", "danger")
        return redirect(url_for("auth.login"))

    user = User.query.filter_by(email=email).first()
    if user:
        user.email_verified = True
        db.session.commit()
        flash("Email verified. You can now log in.", "success")
    return redirect(url_for("auth.login"))


@auth_bp.route("/login", methods=["GET", "POST"])
@limiter.limit("10 per minute")
def login():
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))

    form = LoginForm()
    if form.validate_on_submit():
        user = User.query.filter_by(email=form.email.data.lower()).first()

        if not user or not user.check_password(form.password.data):
            log_action(user.id if user else None, "login_failed", detail=form.email.data)
            flash("Invalid email or password.", "danger")
            return render_template("auth/login.html", form=form)

        if user.is_expired:
            flash("This temporary session has expired.", "danger")
            return render_template("auth/login.html", form=form)

        if user.is_suspended:
            flash("This account has been suspended. Contact an administrator.", "danger")
            return render_template("auth/login.html", form=form)

        if user.totp_enabled:
            if not form.totp_code.data:
                flash("2FA code required.", "warning")
                return render_template("auth/login.html", form=form)
            totp = pyotp.TOTP(user.totp_secret)
            if not totp.verify(form.totp_code.data, valid_window=1):
                flash("Invalid 2FA code.", "danger")
                return render_template("auth/login.html", form=form)

        login_user(user, remember=form.remember.data)
        session["authenticated_at"] = datetime.utcnow().isoformat()
        user.last_login_at = datetime.utcnow()
        user.last_login_ip = request.remote_addr
        db.session.commit()
        log_action(user.id, "login_success")

        next_page = request.args.get("next")
        return redirect(next_page or url_for("main.dashboard"))

    return render_template("auth/login.html", form=form)


@auth_bp.route("/logout")
@login_required
def logout():
    log_action(current_user.id, "logout")
    logout_user()
    flash("You have been logged out.", "info")
    return redirect(url_for("auth.login"))


@auth_bp.route("/reset-password", methods=["GET", "POST"])
def request_reset():
    form = RequestResetForm()
    if form.validate_on_submit():
        user = User.query.filter_by(email=form.email.data.lower()).first()
        if user:
            token = _serializer().dumps(user.email, salt="password-reset")
            reset_url = url_for("auth.reset_password", token=token, _external=True)
            # TODO: wire up mail sending; for now, surface the link directly.
            flash(f"Password reset link: {reset_url}", "info")
        else:
            flash("If that email exists, a reset link has been generated.", "info")
        return redirect(url_for("auth.login"))
    return render_template("auth/reset_request.html", form=form)


@auth_bp.route("/reset-password/<token>", methods=["GET", "POST"])
def reset_password(token):
    try:
        email = _serializer().loads(token, salt="password-reset", max_age=3600)
    except (SignatureExpired, BadSignature):
        flash("Invalid or expired reset link.", "danger")
        return redirect(url_for("auth.request_reset"))

    user = User.query.filter_by(email=email).first()
    if not user:
        flash("Invalid reset link.", "danger")
        return redirect(url_for("auth.request_reset"))

    form = ResetPasswordForm()
    if form.validate_on_submit():
        user.set_password(form.password.data)
        db.session.commit()
        log_action(user.id, "password_reset")
        flash("Password updated. You can now log in.", "success")
        return redirect(url_for("auth.login"))

    return render_template("auth/reset_password.html", form=form)


@auth_bp.route("/2fa/setup", methods=["GET", "POST"])
@login_required
def setup_2fa():
    if not current_user.totp_secret:
        current_user.totp_secret = pyotp.random_base32()
        db.session.commit()

    totp = pyotp.TOTP(current_user.totp_secret)
    provisioning_uri = totp.provisioning_uri(
        name=current_user.email, issuer_name="SnailyCAD Migration Platform"
    )

    form = Enable2FAForm()
    if form.validate_on_submit():
        if totp.verify(form.totp_code.data, valid_window=1):
            current_user.totp_enabled = True
            db.session.commit()
            log_action(current_user.id, "2fa_enabled")
            flash("Two-factor authentication enabled.", "success")
            return redirect(url_for("main.account"))
        flash("Invalid code. Try again.", "danger")

    return render_template(
        "auth/setup_2fa.html", form=form, secret=current_user.totp_secret,
        provisioning_uri=provisioning_uri,
    )


@auth_bp.route("/2fa/disable", methods=["POST"])
@login_required
def disable_2fa():
    current_user.totp_enabled = False
    current_user.totp_secret = None
    db.session.commit()
    log_action(current_user.id, "2fa_disabled")
    flash("Two-factor authentication disabled.", "info")
    return redirect(url_for("main.account"))
