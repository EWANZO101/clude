"""
seed_test_data.py — creates a handful of test items, tools, a project, and
a stock-user badge, each with a REAL barcode registered in the database.
Unlike a randomly-printed barcode, these will actually resolve correctly
when scanned (lookup, quick-remove, kiosk badge login, etc.) — that's the
whole point of running this instead of just printing arbitrary codes.

Safe to run multiple times — it skips anything whose name it already
created (checks for "TEST — " prefix), so re-running just tops up
whatever's missing rather than duplicating everything.

Usage:
    python scripts/seed_test_data.py
"""
import sys
import os
import base64

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app import create_app
from app.extensions import db
from app.models import Item, Tool, Project, User, Role, Barcode
from app.utils.barcode_helper import generate_barcode

TEST_ITEMS = [
    {"name": "TEST — M8 Hex Bolt", "quantity": 100, "sku": "TEST-BOLT-M8", "unit": "pcs"},
    {"name": "TEST — Cable Tie 200mm", "quantity": 500, "sku": "TEST-CT-200", "unit": "pcs"},
    {"name": "TEST — Safety Gloves (L)", "quantity": 20, "sku": "TEST-GLV-L", "unit": "pairs"},
]

TEST_TOOLS = [
    {"name": "TEST — Cordless Drill", "brand": "DemoBrand", "model": "DB-100"},
    {"name": "TEST — Angle Grinder", "brand": "DemoBrand", "model": "AG-200"},
]

TEST_PROJECTS = [
    {"name": "TEST — Warehouse Refit", "code": "TEST-PRJ-01"},
]

TEST_USERS = [
    {"username": "test_floor1", "email": "test_floor1@example.invalid", "role": Role.STOCK_USER},
]


def main():
    app = create_app()
    with app.app_context():
        created = []

        for data in TEST_ITEMS:
            if Item.query.filter_by(name=data["name"]).first():
                continue
            item = Item(**data)
            db.session.add(item)
            db.session.flush()
            bc = generate_barcode("item", item.id)
            created.append(("Item", item.name, bc.code))

        for data in TEST_TOOLS:
            if Tool.query.filter_by(name=data["name"]).first():
                continue
            tool = Tool(**data)
            db.session.add(tool)
            db.session.flush()
            bc = generate_barcode("tool", tool.id)
            created.append(("Tool", tool.name, bc.code))

        for data in TEST_PROJECTS:
            if Project.query.filter_by(name=data["name"]).first():
                continue
            project = Project(**data)
            db.session.add(project)
            db.session.flush()
            bc = generate_barcode("project", project.id)
            created.append(("Project", project.name, bc.code))

        for data in TEST_USERS:
            if User.query.filter_by(username=data["username"]).first():
                continue
            user = User(username=data["username"], email=data["email"], role=data["role"])
            user.set_password("testpass123")
            db.session.add(user)
            db.session.flush()
            bc = generate_barcode("user", user.id)
            created.append(("User badge", user.username, bc.code))

        db.session.commit()

        # ── Printable sheet, covering every TEST record currently in the DB
        #    (not just ones created this run — so this works even if you
        #    only re-ran to top up a couple of missing rows). ──────────────
        sheet_entries = []
        for item in Item.query.filter(Item.name.like("TEST — %")).all():
            if item.barcode:
                sheet_entries.append(("Item", item.name, item.barcode))
        for tool in Tool.query.filter(Tool.name.like("TEST — %")).all():
            if tool.barcode:
                sheet_entries.append(("Tool", tool.name, tool.barcode))
        for project in Project.query.filter(Project.name.like("TEST — %")).all():
            if project.barcode:
                sheet_entries.append(("Project", project.name, project.barcode))
        for user in User.query.filter(User.username.like("test_%")).all():
            if user.barcode:
                sheet_entries.append(("User badge", user.username, user.barcode))

        sheet_path = _write_print_sheet(app, sheet_entries)

        if not created:
            print("Nothing NEW to create — all test data already exists.")
            print(f"Refreshed the print sheet anyway: {sheet_path}\n")
            return

        print(f"Created {len(created)} test record(s):\n")
        print(f"{'Type':<12} {'Name':<28} {'Barcode Code':<16} Image URL")
        for kind, name, code in created:
            print(f"{kind:<12} {name:<28} {code:<16} /api/barcodes/image/{code}")

        print(f"\nPrintable sheet with all TEST barcodes written to:\n  {sheet_path}")
        print("Download it (scp/sftp) and open it in a browser to print, or view/print "
              "individual ones from the admin site's Items/Tools/Projects/Users pages.")
        print("\nTest stock-user login: username 'test_floor1', password 'testpass123'.")


def _write_print_sheet(app, entries) -> str:
    """Builds a single self-contained HTML file (barcode images embedded as
    base64, no external requests needed) with all TEST barcodes on one
    printable page."""
    cards = []
    for kind, name, bc in entries:
        image_path = os.path.join(app.config["BARCODE_OUTPUT_DIR"], os.path.basename(bc.image_path or ""))
        img_b64 = ""
        if bc.image_path and os.path.exists(image_path):
            with open(image_path, "rb") as f:
                img_b64 = base64.b64encode(f.read()).decode()
        cards.append(f"""
        <div class="card">
          <div class="kind">{kind}</div>
          <div class="name">{name}</div>
          {'<img src="data:image/png;base64,' + img_b64 + '" />' if img_b64 else '<div class="missing">No image generated</div>'}
          <div class="code">{bc.code}</div>
        </div>""")

    html = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>StockTool Test Barcodes</title>
<style>
  body {{ font-family: sans-serif; margin: 24px; }}
  h1 {{ font-size: 18px; }}
  .grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-top: 16px; }}
  .card {{ border: 1px solid #ccc; border-radius: 8px; padding: 12px; text-align: center; page-break-inside: avoid; }}
  .kind {{ font-size: 11px; color: #888; text-transform: uppercase; letter-spacing: .05em; }}
  .name {{ font-size: 13px; font-weight: 600; margin: 2px 0 8px; }}
  .code {{ font-family: monospace; font-size: 11px; color: #555; margin-top: 6px; }}
  img {{ max-width: 100%; }}
  .missing {{ color: #c00; font-size: 12px; padding: 20px 0; }}
  @media print {{ .grid {{ grid-template-columns: repeat(3, 1fr); }} }}
</style></head>
<body>
  <h1>StockTool — Test Barcodes ({len(entries)})</h1>
  <p>Generated by scripts/seed_test_data.py. These are real, working test records — scanning any of these will resolve correctly in the system.</p>
  <div class="grid">{"".join(cards)}</div>
</body></html>"""

    out_path = os.path.join(app.instance_path, "test_barcodes_print_sheet.html")
    with open(out_path, "w") as f:
        f.write(html)
    return out_path


if __name__ == "__main__":
    main()
