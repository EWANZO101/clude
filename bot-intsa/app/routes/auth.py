import hmac

from flask import Blueprint, current_app, redirect, render_template, request, session, url_for

bp = Blueprint("auth", __name__)


@bp.route("/login", methods=["GET", "POST"])
def login():
    configured_user = current_app.config.get("APP_USERNAME")
    configured_pass = current_app.config.get("APP_PASSWORD")
    error = None

    if not configured_user or not configured_pass:
        error = "APP_USERNAME and APP_PASSWORD are not set in .env - the app stays locked until you set them."
    elif request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")
        if hmac.compare_digest(username, configured_user) and hmac.compare_digest(password, configured_pass):
            session.clear()
            session["authenticated"] = True
            session.permanent = True
            return redirect(request.args.get("next") or url_for("dashboard.index"))
        error = "Invalid username or password."

    locked = not (configured_user and configured_pass)
    return render_template("login.html", error=error, locked=locked)


@bp.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("auth.login"))
