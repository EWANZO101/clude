import re
from datetime import datetime
from flask import (Blueprint, render_template, request, redirect, url_for,
                   flash, current_app)
from flask_login import login_user, logout_user, login_required, current_user
from flask_mail import Message
from .. import db, mail
from ..models import User, PasswordResetToken
from ..security import safe_next

USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")
MIN_PASSWORD = 8


def password_problem(pw):
    """Return a human-readable reason the password is too weak, or None."""
    if len(pw) < MIN_PASSWORD:
        return f"Password must be at least {MIN_PASSWORD} characters."
    if pw.isdigit() or pw.isalpha():
        return "Password must mix letters with numbers or symbols."
    return None

auth_bp = Blueprint("auth", __name__)


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("main.index"))

    if request.method == "POST":
        ident = request.form.get("identifier", "").strip()
        password = request.form.get("password", "")
        user = User.query.filter(
            (User.username == ident) | (User.email == ident.lower())
        ).first()

        if not user or not user.check_password(password):
            flash("Invalid credentials.", "error")
            return render_template("auth/login.html")
        if not user.is_active:
            flash("Your account is disabled. Contact an admin.", "error")
            return render_template("auth/login.html")

        login_user(user, remember=True)
        user.last_login_at = datetime.utcnow()
        db.session.commit()
        flash(f"Welcome back, {user.username}.", "success")
        next_url = safe_next(request.args.get("next"), url_for("main.index"))
        return redirect(next_url)

    return render_template("auth/login.html")


@auth_bp.route("/register", methods=["GET", "POST"])
def register():
    if current_user.is_authenticated:
        return redirect(url_for("main.index"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        confirm = request.form.get("confirm", "")

        if not username or not email or not password:
            flash("All fields are required.", "error")
            return render_template("auth/register.html")
        if not USERNAME_RE.match(username):
            flash("Username must be 3–32 characters: letters, numbers, dot, dash or underscore.", "error")
            return render_template("auth/register.html")
        if len(email) > 120 or not EMAIL_RE.match(email):
            flash("Please enter a valid email address.", "error")
            return render_template("auth/register.html")
        problem = password_problem(password)
        if problem:
            flash(problem, "error")
            return render_template("auth/register.html")
        if password != confirm:
            flash("Passwords don't match.", "error")
            return render_template("auth/register.html")
        if User.query.filter((db.func.lower(User.username) == username.lower()) | (User.email == email)).first():
            flash("Username or email already in use.", "error")
            return render_template("auth/register.html")

        u = User(username=username, email=email, role="user", is_active=True)
        u.set_password(password)
        db.session.add(u)
        db.session.commit()
        login_user(u, remember=True)
        flash("Account created. Welcome to Ops Labs.", "success")
        return redirect(url_for("main.index"))

    return render_template("auth/register.html")


@auth_bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("Signed out.", "info")
    return redirect(url_for("main.index"))


@auth_bp.route("/forgot", methods=["GET", "POST"])
def forgot():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        user = User.query.filter_by(email=email).first()
        if user:
            tok = PasswordResetToken.create_for(user)
            reset_url = url_for("auth.reset", token=tok.token, _external=True)
            try:
                if current_app.config.get("MAIL_USERNAME"):
                    msg = Message(
                        subject="Ops Labs — Reset your password",
                        recipients=[user.email],
                        body=(f"Hi {user.username},\n\n"
                              f"Click the link below to reset your password:\n{reset_url}\n\n"
                              f"This link expires in 2 hours.\n\n— Ops Labs"),
                    )
                    mail.send(msg)
                else:
                    current_app.logger.info(f"[DEV] Password reset link: {reset_url}")
            except Exception as e:
                current_app.logger.error(f"Mail send failed: {e}")
                current_app.logger.info(f"[FALLBACK] Reset link: {reset_url}")

        # Always show same message (don't leak existence)
        flash("If that email exists, a reset link has been sent.", "info")
        return redirect(url_for("auth.login"))

    return render_template("auth/forgot.html")


@auth_bp.route("/reset/<token>", methods=["GET", "POST"])
def reset(token):
    tok = PasswordResetToken.query.filter_by(token=token).first()
    if not tok or not tok.is_valid:
        flash("Reset link is invalid or expired.", "error")
        return redirect(url_for("auth.forgot"))

    if request.method == "POST":
        pw = request.form.get("password", "")
        confirm = request.form.get("confirm", "")
        if not pw or pw != confirm:
            flash("Passwords don't match.", "error")
            return render_template("auth/reset.html", token=token)
        problem = password_problem(pw)
        if problem:
            flash(problem, "error")
            return render_template("auth/reset.html", token=token)
        tok.user.set_password(pw)
        tok.used = True
        db.session.commit()
        flash("Password reset. You can sign in now.", "success")
        return redirect(url_for("auth.login"))

    return render_template("auth/reset.html", token=token)
