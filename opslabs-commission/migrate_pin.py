"""
Run this ONCE on the server to add the pin_hash column.
Usage: python3 migrate_pin.py
Run from: /root/cioda_commissions/cioda-commissions/
"""
import sqlite3, os

DB_PATH = 'instance/commissions.db'
print(f"Using database: {DB_PATH}")

conn = sqlite3.connect(DB_PATH)
cur  = conn.cursor()

# Show all tables so we can find the right one
cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
tables = [row[0] for row in cur.fetchall()]
print(f"Tables found: {tables}")

# Find the orders table
order_table = None
for t in tables:
    if 'order' in t.lower():
        order_table = t
        break

if not order_table:
    print("❌ Could not find an orders table. Tables are:", tables)
    conn.close()
    exit(1)

print(f"Using table: {order_table}")

cur.execute(f"PRAGMA table_info('{order_table}')")
cols = [row[1] for row in cur.fetchall()]
print(f"Existing columns: {cols}")

if 'pin_hash' in cols:
    print("✅ pin_hash column already exists — nothing to do.")
else:
    cur.execute(f'ALTER TABLE "{order_table}" ADD COLUMN pin_hash VARCHAR(64)')
    conn.commit()
    print("✅ pin_hash column added successfully.")

conn.close()
