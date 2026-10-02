from flask import render_template, abort
from flask_login import current_user

from app.models.shipping import Shipment
from app.models.equipment import CustomerEquipmentRequest


def register_customer_shipping_views(customer_bp):
    @customer_bp.route("/shipments")
    def shipments():
        rows = (
            Shipment.query.join(CustomerEquipmentRequest)
            .filter(CustomerEquipmentRequest.user_id == current_user.id)
            .order_by(Shipment.created_at.desc())
            .all()
        )
        return render_template("customer/shipments/list.html", shipments=rows)

    @customer_bp.route("/shipments/<int:shipment_id>")
    def shipment_detail(shipment_id):
        shipment = (
            Shipment.query.join(CustomerEquipmentRequest)
            .filter(Shipment.id == shipment_id, CustomerEquipmentRequest.user_id == current_user.id)
            .first()
        )
        if shipment is None:
            abort(404)
        return render_template("customer/shipments/detail.html", shipment=shipment)

    @customer_bp.route("/requests/<int:request_id>/manifest")
    def request_manifest(request_id):
        req = CustomerEquipmentRequest.query.filter_by(id=request_id, user_id=current_user.id).first()
        if req is None:
            abort(404)
        return render_template("customer/requests/manifest.html", req=req)
