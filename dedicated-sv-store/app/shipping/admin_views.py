from flask import render_template, redirect, url_for, request, flash, abort
from flask_login import current_user

from app.extensions import db
from app.models.equipment import CustomerEquipmentRequest, RequestStatus, CustomerEquipmentItem
from app.models.shipping import (
    Shipment,
    ShipmentStatus,
    ReceivingRecord,
    InspectionRecord,
    InspectionItem,
    InspectionResult,
    INSPECTION_CHECKLIST_KEYS,
)
from app.shipping.forms import ShipmentForm, ShipmentEventForm, ReceivingRecordForm, InspectionRecordForm
from app.utils.helpers import log_audit, paginate_query
from app.utils.permissions import permission_required
from app.utils.notifications import notify


def register_admin_shipping_views(admin_bp):
    @admin_bp.route("/shipments")
    @permission_required("shipping.view")
    def shipments():
        page = request.args.get("page", 1, type=int)
        query = Shipment.query.order_by(Shipment.created_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("admin/shipping/list.html", pagination=pagination)

    @admin_bp.route("/requests/<int:request_id>/shipment/new", methods=["GET", "POST"])
    @permission_required("shipping.create")
    def shipment_new(request_id):
        req = db.session.get(CustomerEquipmentRequest, request_id) or abort(404)
        existing = Shipment.query.filter_by(equipment_request_id=req.id).first()
        if existing:
            return redirect(url_for("admin.shipment_detail", shipment_id=existing.id))

        form = ShipmentForm()
        if form.validate_on_submit():
            shipment = Shipment(equipment_request_id=req.id)
            form.populate_obj(shipment)
            db.session.add(shipment)
            db.session.flush()
            shipment.add_event(ShipmentStatus.PENDING, description="Shipment created")
            if req.status not in (RequestStatus.IN_TRANSIT, RequestStatus.RECEIVED, RequestStatus.INSPECTION, RequestStatus.DEPLOYMENT, RequestStatus.COMPLETED):
                req.set_status(RequestStatus.SHIPPING_ARRANGED, changed_by_id=current_user.id, reason="Shipment created")
            log_audit("shipment.created", "Shipment", shipment.id, None, {"request_id": req.id})
            db.session.commit()

            from app.api.v1.webhooks import dispatch_webhook

            dispatch_webhook("shipment.created", {"shipment_id": shipment.id, "shipment_number": shipment.shipment_number})

            flash("Shipment created.", "success")
            return redirect(url_for("admin.shipment_detail", shipment_id=shipment.id))

        return render_template("admin/shipping/shipment_form.html", req=req, form=form)

    @admin_bp.route("/shipments/<int:shipment_id>", methods=["GET", "POST"])
    @permission_required("shipping.edit")
    def shipment_detail(shipment_id):
        shipment = db.session.get(Shipment, shipment_id) or abort(404)
        form = ShipmentEventForm()

        if form.validate_on_submit():
            new_status = ShipmentStatus(form.status.data)
            shipment.add_event(new_status, description=form.description.data, location=form.location.data)

            if new_status in (ShipmentStatus.COLLECTED, ShipmentStatus.IN_TRANSIT, ShipmentStatus.OUT_FOR_DELIVERY):
                shipment.request.set_status(RequestStatus.IN_TRANSIT, changed_by_id=current_user.id, reason="Shipment in transit")

            log_audit("shipment.event_added", "Shipment", shipment.id, None, {"status": new_status.value})
            db.session.commit()
            flash("Tracking event added.", "success")
            return redirect(url_for("admin.shipment_detail", shipment_id=shipment.id))

        receiving = ReceivingRecord.query.filter_by(shipment_id=shipment.id).first()
        return render_template("admin/shipping/detail.html", shipment=shipment, form=form, receiving=receiving)

    @admin_bp.route("/shipments/<int:shipment_id>/receive", methods=["GET", "POST"])
    @permission_required("shipping.edit")
    def shipment_receive(shipment_id):
        shipment = db.session.get(Shipment, shipment_id) or abort(404)
        existing = ReceivingRecord.query.filter_by(shipment_id=shipment.id).first()
        if existing:
            return redirect(url_for("admin.shipment_detail", shipment_id=shipment.id))

        form = ReceivingRecordForm()
        if form.validate_on_submit():
            record = ReceivingRecord(shipment_id=shipment.id, received_by_id=current_user.id)
            form.populate_obj(record)
            db.session.add(record)
            shipment.add_event(ShipmentStatus.DELIVERED, description="Received at datacenter")
            shipment.request.set_status(RequestStatus.RECEIVED, changed_by_id=current_user.id, reason="Equipment received")
            notify(
                shipment.request.user_id, "shipment.delivered", f"{shipment.shipment_number} received",
                body="Your equipment has arrived and been received at our datacenter.",
                link=f"/customer/shipments/{shipment.id}",
            )
            log_audit("shipment.received", "Shipment", shipment.id, None, {"condition": record.condition})
            db.session.commit()

            from app.api.v1.webhooks import dispatch_webhook

            dispatch_webhook("shipment.delivered", {"shipment_id": shipment.id, "shipment_number": shipment.shipment_number})

            flash("Receiving record created.", "success")
            return redirect(url_for("admin.shipment_detail", shipment_id=shipment.id))

        return render_template("admin/shipping/receive_form.html", shipment=shipment, form=form)

    @admin_bp.route("/requests/<int:request_id>/items/<int:item_id>/inspect", methods=["GET", "POST"])
    @permission_required("equipment.inspect")
    def item_inspect(request_id, item_id):
        req = db.session.get(CustomerEquipmentRequest, request_id) or abort(404)
        item = db.session.get(CustomerEquipmentItem, item_id)
        if item is None or item.request_id != req.id:
            abort(404)

        form = InspectionRecordForm()
        if form.validate_on_submit():
            record = InspectionRecord(item_id=item.id, inspector_id=current_user.id)
            form.populate_obj(record)
            record.result = InspectionResult(record.result)
            db.session.add(record)
            db.session.flush()

            for key in INSPECTION_CHECKLIST_KEYS:
                db.session.add(
                    InspectionItem(inspection_record_id=record.id, checklist_key=key, passed=request.form.get(key) == "on")
                )

            if req.status != RequestStatus.INSPECTION:
                req.set_status(RequestStatus.INSPECTION, changed_by_id=current_user.id, reason="Inspection started")

            log_audit("equipment_item.inspected", "CustomerEquipmentItem", item.id, None, {"result": record.result.value})
            db.session.commit()
            flash("Inspection recorded.", "success")
            return redirect(url_for("admin.request_detail", request_id=req.id))

        return render_template(
            "admin/shipping/inspect_form.html", req=req, item=item, form=form, checklist_keys=INSPECTION_CHECKLIST_KEYS
        )

    @admin_bp.route("/receiving")
    @permission_required("shipping.view")
    def receiving():
        page = request.args.get("page", 1, type=int)
        query = ReceivingRecord.query.order_by(ReceivingRecord.received_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("admin/shipping/receiving_list.html", pagination=pagination)

    @admin_bp.route("/inspections")
    @permission_required("equipment.inspect")
    def inspections():
        page = request.args.get("page", 1, type=int)
        query = InspectionRecord.query.order_by(InspectionRecord.inspected_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("admin/shipping/inspections_list.html", pagination=pagination)

    @admin_bp.route("/requests/<int:request_id>/advance", methods=["POST"])
    @permission_required("requests.edit")
    def request_advance(request_id):
        req = db.session.get(CustomerEquipmentRequest, request_id) or abort(404)
        action = request.form.get("action")
        if action == "deploy":
            req.set_status(RequestStatus.DEPLOYMENT, changed_by_id=current_user.id, reason="Deployment started")
        elif action == "complete":
            req.set_status(RequestStatus.COMPLETED, changed_by_id=current_user.id, reason="Request completed")
        db.session.commit()
        flash("Request updated.", "success")
        return redirect(url_for("admin.request_detail", request_id=req.id))
