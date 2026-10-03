from datetime import timedelta

from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_user, logout_user, login_required, current_user

from app.extensions import db, limiter
from app.models.base import utcnow
from app.models.user import User, AccountType, EmailVerificationToken, PasswordResetToken
from app.models.customer import CustomerProfile
from app.utils.helpers import client_ip, log_audit
from app.auth.forms import (
    RegistrationForm,
    LoginForm,
    RequestPasswordResetForm,
    ResetPasswordForm,
    ChangePasswordForm,
)
from app.auth.emails import (
    send_verification_email,
    send_password_reset_email,
    send_welcome_email,
)

auth_bp = Blueprint("auth", __name__, template_folder="../templates/auth")

TOKEN_TTL_HOURS = 48


@auth_bp.route("/register", methods=["GET", "POST"])
@limiter.limit("10/hour")
def register():
    if current_user.is_authenticated:
        return redirect(url_for("customer.dashboard"))

    form = RegistrationForm()
    if form.validate_on_submit():
        existing = User.query.filter_by(email=form.email.data.lower()).first()
        if existing:
            flash("An account with that email already exists.", "error")
            return render_template("auth/register.html", form=form)

        user = User(
            email=form.email.data.lower(),
            first_name=form.first_name.data,
            last_name=form.last_name.data,
            account_type=AccountType.CUSTOMER,
        )
        user.set_password(form.password.data)
        db.session.add(user)
        db.session.flush()

        db.session.add(CustomerProfile(user_id=user.id))

        token = EmailVerificationToken(
            user_id=user.id, expires_at=utcnow() + timedelta(hours=TOKEN_TTL_HOURS)
        )
        db.session.add(token)
        log_audit("user.registered", "User", user.id)
        db.session.commit()

        send_verification_email(user, token.token)
        send_welcome_email(user)

        flash("Account created. Please check your email to verify your address.", "success")
        return redirect(url_for("auth.login"))

    return render_template("auth/register.html", form=form)


@auth_bp.route("/verify-email/<token>")
def verify_email(token):
    record = EmailVerificationToken.query.filter_by(token=token).first()
    if not record or not record.is_valid():
        flash("That verification link is invalid or has expired.", "error")
        return redirect(url_for("auth.login"))

    record.used_at = utcnow()
    record.user.is_email_verified = True
    record.user.email_verified_at = utcnow()
    log_audit("user.email_verified", "User", record.user_id)
    db.session.commit()

    flash("Your email has been verified. You can now log in.", "success")
    return redirect(url_for("auth.login"))


@auth_bp.route("/resend-verification", methods=["POST"])
@limiter.limit("5/hour")
def resend_verification():
    email = request.form.get("email", "").lower()
    user = User.query.filter_by(email=email).first()
    if user and not user.is_email_verified:
        token = EmailVerificationToken(
            user_id=user.id, expires_at=utcnow() + timedelta(hours=TOKEN_TTL_HOURS)
        )
        db.session.add(token)
        db.session.commit()
        send_verification_email(user, token.token)
    flash("If an account exists for that email, a verification link has been sent.", "info")
    return redirect(url_for("auth.login"))


@auth_bp.route("/login", methods=["GET", "POST"])
@limiter.limit("20/hour")
def login():
    if current_user.is_authenticated:
        return redirect(url_for("customer.dashboard"))

    form = LoginForm()
    if form.validate_on_submit():
        user = User.query.filter_by(email=form.email.data.lower()).first()

        if user and user.is_locked():
            flash("This account is temporarily locked due to failed login attempts.", "error")
            return render_template("auth/login.html", form=form)

        if not user or not user.check_password(form.password.data):
            if user:
                user.register_failed_login()
                db.session.commit()
            flash("Invalid email or password.", "error")
            return render_template("auth/login.html", form=form)

        if not user.is_active:
            flash("This account has been deactivated. Contact support.", "error")
            return render_template("auth/login.html", form=form)

        user.register_successful_login(ip=client_ip())
        log_audit("user.login", "User", user.id)
        db.session.commit()

        login_user(user, remember=form.remember.data)

        next_url = request.args.get("next")
        if next_url and next_url.startswith("/"):
            return redirect(next_url)
        return redirect(_default_landing(user))

    return render_template("auth/login.html", form=form)


def _default_landing(user):
    if user.account_type == AccountType.ADMIN or user.account_type == AccountType.STAFF:
        return url_for("admin.dashboard")
    if user.account_type == AccountType.SELLER:
        return url_for("seller.dashboard")
    return url_for("customer.dashboard")


@auth_bp.route("/logout")
@login_required
def logout():
    log_audit("user.logout", "User", current_user.id)
    db.session.commit()
    logout_user()
    flash("You have been logged out.", "info")
    return redirect(url_for("marketplace.index"))


@auth_bp.route("/forgot-password", methods=["GET", "POST"])
@limiter.limit("5/hour")
def forgot_password():
    form = RequestPasswordResetForm()
    if form.validate_on_submit():
        user = User.query.filter_by(email=form.email.data.lower()).first()
        if user:
            token = PasswordResetToken(
                user_id=user.id,
                expires_at=utcnow() + timedelta(hours=2),
                requested_ip=client_ip(),
            )
            db.session.add(token)
            db.session.commit()
            send_password_reset_email(user, token.token)
        flash("If an account exists for that email, a reset link has been sent.", "info")
        return redirect(url_for("auth.login"))
    return render_template("auth/forgot_password.html", form=form)


@auth_bp.route("/reset-password/<token>", methods=["GET", "POST"])
def reset_password(token):
    record = PasswordResetToken.query.filter_by(token=token).first()
    if not record or not record.is_valid():
        flash("That password reset link is invalid or has expired.", "error")
        return redirect(url_for("auth.forgot_password"))

    form = ResetPasswordForm()
    if form.validate_on_submit():
        record.user.set_password(form.password.data)
        record.used_at = utcnow()
        record.user.failed_login_attempts = 0
        record.user.locked_until = None
        log_audit("user.password_reset", "User", record.user_id)
        db.session.commit()
        flash("Your password has been reset. You can now log in.", "success")
        return redirect(url_for("auth.login"))

    return render_template("auth/reset_password.html", form=form)


@auth_bp.route("/change-password", methods=["GET", "POST"])
@login_required
def change_password():
    form = ChangePasswordForm()
    if form.validate_on_submit():
        if not current_user.check_password(form.current_password.data):
            flash("Current password is incorrect.", "error")
        else:
            current_user.set_password(form.new_password.data)
            log_audit("user.password_changed", "User", current_user.id)
            db.session.commit()
            flash("Your password has been changed.", "success")
            return redirect(url_for("auth.change_password"))
    return render_template("auth/change_password.html", form=form)
