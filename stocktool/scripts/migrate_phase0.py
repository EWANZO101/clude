"""
migrate_phase0.py — upgrades an EXISTING stocktool-admin database to the
Phase 0 schema (kiosk foundations): adds the `projects` table, adds
user_id/project_id to `barcodes`, adds quantity_delta/device to
`audit_logs`, and generates a badge barcode for any user that doesn't
have one yet.

Safe to run multiple times — every step checks before it acts.

Usage:
    python scripts/migrate_phase0.py

For a BRAND NEW install (empty database), you don't need this — just run
scripts/init_db.py, which creates all tables (including the new ones)
from the current models directly.
"""
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import text, inspect
from app import create_app
from app.extensions import db
from app.models import User
from app.utils.barcode_helper import generate_barcode


def _table_exists(name: str) -> bool:
    return name in inspect(db.engine).get_table_names()


def _columns(table: str) -> set:
    return {c["name"] for c in inspect(db.engine).get_columns(table)}


def main():
    app = create_app()

    with app.app_context():
        # ── 1. New `projects` table ─────────────────────────────────────────
        if not _table_exists("projects"):
            print("Creating 'projects' table...")
            from app.models.project import Project
            Project.__table__.create(db.engine)
        else:
            print("'projects' table already exists — skipping.")

        # ── 2. New columns on `barcodes` ────────────────────────────────────
        barcode_cols = _columns("barcodes")
        with db.engine.begin() as conn:
            if "user_id" not in barcode_cols:
                print("Adding barcodes.user_id...")
                conn.execute(text("ALTER TABLE barcodes ADD COLUMN user_id INTEGER REFERENCES users(id)"))
            else:
                print("barcodes.user_id already exists — skipping.")

            if "project_id" not in barcode_cols:
                print("Adding barcodes.project_id...")
                conn.execute(text("ALTER TABLE barcodes ADD COLUMN project_id INTEGER REFERENCES projects(id)"))
            else:
                print("barcodes.project_id already exists — skipping.")

        # ── 3. New columns on `audit_logs` ──────────────────────────────────
        audit_cols = _columns("audit_logs")
        with db.engine.begin() as conn:
            if "quantity_delta" not in audit_cols:
                print("Adding audit_logs.quantity_delta...")
                conn.execute(text("ALTER TABLE audit_logs ADD COLUMN quantity_delta INTEGER"))
            else:
                print("audit_logs.quantity_delta already exists — skipping.")

            if "device" not in audit_cols:
                print("Adding audit_logs.device...")
                conn.execute(text("ALTER TABLE audit_logs ADD COLUMN device VARCHAR(64)"))
            else:
                print("audit_logs.device already exists — skipping.")

        # ── 4. Backfill badge barcodes for existing users ───────────────────
        users_missing_badge = User.query.filter(~User.barcode.has()).all()
        if users_missing_badge:
            print(f"Generating badges for {len(users_missing_badge)} user(s)...")
            for user in users_missing_badge:
                generate_barcode("user", user.id)
                print(f"  [user] {user.username} (id={user.id})")
            db.session.commit()
        else:
            print("Every user already has a badge barcode.")

        print("\nPhase 0 migration complete.")


if __name__ == "__main__":
    main()
