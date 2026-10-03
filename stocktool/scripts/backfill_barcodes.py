"""
backfill_barcodes.py — generate barcodes for any active items/tools that
don't have one yet.

Needed after upgrading from the old QR-code system (or if barcode
generation ever failed/was skipped for some records). Safe to run
multiple times — it only creates a barcode for records that are missing
one; existing barcodes are left untouched.

Usage:
    python scripts/backfill_barcodes.py
"""
import sys
import os

# Allow running from the project root
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app import create_app
from app.extensions import db
from app.models import Item, Tool
from app.utils.barcode_helper import generate_barcode


def main():
    app = create_app()

    with app.app_context():
        items = Item.query.filter_by(is_active=True).filter(
            ~Item.barcode.has()
        ).all()
        tools = Tool.query.filter_by(is_active=True).filter(
            ~Tool.barcode.has()
        ).all()

        if not items and not tools:
            print("Nothing to do — every active item and tool already has a barcode.")
            return

        print(f"Generating barcodes for {len(items)} item(s) and {len(tools)} tool(s)...")

        for item in items:
            generate_barcode("item", item.id)
            print(f"  [item] {item.name} (id={item.id})")

        for tool in tools:
            generate_barcode("tool", tool.id)
            print(f"  [tool] {tool.name} (id={tool.id})")

        db.session.commit()
        print("Done.")


if __name__ == "__main__":
    main()
