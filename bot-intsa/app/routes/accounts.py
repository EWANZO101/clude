from datetime import datetime

from flask import Blueprint, current_app, redirect, render_template, request, url_for

from ..extensions import db
from ..models import SocialAccount
from ..security import encrypt
from ..services.instagram_agent import test_login

bp = Blueprint("accounts", __name__, url_prefix="/accounts")


@bp.route("/")
def index():
    accounts = SocialAccount.query.all()
    return render_template("accounts.html", accounts=accounts, dry_run=current_app.config["PUBLISH_DRY_RUN"])


@bp.route("/connect", methods=["POST"])
def connect():
    platform = request.form.get("platform", "instagram")
    username = request.form.get("username", "")
    password = request.form.get("password", "")
    totp_secret = request.form.get("totp_secret", "")

    account = SocialAccount.query.filter_by(platform=platform, username=username).first()
    if not account:
        account = SocialAccount(platform=platform, username=username)
        db.session.add(account)

    if password:
        account.encrypted_password = encrypt(password)
    if totp_secret:
        account.encrypted_totp_secret = encrypt(totp_secret)

    db.session.commit()
    return redirect(url_for("accounts.index"))


@bp.route("/<int:account_id>/test", methods=["POST"])
def test(account_id):
    account = SocialAccount.query.get_or_404(account_id)
    result = test_login(account, dry_run=current_app.config["PUBLISH_DRY_RUN"])
    account.connected = result["success"]
    account.last_login_at = datetime.utcnow()
    account.last_login_status = result["message"]
    db.session.commit()
    return redirect(url_for("accounts.index"))


@bp.route("/<int:account_id>/delete", methods=["POST"])
def delete(account_id):
    account = SocialAccount.query.get_or_404(account_id)
    db.session.delete(account)
    db.session.commit()
    return redirect(url_for("accounts.index"))
