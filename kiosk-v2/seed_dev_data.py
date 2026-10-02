"""Dev/test helper — seeds the local DB with sample data. Not shipped in
the .exe; run manually with `python seed_dev_data.py` during development."""
import sys
sys.path.insert(0, ".")

from app import create_app
from app.models import db, Item, Tool, Project, Barcode, LocalUser

app = create_app()
with app.app_context():
    db.create_all()

    if not LocalUser.query.filter_by(username="admin").first():
        db.session.add(LocalUser(username="admin", badge_code="ADMIN0001", role="admin"))
    if not LocalUser.query.filter_by(username="floor_bob").first():
        db.session.add(LocalUser(username="floor_bob", badge_code="BOB000001", role="stock_user"))

    if not Item.query.filter_by(sku="W-001").first():
        item = Item(name="Test Widget", sku="W-001", quantity=25, unit="ea")
        db.session.add(item)
        db.session.flush()
        db.session.add(Barcode(code="ITEM0000001", entity_type="item", entity_id=item.id))
        item.barcode_code = "ITEM0000001"

    if not Tool.query.filter_by(name="Cordless Drill").first():
        tool = Tool(name="Cordless Drill", status=Tool.STATUS_AVAILABLE)
        db.session.add(tool)
        db.session.flush()
        db.session.add(Barcode(code="TOOL0000001", entity_type="tool", entity_id=tool.id))
        tool.barcode_code = "TOOL0000001"

    if not Project.query.filter_by(name="Warehouse Renovation").first():
        db.session.add(Project(name="Warehouse Renovation", description="Q3 storage expansion"))

    db.session.commit()
    print("Seeded dev data.")
