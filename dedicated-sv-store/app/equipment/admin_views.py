from flask import render_template, redirect, url_for, request, flash, abort
from flask_login import current_user

from app.extensions import db
from app.models.equipment import (
    CustomerEquipmentRequest,
    CustomerEquipmentItem,
    EquipmentType,
    EquipmentChangeRequest,
    RequestStatus,
    ChangeRequestStatus,
    CustomerEquipmentHistory,
)
from app.models.user import User, AccountType
from app.equipment.forms import EquipmentItemForm, EquipmentTypeForm
from app.equipment.customer_views import ITEM_FIELDS
from app.utils.helpers import log_audit, paginate_query
from app.utils.permissions import permission_required
from app.utils.notifications import notify


def register_admin_equipment_views(admin_bp):
    @admin_bp.route("/requests")
    @permission_required("requests.view")
    def requests():
        page = request.args.get("page", 1, type=int)
        status_filter = request.args.get("status", "")
        query = CustomerEquipmentRequest.query.order_by(CustomerEquipmentRequest.created_at.desc())
        if status_filter and status_filter in RequestStatus._value2member_map_:
            query = query.filter_by(status=RequestStatus(status_filter))
        pagination = paginate_query(query, page, 25)
        return render_template(
            "admin/requests/list.html", pagination=pagination, status_filter=status_filter,
            statuses=list(RequestStatus),
        )

    @admin_bp.route("/requests/<int:request_id>", methods=["GET", "POST"])
    @permission_required("requests.edit")
    def request_detail(request_id):
        req = db.session.get(CustomerEquipmentRequest, request_id) or abort(404)

        if request.method == "POST":
            action = request.form.get("action")
            if action == "approve":
                req.set_status(RequestStatus.APPROVED, changed_by_id=current_user.id, reason="Approved by admin")
                from app.models.base import utcnow

                req.approved_at = utcnow()
                notify(
                    req.user_id, "request.approved", f"Request {req.request_number} approved",
                    link=f"/customer/requests/{req.id}",
                )
            elif action == "reject":
                req.rejection_reason = request.form.get("reason", "")
                req.set_status(RequestStatus.REJECTED, changed_by_id=current_user.id, reason=req.rejection_reason)
                notify(
                    req.user_id, "request.rejected", f"Request {req.request_number} rejected",
                    body=req.rejection_reason, link=f"/customer/requests/{req.id}",
                )
            elif action == "request_info":
                req.information_requested = request.form.get("reason", "")
                req.set_status(RequestStatus.INFORMATION_REQUIRED, changed_by_id=current_user.id, reason=req.information_requested)
                notify(
                    req.user_id, "request.information_required", f"Information needed for {req.request_number}",
                    body=req.information_requested, link=f"/customer/requests/{req.id}",
                )
            elif action == "technical_review":
                req.set_status(RequestStatus.TECHNICAL_REVIEW, changed_by_id=current_user.id)
            elif action == "under_review":
                req.set_status(RequestStatus.UNDER_REVIEW, changed_by_id=current_user.id)
            elif action == "lock":
                from app.models.base import utcnow

                req.set_status(RequestStatus.LOCKED_FOR_SHIPMENT, changed_by_id=current_user.id, reason="Locked by admin")
                req.locked_at = utcnow()
            elif action == "unlock":
                req.set_status(RequestStatus.INFORMATION_REQUIRED, changed_by_id=current_user.id, reason="Unlocked by admin")
            elif action == "assign_staff":
                staff_id = request.form.get("staff_id", type=int)
                req.assigned_staff_id = staff_id or None
            log_audit("equipment_request.status_changed", "CustomerEquipmentRequest", req.id, None, {"action": action})
            db.session.commit()

            from app.api.v1.webhooks import dispatch_webhook

            dispatch_webhook("request.updated", {"request_id": req.id, "status": req.status.value})

            flash("Request updated.", "success")
            return redirect(url_for("admin.request_detail", request_id=req.id))

        from app.models.shipping import Shipment

        staff_users = User.query.filter(User.account_type.in_([AccountType.STAFF, AccountType.ADMIN])).all()
        shipment = Shipment.query.filter_by(equipment_request_id=req.id).first()
        return render_template("admin/requests/detail.html", req=req, staff_users=staff_users, shipment=shipment)

    @admin_bp.route("/requests/<int:request_id>/items/<int:item_id>", methods=["GET", "POST"])
    @permission_required("equipment.edit")
    def request_item_edit(request_id, item_id):
        req = db.session.get(CustomerEquipmentRequest, request_id) or abort(404)
        item = db.session.get(CustomerEquipmentItem, item_id)
        if item is None or item.request_id != req.id:
            abort(404)

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
            reason = request.form.get("change_reason") or "Updated by admin"
            for field_name, (old_value, new_value) in changes.items():
                db.session.add(
                    CustomerEquipmentHistory(
                        request_id=req.id, item_id=item.id, field_name=field_name,
                        old_value=str(old_value) if old_value is not None else None,
                        new_value=str(new_value) if new_value is not None else None,
                        changed_by_id=current_user.id, reason=reason,
                    )
                )
            log_audit("equipment_item.updated_by_admin", "CustomerEquipmentItem", item.id, None, {"reason": reason})
            db.session.commit()
            flash("Equipment updated.", "success")
            return redirect(url_for("admin.request_detail", request_id=req.id))

        return render_template("admin/requests/item_form.html", req=req, item=item, form=form)

    @admin_bp.route("/requests/<int:request_id>/change-requests/<int:change_id>", methods=["POST"])
    @permission_required("requests.edit")
    def change_request_resolve(request_id, change_id):
        req = db.session.get(CustomerEquipmentRequest, request_id) or abort(404)
        cr = db.session.get(EquipmentChangeRequest, change_id)
        if cr is None or cr.request_id != req.id:
            abort(404)

        action = request.form.get("action")
        from app.models.base import utcnow

        if action == "approve":
            cr.status = ChangeRequestStatus.APPROVED
        elif action == "reject":
            cr.status = ChangeRequestStatus.REJECTED
        cr.admin_response = request.form.get("response", "")
        cr.resolved_by_id = current_user.id
        cr.resolved_at = utcnow()
        log_audit("equipment_change_request.resolved", "EquipmentChangeRequest", cr.id, None, {"status": cr.status.value})
        db.session.commit()
        flash("Change request updated.", "success")
        return redirect(url_for("admin.request_detail", request_id=req.id))

    @admin_bp.route("/customer-equipment")
    @permission_required("equipment.view")
    def customer_equipment():
        page = request.args.get("page", 1, type=int)
        q = request.args.get("q", "").strip()
        query = CustomerEquipmentItem.query.order_by(CustomerEquipmentItem.created_at.desc())
        if q:
            query = query.filter(
                db.or_(
                    CustomerEquipmentItem.serial_number.ilike(f"%{q}%"),
                    CustomerEquipmentItem.asset_number.ilike(f"%{q}%"),
                    CustomerEquipmentItem.model.ilike(f"%{q}%"),
                )
            )
        pagination = paginate_query(query, page, 25)
        return render_template("admin/requests/equipment_list.html", pagination=pagination, q=q)

    @admin_bp.route("/equipment-types", methods=["GET", "POST"])
    @permission_required("equipment.edit")
    def equipment_types():
        form = EquipmentTypeForm()
        if form.validate_on_submit():
            from app.utils.helpers import generate_unique_slug

            equipment_type = EquipmentType(
                name=form.name.data,
                slug=generate_unique_slug(EquipmentType, form.name.data),
                is_networking=form.is_networking.data,
                is_active=form.is_active.data,
            )
            db.session.add(equipment_type)
            db.session.flush()
            log_audit("equipment_type.created", "EquipmentType", equipment_type.id, None, {"name": equipment_type.name})
            db.session.commit()
            flash("Equipment type added.", "success")
            return redirect(url_for("admin.equipment_types"))

        types = EquipmentType.query.order_by(EquipmentType.name).all()
        return render_template("admin/requests/equipment_types.html", types=types, form=form)

    @admin_bp.route("/equipment-types/<int:type_id>/toggle", methods=["POST"])
    @permission_required("equipment.edit")
    def equipment_type_toggle(type_id):
        equipment_type = db.session.get(EquipmentType, type_id) or abort(404)
        equipment_type.is_active = not equipment_type.is_active
        log_audit("equipment_type.toggled", "EquipmentType", equipment_type.id, None, {"is_active": equipment_type.is_active})
        db.session.commit()
        flash("Equipment type updated.", "success")
        return redirect(url_for("admin.equipment_types"))
