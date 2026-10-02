import os
from flask import Flask, jsonify

from app.models import db
from sqlalchemy import event
from sqlalchemy.engine import Engine

def _auto_migrate_columns(app: Flask) -> None:
    """Startup self-healing for the exact class of bug that's already
    bitten the stocktoolsetup side of this project for real: db.create_all()
    only creates tables that don't exist yet -- it never adds a column to
    an EXISTING table when a model gains a new field. This compares each
    model's declared columns against what SQLite actually has and ALTERs
    any missing ones in automatically, so a future model change to this
    local DB (LocalUser, Item, Tool, Project, Barcode) can't brick an
    already-installed kiosk just because nobody remembered to run a
    manual ALTER TABLE.

    Deliberately conservative: only adds a plain nullable column with no
    other constraints. Anything else (NOT NULL, renamed columns, etc.)
    gets logged loudly instead of guessed at."""
    from sqlalchemy import inspect, text

    inspector = inspect(db.engine)
    for table in db.metadata.sorted_tables:
        if table.name not in inspector.get_table_names():
            continue  # brand-new table -- db.create_all() already handles this
        existing_columns = {col["name"] for col in inspector.get_columns(table.name)}
        for column in table.columns:
            if column.name in existing_columns:
                continue
            if not column.nullable:
                app.logger.warning(
                    "Column %s.%s is missing from the database and is NOT NULL -- "
                    "cannot auto-migrate safely. A manual migration is needed.",
                    table.name, column.name,
                )
                continue
            col_type = column.type.compile(db.engine.dialect)
            with db.engine.begin() as conn:
                conn.execute(text(f'ALTER TABLE "{table.name}" ADD COLUMN "{column.name}" {col_type}'))
            app.logger.info("Auto-migrated: added missing column %s.%s", table.name, column.name)

def _local_data_dir() -> str:
    """
    Where the local SQLite DB and config (settings.json) live.

    The MSI install (see installer/) registers this as a per-machine
    Windows service that needs to see the same DB/settings regardless of
    which user is logged in — or whether anyone is — so this now prefers
    %ProgramData%\\StockToolKiosk over %LOCALAPPDATA%. ProgramData is
    writable by services running as LocalSystem/NetworkService without
    extra ACL changes, unlike a specific user's LOCALAPPDATA.

    Falls back to %LOCALAPPDATA%/~ when ProgramData isn't set (e.g. this
    dev sandbox, or the plain no-installer .exe workflow from Part 1-5).
    """
    base = os.environ.get("PROGRAMDATA") or os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    path = os.path.join(base, "StockToolKiosk")
    os.makedirs(path, exist_ok=True)
    return path

def _ensure_db_writable(db_path: str, data_dir: str) -> None:
    """
    Self-heals the single most common cause of "attempt to write a
    readonly database" on Windows: the DOS/NTFS Read-only file
    attribute getting set on kiosk_local.db (or its folder) -- this
    happens easily via a zip extraction, a restore from backup, some
    antivirus/EDR tools, or a OneDrive-synced ProgramData redirect.

    os.chmod on Windows doesn't touch real NTFS ACLs, but it DOES
    directly clear/set the FILE_ATTRIBUTE_READONLY flag (the same
    thing the "Read-only" checkbox in a file's Properties dialog
    controls) -- so this fixes exactly that class of problem
    automatically, every time the app starts, without anyone needing
    to know to go check a checkbox in Explorer.

    If clearing the attribute doesn't actually make the file/folder
    writable (a real NTFS permission denial, a locked/read-only
    volume, a full disk, etc.), this raises a clear, actionable error
    instead of leaving it to surface later as an opaque SQLAlchemy
    traceback the first time someone tries to save something.
    """
    import stat

    try:
        os.chmod(data_dir, stat.S_IWRITE | stat.S_IREAD)
    except OSError:
        pass  # best-effort -- the real check is the write probe below

    if os.path.exists(db_path):
        try:
            os.chmod(db_path, stat.S_IWRITE | stat.S_IREAD)
        except OSError:
            pass

    probe_path = os.path.join(data_dir, ".write_test")
    try:
        with open(probe_path, "w") as f:
            f.write("ok")
        os.remove(probe_path)
    except OSError as e:
        raise RuntimeError(
            f"StockTool Kiosk can't write to its data folder:\n  {data_dir}\n\n"
            f"Clearing the Windows Read-only attribute didn't fix it, which usually means "
            f"this is a real permissions or storage issue rather than just that checkbox. "
            f"Things to check on this machine:\n"
            f"  1. Right-click the StockToolKiosk folder -> Properties -> Security -> "
            f"confirm the account running this app has Modify/Full control.\n"
            f"  2. Confirm the drive isn't full and isn't itself mounted read-only.\n"
            f"  3. If this folder is inside a synced location (OneDrive, etc.) or is "
            f"being actively scanned by antivirus/EDR, exclude it and try again.\n\n"
            f"Underlying error: {e}"
        ) from e


def create_app(test_config: dict | None = None) -> Flask:
    app = Flask(__name__)

    try:
        from version import __version__ as VERSION, __release_date__ as RELEASE_DATE
    except Exception:
        VERSION = "unknown"
        RELEASE_DATE = None

    data_dir = _local_data_dir()
    db_path = os.path.join(data_dir, "kiosk_local.db")
    _ensure_db_writable(db_path, data_dir)

    app.config.update(
        SQLALCHEMY_DATABASE_URI=f"sqlite:///{db_path}",
        SQLALCHEMY_TRACK_MODIFICATIONS=False,
        SECRET_KEY=os.environ.get("KIOSK_SECRET_KEY", "kiosk-local-dev-key"),
        DATA_DIR=data_dir,
        CLOUD_API_BASE=os.environ.get("STOCKTOOL_CLOUD_API", "https://api-stocktool.opslabsystems.cloud"),
        KIOSK_VERSION=VERSION,
        KIOSK_RELEASE_DATE=RELEASE_DATE,
    )
    if test_config:
        app.config.update(test_config)

    db.init_app(app)

    @event.listens_for(Engine, "connect")
    def _set_sqlite_pragma(dbapi_connection, connection_record):
        """Without this, any two requests that touch the DB at the same
        moment (a bulk import mid-loop, the relay client's background
        poll, a sync cycle) can produce "database is locked" -- SQLite's
        default is to fail IMMEDIATELY on a lock instead of waiting.
        busy_timeout tells it to retry for up to 15s before giving up,
        which covers ordinary momentary contention (a single commit is
        on the order of milliseconds) without masking a genuinely stuck
        lock. Applies to every connection on this engine, so it covers
        cloud-run workers and the CLI paths too, not just the main app.
        """
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA busy_timeout = 15000")
        cursor.close()

    with app.app_context():
        db.create_all()
        _auto_migrate_columns(app)

    # ── Local-only REST API (Items / Tools / Projects / Barcode) ──────
    from app.routes_items import items_bp
    from app.routes_tools import tools_bp
    from app.routes_projects import projects_bp
    from app.routes_barcode import barcode_bp
    from app.routes_barcode_view import barcode_view_bp
    from app.routes_auth import auth_bp
    from app.routes_status import status_bp
    from app.routes_backup import backup_bp
    from app.routes_admin import admin_bp
    from app.routes_audit import audit_bp
    from app.routes_license import license_bp
    from app.routes_import_export import import_export_bp
    from app.routes_maintenance_alerts import maintenance_alerts_bp
    from app.routes_ppe import ppe_bp
    from app.routes_wire import wire_bp
    from app.routes_dashboard import dashboard_bp
    from app.routes_db_tools import db_tools_bp
    app.register_blueprint(items_bp)
    app.register_blueprint(tools_bp)
    app.register_blueprint(projects_bp)
    app.register_blueprint(barcode_bp)
    app.register_blueprint(barcode_view_bp)
    app.register_blueprint(auth_bp)
    app.register_blueprint(status_bp)
    app.register_blueprint(backup_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(audit_bp)
    app.register_blueprint(license_bp)

    import license as stocktool_license
    stocktool_license.init_license(app)
    app.register_blueprint(import_export_bp)
    app.register_blueprint(maintenance_alerts_bp)
    app.register_blueprint(ppe_bp)
    app.register_blueprint(wire_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(db_tools_bp)
    @app.route("/")
    def root():
        return jsonify({
            "service": "StockTool Kiosk (local)",
            "version": app.config.get("KIOSK_VERSION", "unknown"),
            "ui": "/ui/",
        }), 200

    from app.ui import ui_bp
    app.register_blueprint(ui_bp)


    if not test_config:
        from app.audit_scheduler import start_scheduler
        start_scheduler(app)
    return app
