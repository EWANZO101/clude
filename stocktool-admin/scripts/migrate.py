"""
migrate.py — brings an EXISTING database up to date with the current
models. Safe to run any time, including on a brand-new database (every
step checks before it acts) — run this after every deploy that changes
a model, not just the first time.

Usage:
    python scripts/migrate.py
"""
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import text, inspect
from app import create_app
from app.extensions import db


def _columns(table: str) -> set:
    return {c["name"] for c in inspect(db.engine).get_columns(table)}


def _add_column(table: str, column: str, ddl_type: str, default_sql: str = None):
    if column in _columns(table):
        print(f"{table}.{column} already exists — skipping.")
        return
    print(f"Adding {table}.{column}...")
    stmt = f"ALTER TABLE {table} ADD COLUMN {column} {ddl_type}"
    if default_sql is not None:
        stmt += f" DEFAULT {default_sql}"
    with db.engine.begin() as conn:
        conn.execute(text(stmt))


def _make_users_password_email_nullable():
    """
    SQLite can't just drop a NOT NULL constraint with ALTER TABLE — it
    needs the classic recreate-copy-swap dance. Needed so a user row can
    have password_hash/email = NULL for badge-only accounts (badge scan
    is their only credential, no password, optionally no email either).

    Safe to run on a table that's already nullable — checked first.
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


def main():
    app = create_app()
    with app.app_context():
        tables = inspect(db.engine).get_table_names()

        # settings.max_checkout_hours — overdue-tool KPI threshold
        if "settings" in tables:
            _add_column("settings", "max_checkout_hours", "INTEGER", "24")
        else:
            print("'settings' table doesn't exist yet — run scripts/init_db.py first "
                  "(or restart the app once; Settings.get() creates its own row on first use).")

        # users.password_hash / users.email — badge-only accounts
        if "users" in tables:
            _make_users_password_email_nullable()

        print("\nMigration complete.")


if __name__ == "__main__":
    main()
