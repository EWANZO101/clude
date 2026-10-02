from flask import render_template, redirect, url_for, request, flash, abort
from flask_login import current_user

from app.extensions import db
from app.models.equipment import (
    CustomerEquipmentRequest,
    CustomerEquipmentItem,
    EquipmentAttachment,
    EquipmentType,
    EquipmentChangeRequest,
    RequestStatus,
    CustomerEquipmentHistory,
)
from app.equipment.forms import EquipmentItemForm, EquipmentAttachmentForm, ChangeRequestForm
from app.utils.helpers import log_audit
from app.utils.uploads import save_private_file

ITEM_FIELDS = [
    "manufacturer", "model", "serial_number", "asset_number", "quantity",
    "cpu_summary", "ram_summary", "storage_summary", "gpu_summary", "raid_summary",
    "psu_summary", "chassis_summary", "port_count", "port_types", "port_speeds",
    "mac_address", "firmware_version", "network_summary", "rack_mount", "u_height",
    "dimensions", "weight_kg", "power_requirements", "declared_value",
    "replacement_value", "insurance_value", "notes",
]


def _own_request_or_404(request_id):
    req = CustomerEquipmentRequest.query.filter_by(id=request_id, user_id=current_user.id).first()
    if req is None:
        abort(404)
    return req


def _own_item_or_404(req, item_id):
    item = db.session.get(CustomerEquipmentItem, item_id)
    if item is None or item.request_id != req.id:
        abort(404)
    return item


def _require_editable(req):
    if not req.is_editable:
        abort(403)


def register_customer_equipment_views(customer_bp):
    @customer_bp.route("/requests", endpoint="requests")
    def requests_list():
        reqs = (
            CustomerEquipmentRequest.query.filter_by(user_id=current_user.id)
            .order_by(CustomerEquipmentRequest.created_at.desc())
            .all()
        )
        return render_template("customer/requests/list.html", requests=reqs)

    @customer_bp.route("/requests/new", methods=["POST"])
    def request_new():
        req = CustomerEquipmentRequest(user_id=current_user.id, status=RequestStatus.DRAFT)
        db.session.add(req)
        db.session.flush()
        log_audit("equipment_request.created", "CustomerEquipmentRequest", req.id)
        db.session.commit()
        flash("New equipment hosting request created.", "success")
        return redirect(url_for("customer.request_detail", request_id=req.id))

    @customer_bp.route("/requests/<int:request_id>")
    def request_detail(request_id):
        req = _own_request_or_404(request_id)
        return render_template("customer/requests/detail.html", req=req)

    @customer_bp.route("/requests/<int:request_id>/items/new", methods=["GET", "POST"])
    def request_item_new(request_id):
        req = _own_request_or_404(request_id)
        _require_editable(req)

        form = EquipmentItemForm()
        form.equipment_type_id.choices = [
            (t.id, t.name) for t in EquipmentType.query.filter_by(is_active=True).order_by(EquipmentType.name)
        ]

        if form.validate_on_submit():
            item = CustomerEquipmentItem(request_id=req.id)
            form.populate_obj(item)
            db.session.add(item)
            db.session.flush()
            db.session.add(
                CustomerEquipmentHistory(
                    request_id=req.id, item_id=item.id, field_name="item_added",
                    new_value=f"{item.manufacturer} {item.model}".strip(), changed_by_id=current_user.id,
                )
            )
            log_audit("equipment_item.created", "CustomerEquipmentItem", item.id)
            db.session.commit()
            flash("Equipment added.", "success")
            return redirect(url_for("customer.request_detail", request_id=req.id))

        return render_template("customer/requests/item_form.html", req=req, form=form, is_new=True)

    @customer_bp.route("/requests/<int:request_id>/items/<int:item_id>", methods=["GET", "POST"])
    def request_item_edit(request_id, item_id):
        req = _own_request_or_404(request_id)
        _require_editable(req)
        item = _own_item_or_404(req, item_id)

        form = EquipmentItemForm(obj=item)
        form.equipment_type_id.choices = [
            (t.id, t.name) for t in EquipmentType.query.filter_by(is_active=True).order_by(EquipmentType.name)
        ]

        if form.validate_on_submit():
            changes = {}
            for field_name in ITEM_FIELDS:
                old_value = getattr(item, field_name)
                new_value = getattr(form, field_name).data
                if str(old_value) != str(new_value):
                    changes[field_name] = (old_value, new_value)
            form.populate_obj(item)
            for field_name, (old_value, new_value) in changes.items():
                db.session.add(
                    CustomerEquipmentHistory(
                        request_id=req.id, item_id=item.id, field_name=field_name,
                        old_value=str(old_value) if old_value is not None else None,
                        new_value=str(new_value) if new_value is not None else None,
                        changed_by_id=current_user.id, reason="Updated customer specification",
                    )
                )
            log_audit("equipment_item.updated", "CustomerEquipmentItem", item.id)
            db.session.commit()
            flash("Equipment updated.", "success")
            return redirect(url_for("customer.request_detail", request_id=req.id))

        return render_template("customer/requests/item_form.html", req=req, form=form, is_new=False, item=item)

    @customer_bp.route("/requests/<int:request_id>/items/<int:item_id>/delete", methods=["POST"])
    def request_item_delete(request_id, item_id):
        req = _own_request_or_404(request_id)
        _require_editable(req)
        item = _own_item_or_404(req, item_id)

        db.session.add(
            CustomerEquipmentHistory(
                request_id=req.id, field_name="item_removed",
                old_value=f"{item.manufacturer} {item.model}".strip(), changed_by_id=current_user.id,
            )
        )
        db.session.delete(item)
        log_audit("equipment_item.deleted", "CustomerEquipmentItem", item_id)
        db.session.commit()
        flash("Equipment removed.", "success")
        return redirect(url_for("customer.request_detail", request_id=req.id))

    @customer_bp.route("/requests/<int:request_id>/items/<int:item_id>/attachments", methods=["GET", "POST"])
    def request_item_attachments(request_id, item_id):
        req = _own_request_or_404(request_id)
        item = _own_item_or_404(req, item_id)

        form = EquipmentAttachmentForm()
        if form.validate_on_submit():
            _require_editable(req)
            path, error = save_private_file(form.file.data, f"equipment/{item.id}")
            if error:
                flash(error, "error")
            else:
                db.session.add(
                    EquipmentAttachment(
                        item_id=item.id, file_path=path, attachment_type=form.attachment_type.data,
                        original_filename=form.file.data.filename, uploaded_by_id=current_user.id,
                    )
                )
                log_audit("equipment_attachment.added", "CustomerEquipmentItem", item.id)
                db.session.commit()
                flash("File uploaded.", "success")
            return redirect(url_for("customer.request_item_attachments", request_id=req.id, item_id=item.id))

        return render_template("customer/requests/attachments.html", req=req, item=item, form=form)

    @customer_bp.route("/requests/<int:request_id>/items/<int:item_id>/attachments/<int:attachment_id>/delete", methods=["POST"])
    def request_item_attachment_delete(request_id, item_id, attachment_id):
        req = _own_request_or_404(request_id)
        _require_editable(req)
        item = _own_item_or_404(req, item_id)
        attachment = db.session.get(EquipmentAttachment, attachment_id)
        if attachment is None or attachment.item_id != item.id:
            abort(404)
        db.session.delete(attachment)
        db.session.commit()
        flash("File removed.", "success")
        return redirect(url_for("customer.request_item_attachments", request_id=req.id, item_id=item.id))

    @customer_bp.route("/requests/<int:request_id>/submit", methods=["POST"])
    def request_submit(request_id):
        req = _own_request_or_404(request_id)
        _require_editable(req)

        if not req.items:
            flash("Add at least one piece of equipment before submitting.", "error")
            return redirect(url_for("customer.request_detail", request_id=req.id))

        from app.models.base import utcnow

        req.submitted_at = req.submitted_at or utcnow()
        req.set_status(RequestStatus.SUBMITTED, changed_by_id=current_user.id, reason="Submitted by customer")
        log_audit("equipment_request.submitted", "CustomerEquipmentRequest", req.id)
        db.session.commit()
        flash("Request submitted for review.", "success")
        return redirect(url_for("customer.request_detail", request_id=req.id))

    @customer_bp.route("/requests/<int:request_id>/change-request", methods=["GET", "POST"])
    def request_change_request(request_id):
        req = _own_request_or_404(request_id)
        if not req.is_locked:
            return redirect(url_for("customer.request_detail", request_id=req.id))

        form = ChangeRequestForm()
        if form.validate_on_submit():
            db.session.add(
                EquipmentChangeRequest(request_id=req.id, message=form.message.data, created_by_id=current_user.id)
            )
            log_audit("equipment_change_request.created", "CustomerEquipmentRequest", req.id)
            db.session.commit()
            flash("Change request submitted. Our team will review it shortly.", "success")
            return redirect(url_for("customer.request_detail", request_id=req.id))

        return render_template("customer/requests/change_request_form.html", req=req, form=form)
