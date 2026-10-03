import os
from flask import Flask, jsonify
from werkzeug.middleware.proxy_fix import ProxyFix
from config import Config
from app.extensions import db, jwt


def create_app(config_class=Config) -> Flask:
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config_class)

    # Trusts nginx's X-Forwarded-Proto/Host/For headers so url_for(...,
    # _external=True) generates https:// URLs once this sits behind a
    # reverse proxy — without this, the QR pairing link and barcode image
    # URLs would keep saying http:// even after HTTPS is set up, since
    # Flask only sees the plain HTTP connection nginx makes to it locally.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    os.makedirs(app.instance_path, exist_ok=True)
    os.makedirs(app.config["BARCODE_OUTPUT_DIR"], exist_ok=True)

    db.init_app(app)
    jwt.init_app(app)

    # ── JWT user loader ────────────────────────────────────────────────────
    # Loads the user fresh from the DB on every JWT-authenticated request
    # instead of trusting the "role" claim baked into the token at login
    # time. Without this, an admin who is demoted or disabled keeps
    # working API access (including admin-only endpoints) for up to the
    # token's full 8-hour lifetime.
    from app.models.user import User

    @jwt.user_lookup_loader
    def user_lookup_callback(_jwt_header, jwt_data):
        identity = jwt_data["sub"]
        user = db.session.get(User, int(identity))
        if user and user.is_active:
            return user
        return None

    @jwt.user_lookup_error_loader
    def user_lookup_error_callback(_jwt_header, _jwt_data):
        return jsonify({"error": "User not found or inactive"}), 401

    @jwt.unauthorized_loader
    def missing_token_callback(reason):
        return jsonify({"error": "Authorization required", "detail": reason}), 401

    @jwt.invalid_token_loader
    def invalid_token_callback(reason):
        return jsonify({"error": "Invalid token", "detail": reason}), 401

    @jwt.expired_token_loader
    def expired_token_callback(_jwt_header, _jwt_data):
        return jsonify({"error": "Token expired"}), 401

    # ── REST API blueprints ─────────────────────────────────────────────────
    from app.api.auth import api_auth_bp
    app.register_blueprint(api_auth_bp)

    from app.api.users import api_users_bp
    app.register_blueprint(api_users_bp)

    from app.api.items import api_items_bp
    app.register_blueprint(api_items_bp)

    from app.api.tools import api_tools_bp
    app.register_blueprint(api_tools_bp)

    from app.api.projects import api_projects_bp
    app.register_blueprint(api_projects_bp)

    from app.api.barcodes import api_barcodes_bp
    app.register_blueprint(api_barcodes_bp)

    from app.api.audit import api_audit_bp
    app.register_blueprint(api_audit_bp)

    from app.api.settings import api_settings_bp
    app.register_blueprint(api_settings_bp)

    # ── Kiosk touch-UI (same app, direct DB access, plain cookie session) ──
    from app.kiosk.routes import kiosk_bp
    app.register_blueprint(kiosk_bp)

    # ── Generic phone-scan relay (used by the admin frontend as a backup
    #    scanner on any page — separate from the kiosk's login-bound pairing) ──
    from app.api.scan_relay import scan_relay_bp
    app.register_blueprint(scan_relay_bp)

    @app.route("/")
    def root():
        return jsonify({"service": "StockTool API", "kiosk_ui": "/kiosk/"}), 200

    @app.after_request
    def set_security_headers(response):
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "same-origin")
        return response

    if not app.debug and not app.testing:
        if app.config.get("SECRET_KEY") == "change-me-in-production":
            app.logger.warning(
                "SECRET_KEY is set to the insecure default. Set the SECRET_KEY "
                "environment variable before exposing this app on a network."
            )
        if app.config.get("JWT_SECRET_KEY") == "jwt-change-me-in-production":
            app.logger.warning(
                "JWT_SECRET_KEY is set to the insecure default. Set the "
                "JWT_SECRET_KEY environment variable before exposing this app "
                "on a network."
            )

    return app
