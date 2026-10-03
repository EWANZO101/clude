from flask import request, g

from app.api.v1 import api_v1_bp
from app.api.v1.helpers import api_success, api_error, pagination_meta
from app.api.v1.auth import require_api_key
from app.models.equipment import CustomerEquipmentRequest
from app.models.finance import Invoice, Payment
from app.models.shipping import Shipment


def _serialize_request(r):
    return {
        "id": r.id,
        "request_number": r.request_number,
        "status": r.status.value,
        "item_count": r.total_item_count,
        "declared_value_total": float(r.declared_value_total),
        "items": [
            {
                "id": item.id,
                "equipment_type": item.equipment_type.name,
                "manufacturer": item.manufacturer,
                "model": item.model,
                "serial_number": item.serial_number,
                "quantity": item.quantity,
            }
            for item in r.items
        ],
        "created_at": r.created_at.isoformat(),
    }


@api_v1_bp.route("/requests")
@require_api_key(scope="requests:read")
def requests_list():
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = CustomerEquipmentRequest.query.filter_by(user_id=g.api_user.id).order_by(
        CustomerEquipmentRequest.created_at.desc()
    )
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success([_serialize_request(r) for r in pagination.items], meta=pagination_meta(pagination))


@api_v1_bp.route("/requests/<int:request_id>")
@require_api_key(scope="requests:read")
def requests_detail(request_id):
    r = CustomerEquipmentRequest.query.filter_by(id=request_id, user_id=g.api_user.id).first()
    if r is None:
        return api_error("NOT_FOUND", "Request not found.", 404)
    return api_success(_serialize_request(r))


@api_v1_bp.route("/equipment/<int:item_id>")
@require_api_key(scope="requests:read")
def equipment_detail(item_id):
    from app.models.equipment import CustomerEquipmentItem

    item = CustomerEquipmentItem.query.join(CustomerEquipmentRequest).filter(
        CustomerEquipmentItem.id == item_id, CustomerEquipmentRequest.user_id == g.api_user.id
    ).first()
    if item is None:
        return api_error("NOT_FOUND", "Equipment item not found.", 404)
    return api_success(
        {
            "id": item.id,
            "manufacturer": item.manufacturer,
            "model": item.model,
            "serial_number": item.serial_number,
            "quantity": item.quantity,
            "declared_value": float(item.declared_value or 0),
        }
    )


@api_v1_bp.route("/invoices")
@require_api_key(scope="invoices:read")
def invoices_list():
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = Invoice.query.filter_by(user_id=g.api_user.id).order_by(Invoice.created_at.desc())
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [
            {
                "id": i.id, "invoice_number": i.invoice_number, "status": i.status.value,
                "total": float(i.total), "balance_due": float(i.balance_due),
            }
            for i in pagination.items
        ],
        meta=pagination_meta(pagination),
    )


@api_v1_bp.route("/payments")
@require_api_key(scope="payments:read")
def payments_list():
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = Payment.query.filter_by(user_id=g.api_user.id).order_by(Payment.created_at.desc())
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [
            {"id": p.id, "amount": float(p.amount), "status": p.status.value, "provider": p.provider}
            for p in pagination.items
        ],
        meta=pagination_meta(pagination),
    )


@api_v1_bp.route("/shipments")
@require_api_key(scope="requests:read")
def shipments_list():
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = (
        Shipment.query.join(CustomerEquipmentRequest)
        .filter(CustomerEquipmentRequest.user_id == g.api_user.id)
        .order_by(Shipment.created_at.desc())
    )
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [
            {
                "id": s.id, "shipment_number": s.shipment_number, "carrier": s.carrier,
                "tracking_number": s.tracking_number, "status": s.status.value,
            }
            for s in pagination.items
        ],
        meta=pagination_meta(pagination),
    )
