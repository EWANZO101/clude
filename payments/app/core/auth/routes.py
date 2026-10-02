from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash, request, current_app
from flask_login import login_user, logout_user, login_required, current_user

from app.extensions import db, login_manager, limiter
from app.core.database.models import (
    User,
    UserSession,
    LoginHistory,
    PasswordResetToken,
    EmailVerificationToken,
)
from app.core.auth.forms import (
    SignupForm,
    LoginForm,
    ForgotPasswordForm,
    ResetPasswordForm,
    ChangePasswordForm,
)
from app.core.email.service import send_verification_email, send_password_reset_email

auth_bp = Blueprint("auth", __name__, template_folder="../../templates/auth")


@login_manager.user_loader
def load_user(user_id):
    return db.session.get(User, user_id)


def _client_ip():
    return request.headers.get("X-Forwarded-For", request.remote_addr)


@auth_bp.route("/signup", methods=["GET", "POST"])
@limiter.limit("10 per hour", methods=["POST"])
def signup():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    form = SignupForm()
    if form.validate_on_submit():
        existing = User.query.filter_by(email=form.email.data.lower().strip()).first()
        if existing:
            flash("An account with that email already exists.", "error")
            return render_template("auth/signup.html", form=form)

        user = User(name=form.name.data.strip(), email=form.email.data.lower().strip())
        user.set_password(form.password.data)
        db.session.add(user)
        db.session.commit()

        verification = EmailVerificationToken(user_id=user.id)
        db.session.add(verification)
        db.session.commit()
        current_app.logger.info(f"Email verification token for {user.email}: {verification.token}")
        send_verification_email(user, verification.token)

        login_user(user)
        flash("Account created. Let's get you set up.", "success")
        return redirect(url_for("dashboard.setup_wizard"))

    return render_template("auth/signup.html", form=form)


@auth_bp.route("/login", methods=["GET", "POST"])
@limiter.limit("15 per 5 minutes", methods=["POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    form = LoginForm()
    if form.validate_on_submit():
        user = User.query.filter_by(email=form.email.data.lower().strip()).first()
        success = bool(user and user.check_password(form.password.data) and user.is_active_account)

        if user:
            db.session.add(LoginHistory(user_id=user.id, ip_address=_client_ip(),
                                         user_agent=request.headers.get("User-Agent", ""), success=success))
            db.session.commit()

        if not success:
            flash("Invalid email or password.", "error")
            return render_template("auth/login.html", form=form)

        login_user(user, remember=form.remember.data)
        session_row = UserSession(
            user_id=user.id,
            ip_address=_client_ip(),
            user_agent=request.headers.get("User-Agent", ""),
        )
        db.session.add(session_row)
        db.session.commit()

        next_page = request.args.get("next")
        return redirect(next_page or url_for("dashboard.index"))

    return render_template("auth/login.html", form=form)


@auth_bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("You have been logged out.", "success")
    return redirect(url_for("auth.login"))


@auth_bp.route("/forgot-password", methods=["GET", "POST"])
@limiter.limit("5 per hour", methods=["POST"])
def forgot_password():
    form = ForgotPasswordForm()
    if form.validate_on_submit():
        user = User.query.filter_by(email=form.email.data.lower().strip()).first()
        if user:
            token = PasswordResetToken(user_id=user.id)
            db.session.add(token)
            db.session.commit()
            current_app.logger.info(f"Password reset token for {user.email}: {token.token}")
            send_password_reset_email(user, token.token)
        flash("If that email exists, a reset link has been sent.", "success")
        return redirect(url_for("auth.login"))
    return render_template("auth/forgot_password.html", form=form)


@auth_bp.route("/reset-password/<token>", methods=["GET", "POST"])
@limiter.limit("10 per hour", methods=["POST"])
def reset_password(token):
    reset_token = PasswordResetToken.query.filter_by(token=token, used=False).first()
    if not reset_token or reset_token.expires_at < datetime.utcnow():
        flash("That reset link is invalid or has expired.", "error")
        return redirect(url_for("auth.forgot_password"))

    form = ResetPasswordForm()
    if form.validate_on_submit():
        user = db.session.get(User, reset_token.user_id)
        user.set_password(form.password.data)
        reset_token.used = True
        db.session.commit()
        flash("Password reset. You can now log in.", "success")
        return redirect(url_for("auth.login"))

    return render_template("auth/reset_password.html", form=form)


@auth_bp.route("/verify-email/<token>")
def verify_email(token):
    verification = EmailVerificationToken.query.filter_by(token=token, used=False).first()
    if not verification or verification.expires_at < datetime.utcnow():
        flash("That verification link is invalid or has expired.", "error")
        return redirect(url_for("dashboard.index"))

    user = db.session.get(User, verification.user_id)
    user.email_verified = True
    verification.used = True
    db.session.commit()
    flash("Email verified.", "success")
    return redirect(url_for("dashboard.index"))


@auth_bp.route("/change-password", methods=["GET", "POST"])
@login_required
def change_password():
    form = ChangePasswordForm()
    if form.validate_on_submit():
        if not current_user.check_password(form.current_password.data):
            flash("Current password is incorrect.", "error")
            return render_template("auth/change_password.html", form=form)
        current_user.set_password(form.new_password.data)
        db.session.commit()
        flash("Password changed.", "success")
        return redirect(url_for("dashboard.settings_security"))
    return render_template("auth/change_password.html", form=form)


@auth_bp.route("/sessions")
@login_required
def sessions():
    active_sessions = current_user.sessions.filter_by(revoked=False).order_by(
        UserSession.last_active_at.desc()
    ).all()
    history = current_user.login_events.order_by(LoginHistory.created_at.desc()).limit(20).all()
    return render_template("auth/sessions.html", sessions=active_sessions, history=history)


@auth_bp.route("/sessions/<session_id>/revoke", methods=["POST"])
@login_required
def revoke_session(session_id):
    session_row = UserSession.query.filter_by(id=session_id, user_id=current_user.id).first()
    if session_row:
        session_row.revoked = True
        db.session.commit()
        flash("Session signed out.", "success")
    return redirect(url_for("auth.sessions"))


@auth_bp.route("/sessions/revoke-all", methods=["POST"])
@login_required
def revoke_all_sessions():
    current_user.sessions.filter_by(revoked=False).update({"revoked": True})
    db.session.commit()
    flash("All other devices have been signed out.", "success")
    return redirect(url_for("auth.sessions"))


@auth_bp.route("/delete-account", methods=["POST"])
@login_required
def delete_account():
    user = current_user
    logout_user()
    db.session.delete(user)
    db.session.commit()
    flash("Your account has been deleted.", "success")
    return redirect(url_for("auth.login"))
