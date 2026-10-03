"""
migrate_discord.py  –  Run ONCE to add the new columns needed for Discord sync.
Usage:  python migrate_discord.py
"""
import sqlite3, os

DB_DIR  = os.path.join(os.path.expanduser('~'), 'cioda_data')
DB_PATH = os.path.join(DB_DIR, 'commissions.db')

conn = sqlite3.connect(DB_PATH)
cur  = conn.cursor()

migrations = [
    # SiteSettings: bot token, ticket channel ID, shared secret
    "ALTER TABLE site_settings ADD COLUMN discord_bot_token TEXT DEFAULT ''",
    "ALTER TABLE site_settings ADD COLUMN discord_ticket_channel TEXT DEFAULT ''",
    "ALTER TABLE site_settings ADD COLUMN discord_bot_secret TEXT DEFAULT ''",
    # Ticket: which Discord thread is linked to this ticket
    "ALTER TABLE ticket ADD COLUMN discord_thread_id TEXT",
]

for sql in migrations:
    try:
        cur.execute(sql)
        print(f"  ✓  {sql[:70]}")
    except sqlite3.OperationalError as e:
        print(f"  –  already exists, skipping  ({e})")

conn.commit()
conn.close()
print("\nMigration complete.")
