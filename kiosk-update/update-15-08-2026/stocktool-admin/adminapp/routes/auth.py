from urllib.parse import urlparse
from flask import Blueprint, render_template, redirect, url_for, flash, request, session, g
from adminapp.utils.api_client import api_post, APIError

auth_bp = Blueprint("auth", __name__)


def _is_safe_next_url(target: str) -> bool:
    """Only allow redirecting to same-origin, relative paths after login —
    otherwise a crafted /login?next=https://evil.example.com link could
    send a victim straight to a phishing site after they log in."""
    if not target:
        return False
    parsed = urlparse(target)
    return not parsed.scheme and not parsed.netloc and target.startswith("/")


@auth_bp.route("/", methods=["GET"])
def index():
    if g.current_user:
        return redirect(url_for("dashboard.index"))
    return redirect(url_for("auth.login"))


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if g.current_user:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        try:
            data = api_post("/api/auth/login", {
                "username": username, "password": password, "device": "admin-web",
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("auth/login.html")

        session.permanent = True
        session["api_token"] = data["access_token"]
        g.current_user = data["user"]

        if data["user"].get("force_password_change"):
            flash("You must change your password before continuing.", "warning")
            return redirect(url_for("auth.change_password"))

        next_page = request.args.get("next")
        if next_page and _is_safe_next_url(next_page):
            return redirect(next_page)
        return redirect(url_for("dashboard.index"))

    return render_template("auth/login.html")


@auth_bp.route("/logout")
def logout():
    try:
        api_post("/api/auth/logout")
    except APIError:
        pass  # token may already be invalid/expired — still clear locally
    session.clear()
    flash("You have been logged out.", "info")
    return redirect(url_for("auth.login"))


@auth_bp.route("/change-password", methods=["GET", "POST"])
def change_password():
    if not g.current_user:
        return redirect(url_for("auth.login"))

    if request.method == "POST":
        current_pw = request.form.get("current_password", "")
        new_pw = request.form.get("new_password", "")
        confirm_pw = request.form.get("confirm_password", "")

        if new_pw != confirm_pw:
            flash("New passwords do not match.", "danger")
            return render_template("auth/change_password.html")

        try:
            api_post("/api/auth/change-password", {
                "current_password": current_pw, "new_password": new_pw,
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("auth/change_password.html")

        flash("Password updated successfully.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("auth/change_password.html")
