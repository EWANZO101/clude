import os
from datetime import datetime, timezone
from flask import Flask, render_template
from config import Config
from app.extensions import db, login_manager, jwt, csrf


def create_app(config_class=Config) -> Flask:
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config_class)

    os.makedirs(app.instance_path, exist_ok=True)
    os.makedirs(app.config["BARCODE_OUTPUT_DIR"], exist_ok=True)

    # ── Extensions ─────────────────────────────────────────────────────────
    db.init_app(app)
    login_manager.init_app(app)
    jwt.init_app(app)
    csrf.init_app(app)

    # ── User loader ────────────────────────────────────────────────────────
    from app.models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    # ── JWT user loader ────────────────────────────────────────────────────
    # Loads the user fresh from the DB on every JWT-authenticated request
    # instead of trusting the "role" claim baked into the token at login
    # time. Without this, an admin who is demoted or disabled keeps
    # working API access (including admin-only endpoints) for up to the
    # token's full 8-hour lifetime.
    @jwt.user_lookup_loader
    def user_lookup_callback(_jwt_header, jwt_data):
        identity = jwt_data["sub"]
        user = db.session.get(User, int(identity))
        if user and user.is_active:
            return user
        return None

    @jwt.user_lookup_error_loader
    def user_lookup_error_callback(_jwt_header, _jwt_data):
        from flask import jsonify
        return jsonify({"error": "User not found or inactive"}), 401

    # ── Context processor — inject 'now' into all templates ────────────────
    @app.context_processor
    def inject_now():
        return {"now": datetime.now(timezone.utc)}

    # ── Error handlers ─────────────────────────────────────────────────────
    @app.errorhandler(403)
    def forbidden(e):
        return render_template("errors/403.html"), 403

    @app.errorhandler(404)
    def not_found(e):
        return render_template("errors/404.html"), 404

    # ── Web blueprints ─────────────────────────────────────────────────────
    from app.routes.auth import auth_bp
    app.register_blueprint(auth_bp)

    from app.routes.dashboard import dashboard_bp
    app.register_blueprint(dashboard_bp)

    from app.routes.items import items_bp
    app.register_blueprint(items_bp)

    from app.routes.tools import tools_bp
    app.register_blueprint(tools_bp)

    from app.routes.projects import projects_bp
    app.register_blueprint(projects_bp)

    from app.routes.logs import logs_bp
    app.register_blueprint(logs_bp)

    from app.routes.admin import admin_bp
    app.register_blueprint(admin_bp)

    from app.routes.barcode import barcode_bp
    app.register_blueprint(barcode_bp)

    # ── API blueprints ─────────────────────────────────────────────────────
    # These are authenticated with JWT bearer tokens (not cookies), so they
    # are not subject to CSRF (a browser can't forge an Authorization header)
    # and are exempted from Flask-WTF's CSRF checks.
    from app.api.auth import api_auth_bp
    app.register_blueprint(api_auth_bp)
    csrf.exempt(api_auth_bp)

    from app.api.items import api_items_bp
    app.register_blueprint(api_items_bp)
    csrf.exempt(api_items_bp)

    from app.api.tools import api_tools_bp
    app.register_blueprint(api_tools_bp)
    csrf.exempt(api_tools_bp)

    from app.api.kiosk import api_kiosk_bp
    app.register_blueprint(api_kiosk_bp)
    csrf.exempt(api_kiosk_bp)

    # ── Security headers ──────────────────────────────────────────────────
    @app.after_request
    def set_security_headers(response):
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "same-origin")
        return response

    # ── Startup safety check ──────────────────────────────────────────────
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
