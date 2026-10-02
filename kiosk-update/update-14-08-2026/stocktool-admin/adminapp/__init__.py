from datetime import datetime, timezone
from flask import Flask, render_template, g, session
from flask_wtf import CSRFProtect
from werkzeug.middleware.proxy_fix import ProxyFix
from config import Config
from adminapp.utils.api_client import api_get, APIError

csrf = CSRFProtect()


def create_app(config_class=Config) -> Flask:
    app = Flask(__name__)
    app.config.from_object(config_class)

    # Same reasoning as stocktool-api: trust nginx's forwarded headers once
    # this sits behind a reverse proxy, so redirects and cookies behave
    # correctly under https:// instead of Flask assuming plain http://.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    csrf.init_app(app)

    # ── Populate g.current_user from the API on every request ──────────────
    # This app holds no user table of its own, so "who is logged in and
    # what's their current role" is only ever known by asking the API —
    # every page load re-validates the session's token against it, which
    # also means a demotion/deactivation made elsewhere takes effect on
    # this session's very next request rather than waiting out a stale
    # local session.
    @app.before_request
    def load_current_user():
        g.current_user = None
        token = session.get("api_token")
        if not token:
            return
        try:
            g.current_user = api_get("/api/auth/me")
        except APIError as e:
            if e.status_code == 401:
                session.clear()
            # Any other error (API unreachable, etc.) — leave g.current_user
            # as None; individual routes will surface the error via flash
            # when they themselves try to call the API.

    @app.context_processor
    def inject_globals():
        return {
            "now": datetime.now(timezone.utc),
            "current_user": g.get("current_user"),
            "api_public_url": app.config["API_PUBLIC_URL"].rstrip("/"),
        }

    @app.errorhandler(403)
    def forbidden(e):
        return render_template("errors/403.html"), 403

    @app.errorhandler(404)
    def not_found(e):
        return render_template("errors/404.html"), 404

    # ── Blueprints ───────────────────────────────────────────────────────────
    from adminapp.routes.auth import auth_bp
    app.register_blueprint(auth_bp)

    from adminapp.routes.dashboard import dashboard_bp
    app.register_blueprint(dashboard_bp)

    from adminapp.routes.items import items_bp
    app.register_blueprint(items_bp)

    from adminapp.routes.tools import tools_bp
    app.register_blueprint(tools_bp)

    from adminapp.routes.projects import projects_bp
    app.register_blueprint(projects_bp)

    from adminapp.routes.admin import admin_bp
    app.register_blueprint(admin_bp)

    from adminapp.routes.barcode import barcode_bp
    app.register_blueprint(barcode_bp)

    from adminapp.routes.logs import logs_bp
    app.register_blueprint(logs_bp)

    from adminapp.routes.settings import settings_bp
    app.register_blueprint(settings_bp)

    from adminapp.routes.categories import categories_bp
    app.register_blueprint(categories_bp)

    from adminapp.routes.builder import builder_bp
    app.register_blueprint(builder_bp)

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

    return app
