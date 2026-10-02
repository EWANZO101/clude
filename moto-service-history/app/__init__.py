import os
from flask import Flask
from dotenv import load_dotenv
from werkzeug.middleware.proxy_fix import ProxyFix

from app.config import Config
from app.extensions import db, login_manager, csrf, migrate, limiter

load_dotenv()


def create_app(config_class=Config):
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config_class)
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)
    os.makedirs(app.instance_path, exist_ok=True)

    db.init_app(app)
    login_manager.init_app(app)
    csrf.init_app(app)
    migrate.init_app(app, db)
    limiter.init_app(app)

    from app.models import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, user_id)

    from app.auth.routes import auth_bp
    from app.motorcycles.routes import moto_bp
    from app.admin.routes import admin_bp
    from app.public.routes import public_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(moto_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(public_bp)

    from app.main import main_bp
    app.register_blueprint(main_bp)

    @app.template_filter("money")
    def money_filter(value):
        if value is None:
            return "—"
        return f"£{value:,.2f}"

    @app.template_filter("commas")
    def commas_filter(value):
        if value is None:
            return "—"
        try:
            return f"{int(value):,}"
        except (ValueError, TypeError):
            return value

    @app.context_processor
    def inject_globals():
        from flask import request
        from app.models import AppSetting
        return {
            "request_path": request.path,
            "site_name": AppSetting.get("site_name", "Moto Service History"),
        }

    @app.after_request
    def set_security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src 'self' https://fonts.gstatic.com; "
            "img-src 'self' data: blob:; "
            "connect-src 'self'"
        )
        if not app.debug:
            response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        return response

    from flask import render_template

    @app.errorhandler(403)
    def forbidden(e):
        return render_template("errors/403.html"), 403

    @app.errorhandler(404)
    def not_found(e):
        return render_template("errors/404.html"), 404

    @app.errorhandler(413)
    def too_large(e):
        return render_template("errors/413.html"), 413

    @app.errorhandler(429)
    def rate_limited(e):
        return render_template("errors/429.html"), 429

    @app.errorhandler(500)
    def server_error(e):
        db.session.rollback()
        return render_template("errors/500.html"), 500

    with app.app_context():
        db.create_all()
        _ensure_default_admin()

    return app


def _ensure_default_admin():
    """Create a default admin on first boot if no admin exists yet."""
    from app.models import User
    if User.query.filter_by(is_admin=True).first() is None:
        if User.query.filter_by(username="admin").first() is None:
            admin = User(username="admin", is_admin=True)
            admin.set_password(os.environ.get("DEFAULT_ADMIN_PASSWORD", "changeme123"))
            db.session.add(admin)
            db.session.commit()
