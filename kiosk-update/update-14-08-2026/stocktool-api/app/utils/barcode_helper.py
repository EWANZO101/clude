import os
import barcode as barcode_lib
from barcode.writer import ImageWriter
from flask import current_app
from app.extensions import db
from app.models.barcode import Barcode

_Code128 = barcode_lib.get_barcode_class("code128")

_LOOKUP_FIELD = {
    "tool": "tool_id",
    "item": "item_id",
    "user": "user_id",
    "project": "project_id",
}


def generate_barcode(entity_type: str, entity_id: int) -> Barcode:
    """
    Generate or regenerate a Code128 barcode PNG for a tool, item, user, or
    project. Returns the Barcode record. Caller must db.session.commit().
    """
    field = _LOOKUP_FIELD.get(entity_type)
    if not field:
        raise ValueError(f"Unknown entity_type: {entity_type}")

    bc = Barcode.query.filter_by(**{field: entity_id}).first()
    if not bc:
        bc = Barcode(**{field: entity_id})
        db.session.add(bc)
        db.session.flush()

    out_dir = current_app.config["BARCODE_OUTPUT_DIR"]
    os.makedirs(out_dir, exist_ok=True)
    filename = f"{entity_type}_{entity_id}_{bc.code}.png"
    filepath_no_ext = os.path.join(out_dir, filename[:-4])  # writer appends .png

    code128 = _Code128(bc.code, writer=ImageWriter())
    code128.save(filepath_no_ext, options={
        "write_text": True,
        "module_height": 12.0,
        "font_size": 9,
        "text_distance": 3,
        "quiet_zone": 6.5,
    })

    bc.image_path = f"barcodes/{filename}"
    return bc
