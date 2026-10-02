import os
import sqlite3
import time

from flask import Flask, g, request

from config import Config
from database import db
from extensions import login_manager, socketio, csrf


def _ensure_sqlite_ready(app):
    """SQLite needs its parent directory to exist AND be writable before the
    first connection. This resolves whatever SQLALCHEMY_DATABASE_URI actually
    is (not just the default path) and creates/checks that real directory,
    so a custom DATABASE_URL or an odd path doesn't silently fail later with
    a cryptic 'unable to open database file' from deep inside SQLAlchemy."""
    uri = app.config.get("SQLALCHEMY_DATABASE_URI", "")
    if not uri.startswith("sqlite:///"):
        return None  # non-sqlite backend (e.g. Postgres) - nothing to prepare here

    raw_path = uri[len("sqlite:///"):]
    if not raw_path or raw_path == ":memory:":
        return None

    db_path = raw_path if os.path.isabs(raw_path) else os.path.abspath(raw_path)
    db_dir = os.path.dirname(db_path)

    if db_dir:
        try:
            os.makedirs(db_dir, exist_ok=True)
        except OSError as exc:
            raise RuntimeError(
                f"Can't create the database directory at {db_dir}: {exc}. "
                f"Check that the user running this process owns/can write to that path."
            ) from exc

    # Prove we can actually open a connection here, with a clear message if not,
    # instead of letting the first real request fail deep inside SQLAlchemy.
    try:
        test_conn = sqlite3.connect(db_path)
        test_conn.close()
    except sqlite3.OperationalError as exc:
        raise RuntimeError(
            f"Can't open the SQLite database at {db_path}: {exc}. "
            f"Common causes: the directory ({db_dir}) doesn't exist or isn't writable "
            f"by the user running this process, or the disk is full/read-only."
        ) from exc

    return db_path


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    resolved_db_path = _ensure_sqlite_ready(app)
    os.makedirs(config_class.LOG_DIR, exist_ok=True)

    # Re-assert SSH lockdown before anything else runs. No-op if no
    # whitelist IPs are configured yet — that's intentional, there's no
    # "open to everyone" fallback, so SSH stays whatever it already was
    # until an admin whitelists at least one IP via the panel.
    try:
        from services import firewall_service as fw
        if fw.is_installed():
            if config_class.SSH_WHITELIST_IPS:
                fw.sync_ssh_whitelist(config_class.SSH_WHITELIST_IPS)
            else:
                app.logger.warning(
                    "No SSH_WHITELIST_IPS configured — SSH access control is "
                    "not active. Add an IP in Firewall > SSH Whitelist."
                )
    except Exception as exc:  # noqa: BLE001 - never let firewall sync block boot
        app.logger.warning("SSH whitelist sync at startup failed: %s", exc)

    db.init_app(app)
    csrf.init_app(app)

    login_manager.init_app(app)
    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please log in to access the panel."
    login_manager.login_message_category = "info"

    # async_mode="threading" keeps things simple under gunicorn without
    # requiring eventlet/gevent worker classes at first deploy.
    socketio.init_app(app, async_mode="threading", cors_allowed_origins="*")

    from models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    from modules.auth.routes import auth_bp
    from modules.dashboard.routes import dashboard_bp, start_stats_emitter
    from modules.systemctl.routes import systemctl_bp
    from modules.nginx.routes import nginx_bp
    from modules.firewall.routes import firewall_bp
    from modules.networking.routes import networking_bp
    from modules.installers.routes import installers_bp
    from modules.users.routes import users_bp
    from modules.logs.routes import logs_bp
    from modules.security.routes import security_bp, start_sessions_emitter
    from modules.dns.routes import dns_bp
    from modules.settings.routes import settings_bp
    from modules.envfiles.routes import envfiles_bp
    from modules.ssl.routes import ssl_bp
    from modules.backups.routes import backups_bp
    from modules.files.routes import files_bp
    from modules.system.routes import system_bp
    from modules.console.routes import console_bp
    from modules.gameservers.routes import gameservers_bp
    from modules.databases.routes import databases_bp
    from modules.txadmin.routes import txadmin_bp
    from modules.txadmin.api import txapi_bp
#     from modules.vms.routes import vms_bp
   #  # from modules.customer.routes import customer_bp
   #  # from modules.agent_api.routes import agent_api_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(systemctl_bp)
    app.register_blueprint(nginx_bp)
    app.register_blueprint(firewall_bp)
    app.register_blueprint(networking_bp)
    app.register_blueprint(installers_bp)
    app.register_blueprint(users_bp)
    app.register_blueprint(logs_bp)
    app.register_blueprint(security_bp)
    app.register_blueprint(dns_bp)
    app.register_blueprint(settings_bp)
    app.register_blueprint(envfiles_bp)
    app.register_blueprint(ssl_bp)
    app.register_blueprint(backups_bp)
    app.register_blueprint(files_bp)
    app.register_blueprint(system_bp)
    app.register_blueprint(console_bp)
    app.register_blueprint(gameservers_bp)
    app.register_blueprint(databases_bp)
    app.register_blueprint(txadmin_bp)
    app.register_blueprint(txapi_bp)
#     app.register_blueprint(vms_bp)
   #  # app.register_blueprint(customer_bp)
   #  # app.register_blueprint(agent_api_bp)
    # Machine client, never carries a CSRF token - browser-facing blueprints
    # above all keep CSRF protection via csrf.init_app(app) globally.
    # csrf.exempt(agent_api_bp)

    with app.app_context():
        db.create_all()
        from models.role import Role as _Role
        # Idempotent: creates nothing for already-set-up panels, but merges
        # newly-introduced permissions (e.g. security.manage) into existing
        # roles on every boot, since seed_defaults() otherwise only runs
        # once from the first-run setup wizard.
        _Role._merge_new_default_permissions()
        from models.user import User as _User
        user_count = _User.query.count()
        app.logger.info(
            "Database: %s (%d existing user%s)",
            resolved_db_path or app.config["SQLALCHEMY_DATABASE_URI"], user_count,
            "" if user_count == 1 else "s",
        )
        if user_count == 0:
            app.logger.warning(
                "No users found — the setup wizard will run. If you expected an existing "
                "admin account, double check this is the same database file as last time."
            )

    start_stats_emitter(app)
    start_sessions_emitter(app)

    from modules.console.routes import start_idle_sweeper
    start_idle_sweeper(app)

    from modules.txadmin.routes import resume_claude_links
    resume_claude_links(app)

    from services import tx_errors
    tx_errors.start_all(app)

    from services import ddos_service
    ddos_service.start_detection_loop(app, socketio)

    @app.before_request
    def _start_timer():
        g._request_start = time.perf_counter()

    @app.after_request
    def _log_timing(response):
        start = getattr(g, "_request_start", None)
        if start is not None:
            elapsed_ms = (time.perf_counter() - start) * 1000
            response.headers["X-Response-Time-ms"] = f"{elapsed_ms:.1f}"
            if elapsed_ms > 200:  # only log the ones actually worth looking at
                app.logger.warning(
                    "SLOW %s %s -> %.1fms", request.method, request.path, elapsed_ms
                )
        return response

    @app.context_processor
    def inject_globals():
        return {"panel_name": app.config["PANEL_NAME"]}

    return app


app = create_app()

if __name__ == "__main__":
    socketio.run(app, host="0.0.0.0", port=app.config["PANEL_PORT"], debug=False, allow_unsafe_werkzeug=True)
