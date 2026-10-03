"""Application factory."""
import hmac
import os
import secrets
from flask import Flask, session, request, abort
from werkzeug.middleware.proxy_fix import ProxyFix
from .config import Config
from .extensions import db, login_manager


def _ensure_columns(app):
    """Idempotently add any columns missing from an existing SQLite DB."""
    from sqlalchemy import inspect, text
    wanted = {"vehicles": [("last_country", "VARCHAR(120)")],
              "users": [("consented_at", "DATETIME")]}
    try:
        with app.app_context():
            insp = inspect(db.engine)
            for table, cols in wanted.items():
                if not insp.has_table(table):
                    continue
                have = {c["name"] for c in insp.get_columns(table)}
                for name, ddl in cols:
                    if name not in have:
                        db.session.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}"))
                        db.session.commit()
                        app.logger.info("Added column %s.%s", table, name)
    except Exception as exc:  # noqa: BLE001
        app.logger.warning("_ensure_columns skipped: %s", exc)


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)
    # Trust the reverse proxy (Cloudflare/nginx) for scheme/host so HTTPS,
    # secure cookies and external URLs are correct behind the proxy.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    os.makedirs(os.path.join(app.root_path, "..", "instance"), exist_ok=True)
    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    db.init_app(app)
    login_manager.init_app(app)

    with app.app_context():
        from . import models  # noqa: F401  (register models)
        try:
            db.create_all()  # idempotent: creates new tables (e.g. password_resets)
        except Exception as exc:  # noqa: BLE001
            app.logger.warning("create_all on startup skipped: %s", exc)
    _ensure_columns(app)

    from .models import User, Notification

    @login_manager.user_loader
    def load_user(uid):
        return db.session.get(User, int(uid))

    # Blueprints
    from .views.main import bp as main_bp
    from .views.auth import bp as auth_bp
    from .views.vehicles import bp as vehicles_bp
    from .views.messaging import bp as messaging_bp
    from .views.forum import bp as forum_bp
    from .views.sightings import bp as sightings_bp
    from .views.admin import bp as admin_bp

    app.register_blueprint(main_bp)
    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(vehicles_bp, url_prefix="/vehicles")
    app.register_blueprint(messaging_bp, url_prefix="/messages")
    app.register_blueprint(forum_bp, url_prefix="/forum")
    app.register_blueprint(sightings_bp, url_prefix="/sightings")
    app.register_blueprint(admin_bp, url_prefix="/admin")

    @app.context_processor
    def inject_globals():
        from flask_login import current_user
        unread_n = unread_msgs = 0
        if current_user.is_authenticated:
            unread_n = Notification.query.filter_by(
                user_id=current_user.id, is_read=False).count()
            from .models import Conversation, Message
            convo_ids = [c.id for c in Conversation.query.filter(
                (Conversation.user_a_id == current_user.id) |
                (Conversation.user_b_id == current_user.id)).all()]
            if convo_ids:
                unread_msgs = Message.query.filter(
                    Message.conversation_id.in_(convo_ids),
                    Message.sender_id != current_user.id,
                    Message.is_read.is_(False)).count()
        return dict(unread_notifications=unread_n, unread_messages=unread_msgs,
                    google_maps_api_key=app.config.get("GOOGLE_MAPS_API_KEY", ""),
                    mot_enabled=bool(app.config.get("MOT_CLIENT_ID")
                                     and app.config.get("MOT_API_KEY")),
                    geonames_enabled=bool(app.config.get("GEONAMES_USERNAME")))

    @app.template_filter("ago")
    def ago(dt):
        if not dt:
            return ""
        from datetime import datetime
        s = (datetime.utcnow() - dt).total_seconds()
        if s < 60:
            return "just now"
        if s < 3600:
            return f"{int(s//60)}m ago"
        if s < 86400:
            return f"{int(s//3600)}h ago"
        if s < 604800:
            return f"{int(s//86400)}d ago"
        return dt.strftime("%Y-%m-%d")

    @app.cli.command("init-db")
    def init_db():
        from .seed import seed
        seed(app)

    # ---- CSRF protection (dependency-free, per-session token) ----
    def _csrf_token():
        tok = session.get("_csrf")
        if not tok:
            tok = secrets.token_urlsafe(32)
            session["_csrf"] = tok
        return tok

    @app.context_processor
    def _inject_csrf():
        return dict(csrf_token=_csrf_token())

    @app.before_request
    def _csrf_protect():
        if request.method in ("POST", "PUT", "PATCH", "DELETE"):
            sent = request.form.get("csrf_token") or request.headers.get("X-CSRFToken", "")
            good = session.get("_csrf", "")
            if not good or not sent or not hmac.compare_digest(str(sent), str(good)):
                abort(400, description="Invalid or missing CSRF token.")

    # ---- Security headers ----
    @app.after_request
    def _security_headers(resp):
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["X-Frame-Options"] = "DENY"
        resp.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        resp.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=(), payment=()"
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.tailwindcss.com https://unpkg.com; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; "
            "font-src 'self' https://fonts.gstatic.com; "
            "img-src 'self' data: https://*.tile.openstreetmap.org; "
            "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; "
            "object-src 'none'; form-action 'self'"
        )
        if request.is_secure:
            resp.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
            # Tell browsers to upgrade any stray http link/form/subresource to https
            resp.headers["Content-Security-Policy"] += "; upgrade-insecure-requests"
        resp.headers["Server"] = "MotoGuard"
        return resp

    return app
