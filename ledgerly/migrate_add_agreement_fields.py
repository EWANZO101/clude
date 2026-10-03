"""
One-off migration: adds the agreement/PIN/signature columns to an existing
ledgerly.db created before those features existed. Safe to run more than
once — it checks which columns already exist first.

Usage (from the project folder, with your venv active):
    python3 migrate_add_agreement_fields.py
"""
import sqlite3
import os

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ledgerly.db")

NEW_COLUMNS = [
    ("agreement_text", "TEXT"),
    ("signed_by_name", "VARCHAR(160)"),
    ("signature_text", "VARCHAR(200)"),
    ("signed_at", "DATETIME"),
    ("pin_code", "VARCHAR(10)"),
    ("client_can_build_schedule", "BOOLEAN DEFAULT 1"),
]


def main():
    if not os.path.exists(DB_PATH):
        print(f"No database found at {DB_PATH} — nothing to migrate. "
              f"Just run the app and it'll create a fresh one with all columns.")
        return

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("PRAGMA table_info(contract)")
    existing = {row[1] for row in cur.fetchall()}

    added = []
    for name, coltype in NEW_COLUMNS:
        if name not in existing:
            cur.execute(f"ALTER TABLE contract ADD COLUMN {name} {coltype}")
            added.append(name)

    conn.commit()
    conn.close()

    if added:
        print(f"Added columns to contract table: {', '.join(added)}")
    else:
        print("Database already has all columns — nothing to do.")


if __name__ == "__main__":
    main()
