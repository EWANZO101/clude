from flask import render_template, redirect, url_for, request, flash, abort
from flask_login import current_user

from app.extensions import db
from app.models.api import ApiKey, Webhook
from app.utils.helpers import log_audit
from app.seller.server_views import _active_seller_or_redirect

DEFAULT_SELLER_SCOPES = ["servers:read", "servers:write", "orders:read", "orders:write", "webhooks:manage"]


def register_seller_api_views(seller_bp):
    @seller_bp.route("/api", methods=["GET", "POST"])
    def api():
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))

        new_raw_key = None
        if request.method == "POST":
            name = request.form.get("name", "Seller API Key")
            api_key, new_raw_key = ApiKey.generate(
                user_id=current_user.id, name=name, scopes=DEFAULT_SELLER_SCOPES, seller_id=profile.id
            )
            db.session.add(api_key)
            log_audit("api_key.created", "ApiKey", None)
            db.session.commit()
            flash("API key created. Copy it now — it will not be shown again.", "success")

        keys = ApiKey.query.filter_by(user_id=current_user.id).order_by(ApiKey.created_at.desc()).all()
        return render_template("seller/api.html", keys=keys, new_raw_key=new_raw_key)

    @seller_bp.route("/api/keys/<int:key_id>/revoke", methods=["POST"])
    def api_key_revoke(key_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        api_key = ApiKey.query.filter_by(id=key_id, user_id=current_user.id).first()
        if api_key is None:
            abort(404)
        from app.models.base import utcnow

        api_key.is_active = False
        api_key.revoked_at = utcnow()
        db.session.commit()
        flash("API key revoked.", "success")
        return redirect(url_for("seller.api"))

    @seller_bp.route("/webhooks", methods=["GET", "POST"])
    def webhooks():
        import secrets

        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))

        if request.method == "POST":
            url = request.form.get("url", "").strip()
            events = [e.strip() for e in request.form.get("events", "").split(",") if e.strip()]
            if url:
                db.session.add(
                    Webhook(seller_id=profile.id, owner_user_id=current_user.id, url=url, secret=secrets.token_hex(32), events=events)
                )
                db.session.commit()
                flash("Webhook added.", "success")
            return redirect(url_for("seller.webhooks"))

        hooks = Webhook.query.filter_by(seller_id=profile.id).order_by(Webhook.created_at.desc()).all()
        return render_template("seller/webhooks.html", webhooks=hooks)

    @seller_bp.route("/webhooks/<int:webhook_id>/delete", methods=["POST"])
    def webhook_delete(webhook_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        webhook = Webhook.query.filter_by(id=webhook_id, seller_id=profile.id).first()
        if webhook is None:
            abort(404)
        db.session.delete(webhook)
        db.session.commit()
        flash("Webhook removed.", "success")
        return redirect(url_for("seller.webhooks"))
