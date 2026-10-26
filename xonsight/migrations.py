from sqlalchemy import inspect, text

from .extensions import db

# Columns added to models.py after a table already existed in production.
# Flask-SQLAlchemy's db.create_all() only creates missing tables, it never
# alters existing ones - so new columns need an explicit ALTER TABLE against
# whatever database is already deployed.
_NEW_COLUMNS = {
    "users": [
        # Self-serve community signup (community_signup.py) - null for every pre-existing account.
        ("community_id", "INTEGER"),
    ],
    "evidence": [
        ("device_serial", "VARCHAR(128) NOT NULL DEFAULT ''"),
        ("transcript", "TEXT NOT NULL DEFAULT ''"),
        ("owner_id", "INTEGER"),
    ],
    "active_recorders": [
        ("status", "VARCHAR(16) NOT NULL DEFAULT 'recording'"),
    ],
    "community_requests": [
        ("is_general", "BOOLEAN NOT NULL DEFAULT 0"),
        # Per-community /report tip line (community.py's report_general) - null for the original
        # single-tenant site's own general request, seeded once already.
        ("community_id", "INTEGER"),
    ],
    "settings": [
        ("discord_webhook_url", "VARCHAR(512) NOT NULL DEFAULT ''"),
        ("discord_notify_evidence", "BOOLEAN NOT NULL DEFAULT 1"),
        ("discord_notify_alerts", "BOOLEAN NOT NULL DEFAULT 1"),
        ("discord_notify_bolos", "BOOLEAN NOT NULL DEFAULT 1"),
        # Per-community settings (admin.py's settings()) - null for the existing control-plane row, which
        # keeps behaving exactly as it always has. No UNIQUE constraint on a retrofitted column (SQLite
        # ALTER TABLE can't add one) - Settings.get()'s filter-then-create is the actual guard.
        ("community_id", "INTEGER"),
    ],
    "communities": [
        # Premium add-on: the in-game phone's Bodycam app ("My footage" / "Live" tabs). Off by default - a
        # community has to be explicitly granted it, same as any other premium feature. The original
        # single-tenant server (no Community row at all) is unaffected - it was never gated on this.
        ("phone_app_enabled", "BOOLEAN NOT NULL DEFAULT 0"),
    ],
}


def run_light_migrations():
    """Safe to call on every boot: only adds a column if inspect() says a
    table already exists and doesn't have it yet. Brand new tables are left
    alone - db.create_all() (called right after this) creates those with
    every column already in place."""
    inspector = inspect(db.engine)
    existing_tables = set(inspector.get_table_names())

    for table, columns in _NEW_COLUMNS.items():
        if table not in existing_tables:
            continue
        existing_columns = {c["name"] for c in inspector.get_columns(table)}
        for name, ddl_type in columns:
            if name in existing_columns:
                continue
            with db.engine.begin() as conn:
                conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {ddl_type}"))
