from flask import Flask, render_template, request, jsonify

from app.config import get_config
from app.extensions import (
    db,
    migrate,
    login_manager,
    csrf,
    mail,
    cors,
    limiter,
    init_redis,
)


def create_app(config_name=None):
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(get_config(config_name))

    _init_extensions(app)
    _register_blueprints(app)
    _register_error_handlers(app)
    _register_hooks(app)
    _register_security_headers(app)
    _register_template_helpers(app)
    _register_logging(app)

    from app.cli import register_cli

    register_cli(app)

    return app


def _init_extensions(app):
    db.init_app(app)
    migrate.init_app(app, db)

    from app import models  # noqa: F401  (ensures all models are registered on db.metadata)
    login_manager.init_app(app)
    csrf.init_app(app)
    mail.init_app(app)
    cors.init_app(app, resources={r"/api/*": {"origins": "*"}})

    app.config["RATELIMIT_STORAGE_URI"] = app.config["RATELIMIT_STORAGE_URI"]
    limiter.init_app(app)

    try:
        init_redis(app)
    except Exception:  # pragma: no cover - redis optional at import time
        pass

    from app.models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))


def _register_blueprints(app):
    from app.auth.routes import auth_bp
    from app.admin.routes import admin_bp
    from app.marketplace.routes import marketplace_bp
    from app.customer.routes import customer_bp
    from app.seller.routes import seller_bp
    from app.orders.routes import orders_bp
    from app.notifications_routes import notifications_bp
    from app.api.v1 import api_v1_bp

    app.register_blueprint(marketplace_bp)
    app.register_blueprint(orders_bp)
    app.register_blueprint(notifications_bp)
    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(admin_bp, url_prefix="/admin")
    app.register_blueprint(customer_bp, url_prefix="/customer")
    app.register_blueprint(seller_bp, url_prefix="/seller")
    app.register_blueprint(api_v1_bp, url_prefix="/api/v1")
    csrf.exempt(api_v1_bp)
    limiter.limit("120 per minute")(api_v1_bp)


def _register_error_handlers(app):
    def wants_json():
        return (
            request.path.startswith("/api/")
            or request.accept_mimetypes.best == "application/json"
        )

    def handle(code, template):
        def handler(err):
            if wants_json():
                return jsonify(
                    {
                        "success": False,
                        "error": {"code": template.upper(), "message": str(err)},
                    }
                ), code
            return render_template(f"errors/{code}.html"), code

        return handler

    for code, name in (
        (400, "bad_request"),
        (403, "forbidden"),
        (404, "not_found"),
        (429, "rate_limited"),
        (500, "server_error"),
    ):
        app.register_error_handler(code, handle(code, name))


def _register_hooks(app):
    from flask_login import current_user
    from app.models.settings import SystemSetting

    @app.before_request
    def check_maintenance_mode():
        if request.path.startswith("/static/"):
            return None
        try:
            maintenance = SystemSetting.get("maintenance_mode", False)
        except Exception:
            maintenance = False
        if maintenance and not (
            request.path.startswith("/admin")
            or request.path.startswith("/auth")
        ):
            if current_user.is_authenticated and current_user.has_permission(
                "settings.edit"
            ):
                return None
            return render_template("maintenance.html"), 503
        return None


def _register_template_helpers(app):
    from app.utils.helpers import format_hardware_value

    app.jinja_env.filters["hwval"] = format_hardware_value

    @app.context_processor
    def inject_globals():
        from datetime import datetime as _dt

        return {"current_year": _dt.utcnow().year, "app_name": "OpsLabs Servers"}


def _register_security_headers(app):
    @app.after_request
    def set_security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
        # 'unsafe-eval' is required by Alpine.js, which evaluates x-data/@click
        # expression strings via `new Function(...)` at runtime rather than
        # only executing static <script> tags.
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net; "
            "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
            "img-src 'self' data: https:; "
            "font-src 'self' data:; "
            "connect-src 'self'"
        )
        if not app.debug and not app.testing:
            response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        return response


def _register_logging(app):
    import logging
    import sys

    if app.debug or app.testing:
        return

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    )
    app.logger.handlers = [handler]
    app.logger.setLevel(logging.INFO)
