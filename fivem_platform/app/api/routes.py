import hmac
import hashlib
import json
from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, url_for, current_app

from app.api import api_bp
from app.extensions import db, limiter
from app.models.developer import Product, License, TebexIntegration, Module, UsageEvent
from app.models.portal import FivemServer, ServerLicense
from app.models.user import User
from app.utils import verify_secret, decrypt_secret, generate_license_key, hash_server_token
from app.auth.mailer import send_email


@api_bp.route("/api/server/config", methods=["POST"])
@limiter.limit("30 per minute")
def server_config():
    """The one call CloudLoader makes at startup. Given just the server
    token, returns every attached product's {product_id, api_key,
    license_key} - no manual per-product config needed. Attachments with
    a revoked/suspended license are silently excluded."""
    data = request.get_json(silent=True) or {}
    token = data.get("server_token", "")
    if not token:
        return jsonify({"error": "Missing server_token."}), 400

    server = FivemServer.query.filter_by(token_hash=hash_server_token(token)).first()
    if not server:
        return jsonify({"error": "Unknown server token."}), 401

    server.last_seen_at = datetime.now(timezone.utc)
    db.session.commit()

    products = []
    for attachment in server.attachments:
        lic = attachment.license
        if not lic.is_valid:
            continue
        developer_profile = lic.product.developer.developer_profile
        api_base = (
            developer_profile.effective_api_base(current_app.config["SITE_URL"])
            if developer_profile else current_app.config["SITE_URL"]
        )
        products.append({
            "product_id": lic.product.product_id,
            "product_name": lic.product.name,
            "api_key": lic.product.api_key,
            "license_key": lic.license_key,
            "api_base": api_base,
            "channel": attachment.channel,
        })

    return jsonify({"server_name": server.name, "products": products})


@api_bp.route("/api/ping", methods=["GET"])
def ping():
    """Lightweight, unauthenticated health check used to verify a
    developer's custom domain is actually CNAME'd and proxying to this
    platform correctly before their generated files start using it."""
    return jsonify({"ok": True, "platform": current_app.config["SITE_NAME"]})


@api_bp.route("/api/license/check/<product_id>", methods=["POST"])
@limiter.limit("120 per minute")
def license_check(product_id):
    """Called by the CloudLoader resource (or a developer's own integration)
    to validate a license. Requires the product's api_key + secret_key plus
    the customer's license_key.

    POST body (JSON):
      { "api_key": "...", "secret_key": "...", "license_key": "...", "server_id": "optional" }
    """
    data = request.get_json(silent=True) or {}
    api_key = data.get("api_key", "")
    secret_key = data.get("secret_key", "")
    license_key = data.get("license_key", "").strip().upper()
    server_id = data.get("server_id")

    product = Product.query.filter_by(product_id=product_id, api_key=api_key, is_active=True).first()

    if not product or not verify_secret(secret_key, product.secret_key_hash):
        return jsonify({"valid": False, "message": "Invalid product credentials."}), 401

    license_obj = License.query.filter_by(license_key=license_key, product_id=product.id).first()

    if not license_obj:
        return jsonify({"valid": False, "message": "License key not found for this product."}), 404

    now = datetime.now(timezone.utc)
    license_obj.last_checked_at = now
    if not license_obj.activated_at:
        license_obj.activated_at = now
    if server_id and not license_obj.server_binding:
        license_obj.server_binding = server_id
    db.session.commit()

    if not license_obj.is_valid:
        return jsonify({
            "valid": False,
            "message": f"License is {license_obj.status}.",
        }), 403

    return jsonify({
        "valid": True,
        "product": {"name": product.name, "version": product.version},
        "license": {
            "status": license_obj.status,
            "expires_at": license_obj.expires_at.isoformat() if license_obj.expires_at else None,
        },
    })


@api_bp.route("/api/license/activate/<product_id>", methods=["POST"])
@limiter.limit("120 per minute")
def license_activate(product_id):
    """Called by the injected platform/license.lua at runtime. Unlike
    /api/license/check, this only needs the product's PUBLIC api_key (the
    one that's safe to embed in a distributed script) plus the customer's
    license_key - never the developer's secret_key."""
    data = request.get_json(silent=True) or {}
    api_key = data.get("api_key", "")
    license_key = data.get("license_key", "").strip().upper()
    server_id = data.get("server_id")

    product = Product.query.filter_by(product_id=product_id, api_key=api_key, is_active=True).first()
    if not product:
        return jsonify({"valid": False, "message": "Invalid product API key."}), 401

    license_obj = License.query.filter_by(license_key=license_key, product_id=product.id).first()
    if not license_obj:
        return jsonify({"valid": False, "message": "License key not found for this product."}), 404

    now = datetime.now(timezone.utc)
    license_obj.last_checked_at = now
    if not license_obj.activated_at:
        license_obj.activated_at = now
    if server_id and not license_obj.server_binding:
        license_obj.server_binding = server_id
    db.session.commit()

    if not license_obj.is_valid:
        return jsonify({"valid": False, "message": f"License is {license_obj.status}."}), 403

    db.session.add(UsageEvent(product_id=product.id, license_id=license_obj.id, event_type="license_check"))
    db.session.commit()

    return jsonify({
        "valid": True,
        "product": {"name": product.name, "version": product.version},
    })


@api_bp.route("/api/update/check/<product_id>", methods=["POST"])
@limiter.limit("60 per minute")
def update_check(product_id):
    """Called by the injected platform/updater.lua. Public-key gated only."""
    data = request.get_json(silent=True) or {}
    api_key = data.get("api_key", "")
    current_version = data.get("current_version", "")

    product = Product.query.filter_by(product_id=product_id, api_key=api_key).first()
    if not product:
        return jsonify({"error": "Invalid product API key."}), 401

    return jsonify({
        "latest_version": product.version,
        "update_available": current_version != "" and current_version != product.version,
    })


def _require_valid_license(product_id, api_key, license_key, server_id=None):
    """Shared gate for module endpoints: product must exist and be active,
    and the license must be valid for it. Returns (product, license, error_response)."""
    product = Product.query.filter_by(product_id=product_id, api_key=api_key, is_active=True).first()
    if not product:
        return None, None, (jsonify({"error": "Invalid product API key."}), 401)

    license_obj = License.query.filter_by(
        license_key=(license_key or "").strip().upper(), product_id=product.id
    ).first()
    if not license_obj:
        return None, None, (jsonify({"error": "License key not found."}), 404)

    now = datetime.now(timezone.utc)
    license_obj.last_checked_at = now
    if not license_obj.activated_at:
        license_obj.activated_at = now
    if server_id and not license_obj.server_binding:
        license_obj.server_binding = server_id
    db.session.commit()

    if not license_obj.is_valid:
        return None, None, (jsonify({"error": f"License is {license_obj.status}."}), 403)

    return product, license_obj, None


def _resolve_channel_modules(product_id, requested_channel):
    """Beta customers get beta-specific modules where they exist, and fall
    back to the stable version of anything that doesn't have a beta
    override - so opting into beta never means getting FEWER modules than
    stable customers, just newer ones where a developer has published them."""
    if requested_channel not in ("stable", "beta"):
        requested_channel = "stable"

    all_modules = Module.query.filter_by(product_id=product_id, is_active=True).all()
    by_name = {}
    for m in all_modules:
        if m.channel == "stable":
            by_name.setdefault(m.name, {})["stable"] = m
        elif m.channel == requested_channel:
            by_name.setdefault(m.name, {})[requested_channel] = m

    resolved = []
    for name, versions in by_name.items():
        chosen = versions.get(requested_channel) or versions.get("stable")
        if chosen:
            resolved.append(chosen)
    return resolved


@api_bp.route("/api/module/list/<product_id>", methods=["POST"])
@limiter.limit("60 per minute")
def module_list(product_id):
    """Called by CloudLoader's module_loader.lua to discover which modules
    a licensed customer can use for a product."""
    data = request.get_json(silent=True) or {}
    product, license_obj, error = _require_valid_license(
        product_id, data.get("api_key", ""), data.get("license_key", ""), data.get("server_id")
    )
    if error:
        return error

    requested_channel = data.get("channel", "stable")
    modules = _resolve_channel_modules(product.id, requested_channel)
    return jsonify({
        "modules": [
            {"name": m.name, "display_name": m.display_name, "side": m.side, "version": m.version, "channel": m.channel}
            for m in modules
        ]
    })


@api_bp.route("/api/module/download/<product_id>/<module_name>", methods=["POST"])
@limiter.limit("60 per minute")
def module_download(product_id, module_name):
    """Returns the raw Lua source for one module. The code lives here, not
    on the customer's disk - this is what makes it 'delivered from the
    platform' per the spec."""
    data = request.get_json(silent=True) or {}
    product, license_obj, error = _require_valid_license(
        product_id, data.get("api_key", ""), data.get("license_key", ""), data.get("server_id")
    )
    if error:
        return error

    requested_channel = data.get("channel", "stable")
    if requested_channel not in ("stable", "beta"):
        requested_channel = "stable"

    module = Module.query.filter_by(
        product_id=product.id, name=module_name, channel=requested_channel, is_active=True
    ).first()
    if not module and requested_channel != "stable":
        # No beta override for this specific module - fall back to stable.
        module = Module.query.filter_by(
            product_id=product.id, name=module_name, channel="stable", is_active=True
        ).first()
    if not module:
        return jsonify({"error": "Module not found."}), 404

    db.session.add(UsageEvent(
        product_id=product.id, license_id=license_obj.id,
        event_type="module_download", module_name=module.name,
    ))
    db.session.commit()

    return jsonify({
        "name": module.name,
        "side": module.side,
        "version": module.version,
        "channel": module.channel,
        "code": module.code,
    })


@api_bp.route("/api/config/load/<product_id>", methods=["POST"])
@limiter.limit("60 per minute")
def config_load(product_id):
    """Remote Configuration - per the spec's Automatic API Injector
    'Config loader' function. Lets a developer tune values live without
    republishing any module code. License-gated like module endpoints."""
    data = request.get_json(silent=True) or {}
    product, license_obj, error = _require_valid_license(
        product_id, data.get("api_key", ""), data.get("license_key", ""), data.get("server_id")
    )
    if error:
        return error

    config = {}
    if product.remote_config:
        try:
            config = json.loads(product.remote_config)
        except (ValueError, TypeError):
            config = {}

    return jsonify({"config": config})


def _unique_license_key():
    while True:
        candidate = generate_license_key()
        if not License.query.filter_by(license_key=candidate).first():
            return candidate


@api_bp.route("/api/tebex/webhook/<product_id>", methods=["POST"])
@limiter.limit("60 per minute")
def tebex_webhook(product_id):
    """Tebex (or a test client) posts purchase events here. Verified via
    HMAC-SHA256 over the raw request body using the product's webhook
    secret, sent in the X-Signature header - the same shape as Tebex's own
    webhook signing scheme.

    Expected JSON body:
      {
        "email": "customer@example.com",
        "package_id": "optional - filtered against integration setting",
        "transaction_id": "optional, for your own records",
        "quantity": 1
      }
    """
    product = Product.query.filter_by(product_id=product_id).first()
    if not product or not product.tebex_integration:
        return jsonify({"status": "error", "message": "No Tebex integration for this product."}), 404

    integration = product.tebex_integration
    if not integration.is_active:
        return jsonify({"status": "error", "message": "Tebex integration is paused."}), 403

    raw_body = request.get_data()
    signature = request.headers.get("X-Signature", "")

    try:
        secret = decrypt_secret(integration.webhook_secret_encrypted)
    except Exception:
        return jsonify({"status": "error", "message": "Webhook not configured correctly."}), 500

    expected_sig = hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected_sig, signature):
        return jsonify({"status": "error", "message": "Invalid signature."}), 401

    data = request.get_json(silent=True) or {}
    email = (data.get("email") or "").strip().lower()
    package_id = data.get("package_id")
    quantity = data.get("quantity", 1)

    if not email:
        return jsonify({"status": "error", "message": "Missing customer email."}), 400

    if integration.package_id_filter and package_id and str(package_id) != integration.package_id_filter:
        return jsonify({"status": "ignored", "message": "Package ID does not match this integration."}), 200

    try:
        quantity = max(1, min(int(quantity), 20))
    except (TypeError, ValueError):
        quantity = 1

    created_keys = []
    for _ in range(quantity):
        lic = License(
            product_id=product.id,
            developer_id=product.developer_id,
            license_key=_unique_license_key(),
            customer_email=email,
        )
        db.session.add(lic)
        created_keys.append(lic)

    integration.last_event_at = datetime.now(timezone.utc)
    integration.total_purchases += 1
    for lic in created_keys:
        db.session.add(UsageEvent(product_id=product.id, license_id=lic.id, event_type="tebex_purchase"))
    db.session.commit()

    # Auto-link to an existing account with this email, and auto-attach to
    # their server if they have exactly one - if they have zero or several,
    # we can't guess which one, so leave it for them to attach in the portal.
    existing_user = User.query.filter_by(email=email).first()
    auto_attached = False
    if existing_user:
        for lic in created_keys:
            lic.customer_user_id = existing_user.id
        db.session.commit()

        servers = FivemServer.query.filter_by(owner_id=existing_user.id).all()
        if len(servers) == 1:
            for lic in created_keys:
                db.session.add(ServerLicense(server_id=servers[0].id, license_id=lic.id))
            db.session.commit()
            auto_attached = True

    portal_url = url_for("portal.my_licenses", _external=True)
    cloudloader_url = url_for("cloudloader.info", _external=True)

    if existing_user and auto_attached:
        setup_note = (
            f"This is already attached to your server ({servers[0].name}) - "
            "nothing else to do. It'll be live on the next re-check "
            "(or restart CloudLoader for it immediately)."
        )
    elif existing_user:
        setup_note = (
            f"View and attach it to a server here: {portal_url}\n"
            f"(First time? Install CloudLoader: {cloudloader_url})"
        )
    else:
        key_list = "\n".join(f"  {lic.license_key}" for lic in created_keys)
        setup_note = (
            f"Sign up at {portal_url} with this email address and it'll show "
            f"up automatically - no need to copy the key below by hand.\n\n"
            f"Your license key{'s' if quantity > 1 else ''} (fallback, if you'd rather set up manually):\n{key_list}\n\n"
            f"Install CloudLoader: {cloudloader_url}"
        )

    send_email(
        to=email,
        subject=f"Your {product.name} license",
        body=(
            f"Thanks for your purchase!\n\n"
            f"Product: {product.name} (v{product.version})\n\n"
            f"{setup_note}"
        ),
    )

    developer = product.developer
    if developer.developer_profile and developer.developer_profile.email_notifications_enabled:
        send_email(
            to=developer.email,
            subject=f"New sale: {product.name}",
            body=(
                f"{quantity} license{'s' if quantity > 1 else ''} of {product.name} "
                f"just sold to {email}.\n\n"
                f"Total purchases for this product: {integration.total_purchases}\n\n"
                f"View it in your dashboard: {url_for('developer.product_detail', product_id=product.product_id, _external=True)}\n\n"
                f"(Turn these off anytime from your product's settings.)"
            ),
        )

    return jsonify({
        "status": "ok",
        "license_keys": [lic.license_key for lic in created_keys],
    })
