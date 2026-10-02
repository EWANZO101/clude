"""
Entrypoint shipped inside the update package (release/build_release.py
always includes this file at the package root) — this is exactly what a
freshly auto-configured kiosk_start_command runs (see the Instance Agent's
agent/update_manager.py::_auto_default_kiosk_command): the agent's own
bundled Python interpreter running this file, with this file's own
directory as the working directory.

Self-bootstraps on first run so a zero-touch install.ps1 enrollment ends
with an actually-usable kiosk, not an empty database with no way to log
in: creates the schema if it doesn't exist yet (no migrations/ folder ships
in the release package — see build_release.py's EXCLUDE_DIR_NAMES — so
`flask db upgrade` isn't an option here), and seeds a single "admin"
LocalUser with no password if the user table is empty (badge/username-only
login is the original StockTool Kiosk's documented, loopback-only-safe
default — see LocalUser.check_password). Both checks are safe to run on
every single startup: they're no-ops once the schema/user already exist,
which is the normal case after the very first boot.

Also self-installs any of its own missing dependencies (see
_ensure_dependencies_installed below) before ever importing app/ — real
incident (2026-09-08): a release added a new import (barcode_render.py's
`import barcode`) and the machine's bundled Python simply didn't have it,
since nothing in the update pipeline (Agent update_manager.py just swaps
files — see OWNERSHIP.md) ever ran `pip install` again after the initial
install.ps1. Fixing this here rather than in the Agent means it ships
through the exact same Build Release -> Push Update path as any other
code change — no Agent update, no manual step on the machine, nothing
outside the Admin Panel at all.

Serves via waitress (already in requirements.txt) rather than Flask's own
dev server by default — the dev server's debug=True reloader forks a
second process that a ProcessSupervisor watching the top-level PID can't
see, and its interactive debugger is a real risk on any machine with more
than one local account. Set OPSLAB_KIOSK_DEV=1 to get the old dev-server
behavior back for local development on a workstation, not on a deployed
kiosk.
"""
import os
import re
import sys


def _ensure_dependencies_installed():
    """Checks every line of this package's own requirements.txt against
    what's actually importable in the current interpreter (the Agent's
    bundled python.exe — see module docstring) and `pip install`s
    anything missing, before app/ is ever imported. A normal restart with
    nothing missing costs one importlib.metadata lookup per requirement
    (fast, no subprocess) — pip only actually runs when something's
    genuinely absent, which should be rare (once per machine, right after
    a release adds a new dependency)."""
    import importlib.metadata

    req_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements.txt")
    if not os.path.isfile(req_path):
        return

    missing = []
    with open(req_path, "r", encoding="utf-8") as f:
        for line in f:
            requirement = line.split("#", 1)[0].strip()
            if not requirement:
                continue
            # Distribution name is everything before the first version/
            # extras/environment-marker token — good enough for the plain
            # "Name==x.y.z" lines this file actually has, without needing
            # a full PEP 508 parser just to check presence.
            dist_name = re.split(r"[<>=!~;\[]", requirement, 1)[0].strip()
            if not dist_name:
                continue
            try:
                importlib.metadata.version(dist_name)
            except importlib.metadata.PackageNotFoundError:
                missing.append(requirement)

    if not missing:
        return

    print(f"[bootstrap] installing missing dependencies: {missing}", flush=True)
    import subprocess
    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", *missing],
            check=True, timeout=300,
        )
        print("[bootstrap] dependency install complete", flush=True)
    except Exception as e:
        # Never crash the whole kiosk over a failed self-heal attempt (e.g.
        # no network right now) — the ORIGINAL ImportError a few lines down
        # is still a clearer signal than one raised from here, and a
        # transient failure now doesn't prevent trying again next start.
        print(f"[bootstrap] WARNING: dependency install failed, continuing anyway: {e}", flush=True)


_ensure_dependencies_installed()

from app import create_app
from app.extensions import db

app = create_app()

# Overridable so a future port collision (like the one that motivated this
# comment - this machine's separate StockTool Kiosk product already owns
# 8420) is a one-line environment variable fix via a "configure" push,
# not a new release build.
PORT = int(os.environ.get("OPSLAB_KIOSK_PORT", "8421"))


# Columns added to an existing table after a kiosk was first installed —
# db.create_all() below only ever creates a table that doesn't exist yet,
# never adds a column to one that already does, so an already-running
# kiosk's sqlite file needs this same "poor man's migration" every startup
# that a brand-new one gets for free from create_all(). Added for the
# Admin Panel <-> Kiosk App inventory sync (see app/blueprints/sync_api.py)
# — safe to run unconditionally, same as create_all() itself: a no-op once
# the column already exists.
_ADDED_COLUMNS = {
    "items": [("public_id", "VARCHAR(36)"), ("updated_at", "DATETIME"), ("deleted_at", "DATETIME"),
              ("location", "VARCHAR(128)"), ("supplier", "VARCHAR(255)")],
    "tools": [("public_id", "VARCHAR(36)"), ("updated_at", "DATETIME"), ("deleted_at", "DATETIME"),
              ("category", "VARCHAR(64)")],
    "local_users": [("public_id", "VARCHAR(36)"), ("updated_at", "DATETIME"), ("last_login_at", "DATETIME")],
    "activity_events": [("local_user_id", "INTEGER")],
    "wire_spools": [("current_weight_lbs", "FLOAT")],
    "wire_issuance_events": [("starting_weight_lbs", "FLOAT"), ("finishing_weight_lbs", "FLOAT"),
                             ("consumed_lbs", "FLOAT")],
}


def _ensure_sync_columns():
    import uuid
    from sqlalchemy import inspect, text

    inspector = inspect(db.engine)
    existing_tables = set(inspector.get_table_names())
    for table, columns in _ADDED_COLUMNS.items():
        if table not in existing_tables:
            continue  # brand-new install — create_all() below adds it with every column already
        existing_columns = {c["name"] for c in inspector.get_columns(table)}
        for name, sql_type in columns:
            if name in existing_columns:
                continue
            db.session.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}"))
    db.session.commit()

    # public_id has no server-side default (SQLite ALTER TABLE can't add a
    # column with a non-constant default) — backfill any row that just
    # gained a null one so it has a real, usable sync identity immediately
    # rather than on its next unrelated save.
    from app.models import Item, Tool, LocalUser
    for model in (Item, Tool, LocalUser):
        for row in model.query.filter(model.public_id.is_(None)).all():
            row.public_id = str(uuid.uuid4())
    db.session.commit()


def _ensure_inventory_type_system_seeded():
    """Track 2 (see /root/.claude/plans/sprightly-meandering-whisper.md):
    seed the 3 built-in ItemTypes and one NavEntry per hardcoded
    SIDEBAR_ITEMS entry. Idempotent per-key, not just "table is empty" —
    a new SIDEBAR_ITEMS entry added later (e.g. inventory_manage, added
    alongside Phase C's UI) still needs to reach an already-provisioned
    kiosk's NavEntry table on its next startup, not just a brand-new
    install's db.create_all()."""
    from app.models import ItemType, NavEntry, SIDEBAR_ITEMS

    existing_type_keys = {t.key for t in ItemType.query.all()}
    for key, name in (("item", "Item"), ("tool", "Tool"), ("welding_wire", "Welding Wire")):
        if key not in existing_type_keys:
            db.session.add(ItemType(key=key, name=name, is_builtin=True))

    existing_nav_keys = {n.key for n in NavEntry.query.all()}
    next_order = (db.session.query(db.func.max(NavEntry.sort_order)).scalar() or -1) + 1
    for key, label, section in SIDEBAR_ITEMS:
        if key in existing_nav_keys:
            continue
        db.session.add(NavEntry(key=key, label=label, section=section, is_builtin=True, sort_order=next_order))
        next_order += 1

    db.session.commit()


def _ensure_bootstrapped():
    from app.models import LocalUser

    with app.app_context():
        db.create_all()
        _ensure_sync_columns()
        _ensure_inventory_type_system_seeded()
        if LocalUser.query.count() == 0:
            admin = LocalUser(username="admin", role="admin")
            db.session.add(admin)
            db.session.commit()


_ensure_bootstrapped()


def _run_backup_scheduler_loop(check_interval_seconds: int = 300):
    """Background thread, started once below — checks every 5 minutes
    whether today's scheduled LOCAL backup (see app/backup.py) is due,
    using whatever the Agent most recently applied to kiosk_config.json.
    Deliberately re-reads that file fresh on every check (load_agent_config
    is a plain file read, not cached) rather than the Config class's own
    AGENT_CONFIG attribute, which is frozen at process start the same way
    AUTO_LOGOUT_MINUTES is — a schedule changed from the Client Portal
    should take effect within 5 minutes, not require a kiosk restart."""
    import time
    from app.config import load_agent_config
    from app.backup import run_scheduled_local_backup_if_due

    while True:
        try:
            with app.app_context():
                if run_scheduled_local_backup_if_due(load_agent_config()):
                    print("[backup] scheduled local backup created", flush=True)
        except Exception as e:
            print(f"[backup] scheduled local backup check failed: {e}", flush=True)
        time.sleep(check_interval_seconds)


def _start_backup_scheduler_thread():
    import threading
    thread = threading.Thread(target=_run_backup_scheduler_loop, daemon=True, name="backup-scheduler")
    thread.start()


_start_backup_scheduler_thread()


def _run_retention_purge_loop(check_interval_seconds: int = 86400):
    """Background thread, started once below — once a day, purges closed
    personal-data history rows past whatever `activity_log_retention_days`
    the Agent most recently applied (see app/retention.py). A no-op
    (checks and returns) on every kiosk that hasn't set that config key,
    which is the default/normal case."""
    import time
    from app.config import load_agent_config
    from app.retention import run_scheduled_purge_if_due

    while True:
        try:
            with app.app_context():
                result = run_scheduled_purge_if_due(load_agent_config())
                if result is not None:
                    print(f"[retention] scheduled purge: {result}", flush=True)
        except Exception as e:
            print(f"[retention] scheduled purge check failed: {e}", flush=True)
        time.sleep(check_interval_seconds)


def _start_retention_purge_thread():
    import threading
    thread = threading.Thread(target=_run_retention_purge_loop, daemon=True, name="retention-purge")
    thread.start()


_start_retention_purge_thread()


def _start_client_portal_listener():
    """Local Client Portal (see app/blueprints/client.py) — an OPTIONAL
    second listener, bound to ALL interfaces (unlike PORT above, which
    stays 127.0.0.1-only), so it's reachable at this machine's LAN IP —
    e.g. http://192.168.1.50:<CLIENT_PORTAL_PORT>/client/login. Same
    Flask `app` object as the main kiosk port (same DB, same session/auth
    machinery) — this just adds where else it's reachable from, not a
    second application. No-op (nothing extra listens) unless
    OPSLAB_CLIENT_PORTAL_PORT is actually set. Started unconditionally at
    module level, same as the backup-scheduler thread above, so it comes
    up the same way whether this process is run via `OPSLAB_KIOSK_DEV=1`
    (Flask's dev server) or the normal waitress path below."""
    port = app.config.get("CLIENT_PORTAL_PORT")
    if not port:
        return
    import threading
    from waitress import serve as waitress_serve

    def _serve():
        waitress_serve(app, host="0.0.0.0", port=port)

    threading.Thread(target=_serve, daemon=True, name="client-portal-listener").start()
    print(f"[client-portal] listening on 0.0.0.0:{port} (/client/login)", flush=True)


_start_client_portal_listener()

if __name__ == "__main__":
    if os.environ.get("OPSLAB_KIOSK_DEV") == "1":
        app.run(debug=True, host="127.0.0.1", port=PORT)
    else:
        from waitress import serve
        serve(app, host="127.0.0.1", port=PORT)
