from flask import Blueprint, render_template, redirect, url_for, request, flash, abort

from app.extensions import db
from app.models import ItemType, InventoryItem, Settings
from app.permissions import require_login_if_enabled, require_admin, current_actor
from app.barcode_render import code128_data_uri, qr_data_uri
from app import item_type_admin, inventory_admin, measurement

bp = Blueprint("inventory", __name__, url_prefix="/inventory")


def _custom_fields_form(fields, form):
    """Extracts {field_key: value} from a submitted form for a type's
    custom fields, coercing booleans/numbers per field_type."""
    values = {}
    for f in fields:
        raw = form.get(f"field_{f['key']}")
        if f["field_type"] == "boolean":
            values[f["key"]] = (raw == "on")
        elif f["field_type"] == "number":
            try:
                values[f["key"]] = float(raw) if raw not in (None, "") else None
            except ValueError:
                values[f["key"]] = raw
        else:
            values[f["key"]] = raw
    return values


# ---------------------------------------------------------------------------
# Type manager
# ---------------------------------------------------------------------------

@bp.route("/")
@require_admin
def type_manager():
    return render_template(
        "inventory/types.html", types=item_type_admin.all_types_state(), field_types=item_type_admin.FIELD_TYPES,
    )


@bp.route("/types/add", methods=["POST"])
@require_admin
def add_type():
    ok, message = item_type_admin.create_type(
        current_actor(), request.form.get("name", ""), request.form.get("description", ""),
    )
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.type_manager"))


@bp.route("/types/<type_key>/edit", methods=["POST"])
@require_admin
def edit_type(type_key):
    ok, message = item_type_admin.update_type(
        current_actor(), type_key, request.form.get("name", ""), request.form.get("description", ""),
    )
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.type_manager"))


@bp.route("/types/<type_key>/delete", methods=["POST"])
@require_admin
def delete_type(type_key):
    ok, message = item_type_admin.delete_type(current_actor(), type_key)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.type_manager"))


@bp.route("/types/<type_key>/fields/add", methods=["POST"])
@require_admin
def add_field(type_key):
    options_raw = request.form.get("options", "")
    options = [o.strip() for o in options_raw.split(",") if o.strip()]
    ok, message = item_type_admin.add_field(
        current_actor(), type_key, request.form.get("label", ""), request.form.get("field_type", "text"),
        options=options, required=(request.form.get("required") == "on"),
    )
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.type_manager"))


@bp.route("/types/<type_key>/fields/<int:field_id>/edit", methods=["POST"])
@require_admin
def edit_field(type_key, field_id):
    options_raw = request.form.get("options", "")
    options = [o.strip() for o in options_raw.split(",") if o.strip()]
    ok, message = item_type_admin.update_field(
        current_actor(), field_id, request.form.get("label", ""), request.form.get("field_type", "text"),
        options=options, required=(request.form.get("required") == "on"),
    )
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.type_manager"))


@bp.route("/types/<type_key>/fields/<int:field_id>/delete", methods=["POST"])
@require_admin
def delete_field(type_key, field_id):
    ok, message = item_type_admin.delete_field(current_actor(), field_id)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.type_manager"))


# ---------------------------------------------------------------------------
# Item list / add / bulk (per type)
# ---------------------------------------------------------------------------

@bp.route("/type/<type_key>")
@require_login_if_enabled
def list_type_items(type_key):
    item_type = ItemType.query.filter_by(key=type_key, deleted_at=None).first()
    if item_type is None:
        abort(404)
    q = request.args.get("q", "").strip()
    query = InventoryItem.query.filter_by(item_type_key=type_key, deleted_at=None)
    if q:
        query = query.filter(InventoryItem.name.ilike(f"%{q}%"))
    items = query.order_by(InventoryItem.name).all()
    fields = item_type_admin.type_state(type_key)["fields"]
    return render_template(
        "inventory/list.html", item_type=item_type, items=items, fields=fields, q=q,
        all_types=ItemType.query.filter_by(deleted_at=None).order_by(ItemType.name).all(),
        measurement_kinds=measurement.MEASUREMENT_KINDS, barcode_enabled=Settings.get().barcode_enabled,
    )


@bp.route("/type/<type_key>/add", methods=["POST"])
@require_login_if_enabled
def add_item(type_key):
    item_type = ItemType.query.filter_by(key=type_key, deleted_at=None).first()
    if item_type is None:
        abort(404)
    fields = item_type_admin.type_state(type_key)["fields"]
    custom_values = _custom_fields_form(fields, request.form)
    ok, message, _item = inventory_admin.create_item(
        current_actor(), type_key, request.form.get("name", ""),
        sku=request.form.get("sku"), serial_number=request.form.get("serial_number"),
        quantity_value=(float(request.form["quantity_value"]) if request.form.get("quantity_value") else None),
        quantity_unit=request.form.get("quantity_unit") or None,
        custom_fields=custom_values, status=request.form.get("status", "active"),
    )
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.list_type_items", type_key=type_key))


@bp.route("/<int:item_id>/delete", methods=["POST"])
@require_login_if_enabled
def delete_item(item_id):
    item = InventoryItem.query.get_or_404(item_id)
    type_key = item.item_type_key
    ok, message = inventory_admin.delete_item(current_actor(), item_id)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.list_type_items", type_key=type_key))


@bp.route("/bulk", methods=["POST"])
@require_login_if_enabled
def bulk_action():
    type_key = request.form.get("type_key", "")
    item_ids = [int(i) for i in request.form.getlist("item_ids") if i.isdigit()]
    action = request.form.get("action", "")
    if not item_ids:
        flash("No items were selected.", "danger")
        return redirect(url_for("inventory.list_type_items", type_key=type_key))

    if action == "delete":
        ok, message, _count = inventory_admin.bulk_delete(current_actor(), item_ids)
    elif action == "set_status":
        ok, message, _count = inventory_admin.bulk_update(current_actor(), item_ids, status=request.form.get("status"))
    elif action == "set_unit":
        ok, message, _count = inventory_admin.bulk_update(current_actor(), item_ids, quantity_unit=request.form.get("quantity_unit"))
    elif action == "set_type":
        ok, message, _count = inventory_admin.bulk_update(current_actor(), item_ids, item_type_key=request.form.get("new_type_key"))
    else:
        ok, message = False, f"Unknown bulk action '{action}'."
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.list_type_items", type_key=type_key))


# ---------------------------------------------------------------------------
# Manage view — the dedicated per-item page
# ---------------------------------------------------------------------------

@bp.route("/<int:item_id>/manage")
@require_login_if_enabled
def manage_item(item_id):
    item = InventoryItem.query.get_or_404(item_id)
    item_type = ItemType.query.get(item.item_type_key)
    fields = item_type_admin.type_state(item.item_type_key)["fields"]
    current_kind = measurement.kind_for_unit(item.quantity_unit) if item.quantity_unit else None
    barcode_enabled = Settings.get().barcode_enabled
    return render_template(
        "inventory/manage.html", item=item, item_type=item_type, fields=fields,
        custom_values=item.custom_fields_dict(),
        all_types=ItemType.query.filter_by(deleted_at=None).order_by(ItemType.name).all(),
        measurement_kinds=measurement.MEASUREMENT_KINDS, current_kind=current_kind,
        barcode_enabled=barcode_enabled,
        barcode_data_uri=code128_data_uri(item.barcode_code) if barcode_enabled and item.barcode_code else None,
        qr_data_uri=qr_data_uri(item.barcode_code) if barcode_enabled and item.barcode_code else None,
        event_types=inventory_admin.EVENT_TYPES,
    )


@bp.route("/<int:item_id>/manage/save", methods=["POST"])
@require_login_if_enabled
def save_item(item_id):
    item = InventoryItem.query.get_or_404(item_id)
    fields = item_type_admin.type_state(item.item_type_key)["fields"]
    custom_values = _custom_fields_form(fields, request.form)
    ok, message = inventory_admin.update_item(
        current_actor(), item_id, name=request.form.get("name"), sku=request.form.get("sku"),
        serial_number=request.form.get("serial_number"), status=request.form.get("status"),
        custom_fields=custom_values, checked_out_by_name=request.form.get("checked_out_by_name"),
        current_project=request.form.get("current_project"),
    )
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.manage_item", item_id=item_id))


@bp.route("/<int:item_id>/manage/measurement", methods=["POST"])
@require_login_if_enabled
def set_measurement(item_id):
    ok, message = inventory_admin.change_measurement(current_actor(), item_id, request.form.get("quantity_unit", ""))
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.manage_item", item_id=item_id))


@bp.route("/<int:item_id>/manage/type", methods=["POST"])
@require_login_if_enabled
def set_type(item_id):
    ok, message = inventory_admin.change_type(current_actor(), item_id, request.form.get("item_type_key", ""))
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.manage_item", item_id=item_id))


@bp.route("/<int:item_id>/manage/generate-sku", methods=["POST"])
@require_login_if_enabled
def generate_sku(item_id):
    ok, message = inventory_admin.generate_sku(current_actor(), item_id)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.manage_item", item_id=item_id))


@bp.route("/<int:item_id>/manage/generate-serial", methods=["POST"])
@require_login_if_enabled
def generate_serial(item_id):
    ok, message = inventory_admin.generate_serial_number(current_actor(), item_id)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.manage_item", item_id=item_id))


@bp.route("/<int:item_id>/manage/event", methods=["POST"])
@require_login_if_enabled
def log_event(item_id):
    ok, message = inventory_admin.log_event(
        current_actor(), item_id, request.form.get("event_type", ""),
        project=request.form.get("project"), detail=request.form.get("detail"),
    )
    flash(message, "success" if ok else "danger")
    return redirect(url_for("inventory.manage_item", item_id=item_id))
