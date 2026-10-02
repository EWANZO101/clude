"""
migrate.py — brings an EXISTING database up to date with the current
models. Safe to run any time, including repeatedly (every step checks
before it acts).

Usage:
    python scripts/migrate.py
"""
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import text, inspect
from app import create_app
from app.models import db


def _make_users_password_email_nullable():
    """
    SQLite can't drop a NOT NULL constraint with plain ALTER TABLE — it
    needs the classic recreate-copy-swap dance. Needed so a user row can
    have password_hash/email = NULL for badge-only accounts.
    """
    cols = {c["name"]: c for c in inspect(db.engine).get_columns("users")}
    if cols["password_hash"]["nullable"] and cols["email"]["nullable"]:
        print("users.password_hash / users.email already nullable — skipping.")
        return

    print("Rebuilding 'users' table so password_hash/email can be NULL "
          "(badge-only accounts)...")
    with db.engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE users_new (
                id INTEGER PRIMARY KEY,
                username VARCHAR(64) NOT NULL,
                email VARCHAR(120),
                password_hash VARCHAR(256),
                role VARCHAR(32) NOT NULL DEFAULT 'stock_user',
                is_active BOOLEAN NOT NULL DEFAULT 1,
                force_password_change BOOLEAN NOT NULL DEFAULT 0,
                created_at DATETIME,
                last_login DATETIME
            )
        """))
        conn.execute(text("""
            INSERT INTO users_new (id, username, email, password_hash, role,
                                    is_active, force_password_change, created_at, last_login)
            SELECT id, username, email, password_hash, role,
                   is_active, force_password_change, created_at, last_login
            FROM users
        """))
        conn.execute(text("DROP TABLE users"))
        conn.execute(text("ALTER TABLE users_new RENAME TO users"))
        conn.execute(text("CREATE UNIQUE INDEX IF NOT EXISTS ix_users_username ON users (username)"))
        conn.execute(text("CREATE UNIQUE INDEX IF NOT EXISTS ix_users_email ON users (email)"))
    print("'users' table rebuilt.")


def _add_item_measurement_columns():
    cols = {c["name"] for c in inspect(db.engine).get_columns("items")}
    with db.engine.begin() as conn:
        if "measurement_type" not in cols:
            print("Adding items.measurement_type ...")
            conn.execute(text(
                "ALTER TABLE items ADD COLUMN measurement_type VARCHAR(16) NOT NULL DEFAULT 'count'"
            ))
        if "stock_amount" not in cols:
            print("Adding items.stock_amount ...")
            conn.execute(text("ALTER TABLE items ADD COLUMN stock_amount FLOAT"))


def _create_new_tables():
    """Category and its association tables are brand new models --
    db.create_all() only creates tables that don't exist yet, so this
    is safe to call every run and never touches existing tables."""
    print("Ensuring categories / association tables exist ...")
    db.create_all()


def _migrate_wire_tables():
    """The welding-wire tables were reworked from a single-step
    'transaction log' (coil_reference/wire_type/wire_size columns, no
    status) to a real checkout/checkin model with a status column and
    an admin-manageable WireCode table. That earlier version was never
    reachable from any UI (no kiosk tab, no admin screen existed for
    it) so there's no real usage data to preserve -- if the OLD schema
    is detected, the two tables are dropped and recreated on the new
    schema rather than attempting a lossy column-rename migration.
    wire_codes is seeded with the two codes named in the spec."""
    from app.models import WireCode
    table_names = inspect(db.engine).get_table_names()

    if "wire_coils" in table_names:
        cols = {c["name"] for c in inspect(db.engine).get_columns("wire_coils")}
        if "coil_reference" in cols:  # old schema marker
            print("Old welding-wire schema detected (pre-checkout/checkin) -- "
                  "recreating wire_coils/wire_transactions on the new schema...")
            with db.engine.begin() as conn:
                conn.execute(text("DROP TABLE IF EXISTS wire_transactions"))
                conn.execute(text("DROP TABLE IF EXISTS wire_coils"))

    print("Ensuring wire_codes / wire_coils / wire_transactions exist ...")
    db.create_all()

    if not WireCode.query.first():
        print("Seeding default wire codes (1.2 Code Wire, 1.6 Code Wire) ...")
        db.session.add(WireCode(name="1.2 Code Wire"))
        db.session.add(WireCode(name="1.6 Code Wire"))
        db.session.commit()


def _add_wire_coil_empty_at_column():
    if "wire_coils" not in inspect(db.engine).get_table_names():
        return
    cols = {c["name"] for c in inspect(db.engine).get_columns("wire_coils")}
    if "empty_at" in cols:
        return
    print("Adding wire_coils.empty_at ...")
    with db.engine.begin() as conn:
        conn.execute(text("ALTER TABLE wire_coils ADD COLUMN empty_at DATETIME"))
    # Backfill: any coil that's already sitting at status='empty' from
    # before this column existed gets empty_at = now, so it still gets
    # a full 30 days before auto-delete rather than vanishing immediately.
    from app.models import WireCoil, db as _db
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    stale = WireCoil.query.filter_by(status=WireCoil.STATUS_EMPTY, empty_at=None).all()
    if stale:
        print(f"Backfilling empty_at for {len(stale)} existing empty coil(s) ...")
        for coil in stale:
            coil.empty_at = now
        _db.session.commit()


def _add_settings_columns():
    if "settings" not in inspect(db.engine).get_table_names():
        return
    cols = {c["name"] for c in inspect(db.engine).get_columns("settings")}
    if "kiosk_home_screen" not in cols:
        print("Adding settings.kiosk_home_screen ...")
        with db.engine.begin() as conn:
            conn.execute(text(
                "ALTER TABLE settings ADD COLUMN kiosk_home_screen VARCHAR(16) NOT NULL DEFAULT 'scan'"
            ))


def main():
    app = create_app()
    with app.app_context():
        tables = inspect(db.engine).get_table_names()
        if "users" in tables:
            _make_users_password_email_nullable()
        else:
            print("'users' table doesn't exist — nothing to migrate.")
        if "items" in tables:
            _add_item_measurement_columns()
        _add_settings_columns()
        _create_new_tables()
        _migrate_wire_tables()
        _add_wire_coil_empty_at_column()
        # NOTE: dashboard-layout seeding was removed here -- DashboardLayout
        # belongs to the separate stocktool-api project, not this kiosk
        # codebase (see removed publish_unpublished_layouts.py, which
        # imported from app.extensions -- a module that has never existed
        # in this project).
        print("\nMigration complete.")


if __name__ == "__main__":
    main()
