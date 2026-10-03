"""
═══════════════════════════════════════════════════════════════════════════
  migrate_ticket_statuses.py — one-time DB migration
═══════════════════════════════════════════════════════════════════════════
  Adds the resolution_note column and remaps legacy statuses to the new
  5-stage flow.

  Usage:
      cd /root/opslabs
      ./venv/bin/python migrate_ticket_statuses.py

  Safe to re-run (idempotent).
═══════════════════════════════════════════════════════════════════════════
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import create_app, db
from sqlalchemy import text


app = create_app()
with app.app_context():

    # 1. Add the resolution_note column if it doesn't exist (SQLite trick)
    conn = db.engine.connect()
    cols = [r[1] for r in conn.execute(text("PRAGMA table_info(tickets)"))]
    if "resolution_note" not in cols:
        conn.execute(text("ALTER TABLE tickets ADD COLUMN resolution_note TEXT"))
        conn.commit()
        print("✅ Added column: tickets.resolution_note")
    else:
        print("ℹ️  Column tickets.resolution_note already exists")

    # 2. Remap legacy "open" → "seen" and "closed" → "resolved"
    open_count = conn.execute(text(
        "UPDATE tickets SET status='seen' WHERE status='open'"
    )).rowcount
    closed_count = conn.execute(text(
        "UPDATE tickets SET status='resolved' WHERE status='closed'"
    )).rowcount
    conn.commit()

    print(f"✅ Remapped {open_count} 'open' tickets → 'seen'")
    print(f"✅ Remapped {closed_count} 'closed' tickets → 'resolved'")

    # 3. Sanity check
    rows = conn.execute(text(
        "SELECT status, COUNT(*) FROM tickets GROUP BY status"
    )).fetchall()
    print("\nCurrent ticket-status distribution:")
    for status, n in rows:
        print(f"  {status:<14} {n}")

    conn.close()
print("\nDone.")
