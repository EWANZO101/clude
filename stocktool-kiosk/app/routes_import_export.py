"""
CSV import/export for Items and Tools, local-only (mirrors the same
admin-gated pattern as app/routes_admin.py).

Import behaviour:
  - Items are matched by `sku` when the CSV row has one (update-in-place);
    rows with no sku, or an sku not already in the DB, create a new item.
  - Tools are matched by `barcode_code` when the CSV row has one and it
    already exists; otherwise a new tool is created.
  - A blank barcode_code column on a NEW row gets a real, working barcode
    auto-assigned (same helper routes_admin.py's create_item/create_tool
    use), so imported test data behaves identically to anything created
    by hand -- scannable, etc.
  - Bad rows are skipped and reported back individually; one broken row
    never aborts the rest of the file.

Export is a straight CSV dump of every column the model exposes via
to_dict(), so import -> export round-trips losslessly.
"""
import csv
import io
from datetime import datetime, timezone

from flask import Blueprint, request, jsonify, Response

from app.models import db, Item, Tool
from app.auth import permission_required
from app.routes_admin import _assign_barcode, _reassign_barcode, _str_or_none
from app.codes import unique_sku

import_export_bp = Blueprint("import_export", __name__, url_prefix="/api/admin")

ITEM_FIELDS = ["name", "sku", "description", "quantity", "unit", "barcode_code"]
TOOL_FIELDS = ["name", "description", "status", "checked_out_by_name", "barcode_code"]


def _read_csv_upload():
    """Pulls a CSV out of either a multipart file upload (field name
    'file') or a raw text/csv body -- covers both a <form>/FormData
    upload from the browser and a quick `curl --data-binary @x.csv`.
    Returns (DictReader, error_response_or_None)."""
    if "file" in request.files:
        raw = request.files["file"].read()
    else:
        raw = request.get_data()
    if not raw:
        return None, (jsonify({"error": "No CSV file provided (expected multipart field 'file')."}), 400)
    text = raw.decode("utf-8-sig", errors="replace")  # -sig: tolerate Excel's BOM
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None:
        return None, (jsonify({"error": "CSV appears to be empty."}), 400)
    return reader, None


def _csv_response(fieldnames, rows, filename):
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    return Response(
        buf.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# ───────────────────────────── Items ─────────────────────────────────
@import_export_bp.route("/items/export", methods=["GET"])
@permission_required("admin")
def export_items():
    items = Item.query.order_by(Item.name.asc()).all()
    rows = [{k: d.get(k, "") for k in ITEM_FIELDS} for d in (i.to_dict() for i in items)]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return _csv_response(ITEM_FIELDS, rows, f"items_export_{stamp}.csv")


@import_export_bp.route("/items/import", methods=["POST"])
@permission_required("admin")
def import_items():
    reader, err = _read_csv_upload()
    if err:
        return err

    created, updated, errors = 0, 0, []
    for i, row in enumerate(reader, start=2):  # start=2: row 1 is the header
        name = _str_or_none(row.get("name"))
        if not name:
            errors.append(f"Row {i}: 'name' is required — skipped.")
            continue

        try:
            quantity = int(row.get("quantity") or 0)
        except (TypeError, ValueError):
            errors.append(f"Row {i}: quantity '{row.get('quantity')}' isn't an integer — skipped.")
            continue
        if quantity < 0:
            errors.append(f"Row {i}: quantity can't be negative — skipped.")
            continue

        sku = _str_or_none(row.get("sku"))
        requested_code = _str_or_none(row.get("barcode_code"))
        existing = Item.query.filter_by(sku=sku).first() if sku else None

        if existing:
            existing.name = name
            existing.description = _str_or_none(row.get("description"))
            existing.unit = _str_or_none(row.get("unit"))
            existing.quantity = quantity
            if requested_code != existing.barcode_code:
                new_code, code_err = _reassign_barcode("item", existing.id, existing.barcode_code, requested_code)
                if code_err:
                    errors.append(f"Row {i} ({name}): {code_err} — row skipped, item left unchanged.")
                    db.session.rollback()
                    continue
                existing.barcode_code = new_code
            existing.dirty = True
            db.session.commit()
            updated += 1
            continue

        if sku and Item.query.filter_by(sku=sku).first():
            errors.append(f"Row {i} ({name}): SKU '{sku}' already in use — skipped.")
            continue

        item = Item(
            name=name,
            sku=sku or unique_sku(),
            description=_str_or_none(row.get("description")),
            quantity=quantity,
            unit=_str_or_none(row.get("unit")),
        )
        db.session.add(item)
        db.session.flush()
        code, code_err = _assign_barcode("item", item.id, requested_code)
        if code_err:
            db.session.rollback()
            errors.append(f"Row {i} ({name}): {code_err} — skipped.")
            continue
        item.barcode_code = code
        db.session.commit()
        created += 1

    return jsonify({"created": created, "updated": updated, "errors": errors}), 200


# ───────────────────────────── Tools ─────────────────────────────────
@import_export_bp.route("/tools/export", methods=["GET"])
@permission_required("admin")
def export_tools():
    tools = Tool.query.order_by(Tool.name.asc()).all()
    rows = [{k: d.get(k, "") for k in TOOL_FIELDS} for d in (t.to_dict() for t in tools)]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return _csv_response(TOOL_FIELDS, rows, f"tools_export_{stamp}.csv")


@import_export_bp.route("/tools/import", methods=["POST"])
@permission_required("admin")
def import_tools():
    reader, err = _read_csv_upload()
    if err:
        return err

    valid_statuses = (Tool.STATUS_AVAILABLE, Tool.STATUS_CHECKED_OUT, Tool.STATUS_MAINTENANCE)
    created, updated, errors = 0, 0, []
    for i, row in enumerate(reader, start=2):
        name = _str_or_none(row.get("name"))
        if not name:
            errors.append(f"Row {i}: 'name' is required — skipped.")
            continue

        status = _str_or_none(row.get("status")) or Tool.STATUS_AVAILABLE
        if status not in valid_statuses:
            errors.append(f"Row {i} ({name}): status '{status}' must be one of "
                           f"{', '.join(valid_statuses)} — skipped.")
            continue

        requested_code = _str_or_none(row.get("barcode_code"))
        checked_out_by = _str_or_none(row.get("checked_out_by_name"))
        if status == Tool.STATUS_CHECKED_OUT and not checked_out_by:
            errors.append(f"Row {i} ({name}): status is checked_out but checked_out_by_name is blank — skipped.")
            continue

        existing = Tool.query.filter_by(barcode_code=requested_code).first() if requested_code else None

        if existing:
            existing.name = name
            existing.description = _str_or_none(row.get("description"))
            existing.status = status
            existing.checked_out_by_name = checked_out_by if status == Tool.STATUS_CHECKED_OUT else None
            existing.dirty = True
            db.session.commit()
            updated += 1
            continue

        tool = Tool(
            name=name,
            description=_str_or_none(row.get("description")),
            status=status,
            checked_out_by_name=checked_out_by if status == Tool.STATUS_CHECKED_OUT else None,
        )
        db.session.add(tool)
        db.session.flush()
        code, code_err = _assign_barcode("tool", tool.id, requested_code)
        if code_err:
            db.session.rollback()
            errors.append(f"Row {i} ({name}): {code_err} — skipped.")
            continue
        tool.barcode_code = code
        db.session.commit()
        created += 1

    return jsonify({"created": created, "updated": updated, "errors": errors}), 200
