import os

from flask import Flask

from app.config import DevConfig, ProdConfig
from app.extensions import db, login_manager, csrf, migrate, limiter


def create_app(config_name=None):
    app = Flask(__name__, instance_relative_config=True)

    config_name = config_name or os.environ.get("FLASK_ENV", "development")
    app.config.from_object(ProdConfig if config_name == "production" else DevConfig)

    os.makedirs(app.instance_path, exist_ok=True)
    os.makedirs(app.config["EXPORTS_DIR"], exist_ok=True)
    os.makedirs(app.config["UPLOADS_DIR"], exist_ok=True)

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
    from app.main.routes import main_bp
    from app.exports.routes import exports_bp
    from app.imports.routes import imports_bp
    from app.admin.routes import admin_bp
    from app.agent.routes import agent_bp
    from app.shares.routes import shares_bp
    from app.support.routes import support_bp
    from app.admin.decorators import enforce_force_logout

    app.register_blueprint(auth_bp)
    app.register_blueprint(main_bp)
    app.register_blueprint(exports_bp)
    app.register_blueprint(imports_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(agent_bp)
    app.register_blueprint(shares_bp)
    app.register_blueprint(support_bp)

    app.before_request(enforce_force_logout)

    @app.before_request
    def _make_session_permanent():
        from flask import session
        session.permanent = True

    @app.after_request
    def _security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com https://cdnjs.cloudflare.com; "
            "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; "
            "img-src 'self' data:; "
            "font-src 'self' https://cdnjs.cloudflare.com; "
            "frame-ancestors 'none'"
        )
        if config_name == "production":
            response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        return response

    @app.context_processor
    def inject_globals():
        return {"app_name": "SnailyCAD Migration Platform"}

    @app.cli.command("create-admin")
    def create_admin():
        """Promote or create a user as admin: flask create-admin"""
        import getpass
        from app.models import User, Role

        email = input("Admin email: ").strip().lower()
        user = User.query.filter_by(email=email).first()

        if user:
            user.role = Role.ADMIN
            user.is_suspended = False
            db.session.commit()
            print(f"Existing user {email} promoted to admin.")
            return

        password = getpass.getpass("Password (min 10 chars): ")
        confirm = getpass.getpass("Confirm password: ")
        if password != confirm:
            print("Passwords don't match.")
            return
        if len(password) < 10:
            print("Password must be at least 10 characters.")
            return

        user = User(email=email, role=Role.ADMIN, email_verified=True)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        print(f"Admin user {email} created.")

    @app.cli.command("cleanup")
    def cleanup():
        """
        Removes expired temporary accounts (and their exports) and marks
        completed exports past the retention window as expired.
        Intended to run on a schedule: cron/systemd timer, e.g. hourly.
        """
        import os as _os
        from datetime import datetime, timedelta
        from app.models import User, Export, ExportStatus, Setting

        if Setting.get("cleanup_enabled", "true") != "true":
            print("Cleanup is disabled in admin settings — nothing to do.")
            return

        # --- expired temporary accounts ---
        expired_users = [u for u in User.query.filter_by(is_temporary=True).all() if u.is_expired]
        removed_users = 0
        for user in expired_users:
            for export in user.exports.all():
                if export.file_path and _os.path.exists(export.file_path):
                    _os.remove(export.file_path)
                sidecar = f"{export.file_path}.sha256" if export.file_path else None
                if sidecar and _os.path.exists(sidecar):
                    _os.remove(sidecar)
            db.session.delete(user)
            removed_users += 1
        db.session.commit()
        print(f"Removed {removed_users} expired temporary account(s).")

        # --- retention-expired exports (respecting any approved per-export extension) ---
        standard_days = int(Setting.get("export_retention_days", "7"))
        candidates = Export.query.filter(Export.status == ExportStatus.COMPLETE).all()

        removed_exports = 0
        now = datetime.utcnow()
        for export in candidates:
            effective_days = export.effective_retention_days(standard_days)
            if now - export.created_at < timedelta(days=effective_days):
                continue
            if export.file_path and _os.path.exists(export.file_path):
                _os.remove(export.file_path)
            sidecar = f"{export.file_path}.sha256" if export.file_path else None
            if sidecar and _os.path.exists(sidecar):
                _os.remove(sidecar)
            export.status = ExportStatus.EXPIRED
            removed_exports += 1
        db.session.commit()
        print(f"Expired {removed_exports} export(s) past their retention window "
              f"(standard {standard_days} days, longer where an extension was approved).")

    @app.cli.command("check-deps")
    def check_deps():
        """Verifies required packages are actually importable in this venv."""
        import importlib

        # (import name, pip package name, why it matters)
        checks = [
            ("flask", "Flask", "core app"),
            ("flask_sqlalchemy", "Flask-SQLAlchemy", "database"),
            ("flask_login", "Flask-Login", "auth"),
            ("flask_wtf", "Flask-WTF", "forms/CSRF"),
            ("flask_migrate", "Flask-Migrate", "db migrations"),
            ("flask_limiter", "Flask-Limiter", "rate limiting"),
            ("pyotp", "pyotp", "2FA"),
            ("itsdangerous", "itsdangerous", "signed tokens"),
            ("paramiko", "paramiko", "SSH remote export/import"),
            ("dotenv", "python-dotenv", ".env loading outside the Flask CLI"),
        ]

        missing = []
        for import_name, pip_name, purpose in checks:
            try:
                importlib.import_module(import_name)
            except ImportError:
                missing.append((pip_name, purpose))

        if not missing:
            print(f"All {len(checks)} required packages are installed.")
            return

        print(f"Missing {len(missing)} required package(s):")
        for pip_name, purpose in missing:
            print(f"  - {pip_name}  (needed for: {purpose})")
        print("\nFix: pip install -r requirements.txt   (inside the venv), then restart the app.")

    @app.cli.command("test-email")
    def test_email():
        """Sends a real test email using the current mail config: flask test-email"""
        from app.email import _mail_settings, mail_is_configured, send_email

        settings = _mail_settings()
        print("Current mail configuration:")
        print(f"  server:   {settings['server'] or '(not set)'}")
        print(f"  port:     {settings['port']}")
        print(f"  use_tls:  {settings['use_tls']}")
        print(f"  username: {settings['username'] or '(not set)'}")
        print(f"  sender:   {settings['sender'] or '(not set)'}")
        print()

        if not mail_is_configured():
            print("Mail is NOT configured — server or sender is missing. "
                  "Set MAIL_SERVER/MAIL_DEFAULT_SENDER in .env, or configure "
                  "them in /admin/settings, then try again.")
            return

        to = input("Send a test email to: ").strip()
        if not to:
            print("No address given, aborting.")
            return

        print(f"Sending to {to} from {settings['sender']} via {settings['server']}:{settings['port']}...")
        sent = send_email(
            to=to,
            subject="SnailyCAD Migration Platform — test email",
            body_text="This is a test email to confirm mail delivery is working correctly.",
        )
        if sent:
            print("Sent without error. Check the inbox (and spam folder) to confirm it actually arrived — "
                  "a successful SMTP transaction doesn't always guarantee delivery.")
        else:
            print("FAILED to send. Check the application logs (journalctl -u snailycad-migrate) "
                  "for the specific SMTP error.")

    return app