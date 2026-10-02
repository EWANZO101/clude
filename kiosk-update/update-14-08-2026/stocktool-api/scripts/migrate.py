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
from app.extensions import db


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
    """Category, DashboardLayout, and their association tables are brand
    new models — db.create_all() only creates tables that don't exist yet,
    so this is safe to call every run and never touches existing tables."""
    print("Ensuring categories / dashboard_layouts / association tables exist ...")
    db.create_all()


def _ensure_default_layout():
    from app.models.layout import DashboardLayout, DEFAULT_LAYOUT_COMPONENTS
    if DashboardLayout.query.first():
        return
    print("Seeding a default kiosk layout ...")
    layout = DashboardLayout(name="Default Kiosk", slug="default-kiosk", is_default=True)
    layout.draft = DEFAULT_LAYOUT_COMPONENTS
    # Publish immediately, not just draft: kiosks only ever render
    # published_components (that's the whole point of the draft/publish
    # split), so a seeded-but-unpublished layout is invisible to every
    # kiosk until someone happens to open Builder Mode and hit Publish.
    # DEFAULT_LAYOUT_COMPONENTS mirrors the harmless scan-only screen, so
    # publishing it immediately here is safe.
    layout.publish()
    db.session.add(layout)
    db.session.commit()


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
        _ensure_default_layout()
        print("\nMigration complete.")


if __name__ == "__main__":
    main()
