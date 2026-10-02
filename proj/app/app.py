import os
from flask import Flask, render_template, redirect, url_for, request, flash, jsonify
from flask_login import (
    LoginManager, login_user, logout_user, login_required, current_user
)
from werkzeug.security import check_password_hash, generate_password_hash

from config import Config
from models import db, Account, SessionEvent, AdminUser
import session_manager as sm

app = Flask(__name__)
app.config.from_object(Config)

db.init_app(app)

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = "login"

ADMIN_PASS_HASH = generate_password_hash(app.config["ADMIN_PASS"])


@login_manager.user_loader
def load_user(username):
    if username == app.config["ADMIN_USER"]:
        return AdminUser(username)
    return None


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")
        if username == app.config["ADMIN_USER"] and check_password_hash(
            ADMIN_PASS_HASH, password
        ):
            login_user(AdminUser(username))
            return redirect(url_for("dashboard"))
        flash("Invalid credentials", "error")
    return render_template("login.html")


@app.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def dashboard():
    accounts = Account.query.order_by(Account.created_at.desc()).all()
    statuses = {a.id: sm.is_running(a.screen_name(), a.os_user) for a in accounts}
    return render_template("dashboard.html", accounts=accounts, statuses=statuses)


@app.route("/accounts/new", methods=["GET", "POST"])
@login_required
def new_account():
    if request.method == "POST":
        account = Account(
            name=request.form["name"],
            team_label=request.form.get("team_label"),
            project_path=request.form.get("project_path"),
            config_dir=request.form.get("config_dir"),
            api_key=request.form.get("api_key"),
            model=request.form.get("model"),
            notes=request.form.get("notes"),
            os_user=request.form.get("os_user") or None,
        )
        db.session.add(account)
        db.session.commit()
        flash("Account created", "success")
        return redirect(url_for("dashboard"))
    return render_template("account_form.html", account=None, allowed_os_users=app.config["ALLOWED_OS_USERS"])


@app.route("/accounts/<int:account_id>/edit", methods=["GET", "POST"])
@login_required
def edit_account(account_id):
    account = Account.query.get_or_404(account_id)
    if request.method == "POST":
        account.name = request.form["name"]
        account.team_label = request.form.get("team_label")
        account.project_path = request.form.get("project_path")
        account.config_dir = request.form.get("config_dir")
        account.api_key = request.form.get("api_key")
        account.model = request.form.get("model")
        account.notes = request.form.get("notes")
        account.os_user = request.form.get("os_user") or None
        db.session.add(SessionEvent(account_id=account.id, action="configure",
                                     detail="Settings updated"))
        db.session.commit()
        flash("Account updated", "success")
        return redirect(url_for("dashboard"))
    return render_template("account_form.html", account=account, allowed_os_users=app.config["ALLOWED_OS_USERS"])


@app.route("/accounts/<int:account_id>/delete", methods=["POST"])
@login_required
def delete_account(account_id):
    account = Account.query.get_or_404(account_id)
    sm.stop_session(account)
    SessionEvent.query.filter_by(account_id=account.id).delete()
    db.session.delete(account)
    db.session.commit()
    flash("Account deleted", "success")
    return redirect(url_for("dashboard"))


@app.route("/api/accounts/<int:account_id>/start", methods=["POST"])
@login_required
def api_start(account_id):
    account = Account.query.get_or_404(account_id)
    ok, msg = sm.start_session(account, app.config["LOG_DIR"], app.config["CLAUDE_HOMES_DIR"])
    db.session.add(SessionEvent(account_id=account.id, action="start", detail=msg))
    db.session.commit()
    return jsonify({"ok": ok, "message": msg})


@app.route("/api/accounts/<int:account_id>/stop", methods=["POST"])
@login_required
def api_stop(account_id):
    account = Account.query.get_or_404(account_id)
    ok, msg = sm.stop_session(account)
    db.session.add(SessionEvent(account_id=account.id, action="stop", detail=msg))
    db.session.commit()
    return jsonify({"ok": ok, "message": msg})


@app.route("/api/accounts/<int:account_id>/status")
@login_required
def api_status(account_id):
    account = Account.query.get_or_404(account_id)
    running = sm.is_running(account.screen_name(), account.os_user)
    return jsonify({"running": running})


@app.route("/api/accounts/<int:account_id>/log")
@login_required
def api_log(account_id):
    account = Account.query.get_or_404(account_id)
    log = sm.tail_log(account, app.config["LOG_DIR"])
    return jsonify({"log": log, "running": sm.is_running(account.screen_name(), account.os_user)})


@app.route("/api/accounts/<int:account_id>/input", methods=["POST"])
@login_required
def api_input(account_id):
    account = Account.query.get_or_404(account_id)
    text = request.json.get("text", "") if request.is_json else request.form.get("text", "")
    if request.is_json and request.json.get("enter"):
        text += "\r"
    ok, msg = sm.send_keys(account, text)
    return jsonify({"ok": ok, "message": msg})


with app.app_context():
    db.create_all()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=app.config["PORT"], debug=False)
