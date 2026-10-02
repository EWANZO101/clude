from flask import request, g

from app.extensions import db
from app.api.v1 import api_v1_bp
from app.api.v1.helpers import api_success, api_error, pagination_meta
from app.api.v1.auth import require_api_key
from app.models.order import Order, OrderStatus
from app.models.user import AccountType
from app.models.seller import SellerProfile


def _serialize_order(o):
    return {
        "id": o.id,
        "order_number": o.order_number,
        "status": o.status.value,
        "payment_status": o.payment_status.value,
        "fulfilment_status": o.fulfilment_status.value,
        "subtotal": float(o.subtotal),
        "total": float(o.total),
        "currency": o.currency,
        "items": [
            {"title": i.title_snapshot, "quantity": i.quantity, "line_total": float(i.line_total)}
            for i in o.items
        ],
        "created_at": o.created_at.isoformat(),
    }


def _scoped_orders_query():
    if g.api_user.account_type == AccountType.SELLER:
        seller = SellerProfile.query.filter_by(user_id=g.api_user.id).first()
        if seller is None:
            return None
        return Order.query.filter_by(seller_id=seller.id)
    return Order.query.filter_by(user_id=g.api_user.id)


@api_v1_bp.route("/orders")
@require_api_key(scope="orders:read")
def orders_list():
    query = _scoped_orders_query()
    if query is None:
        return api_error("FORBIDDEN", "API key owner is not a seller.", 403)

    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    pagination = query.order_by(Order.created_at.desc()).paginate(page=page, per_page=per_page, error_out=False)
    return api_success([_serialize_order(o) for o in pagination.items], meta=pagination_meta(pagination))


@api_v1_bp.route("/orders/<int:order_id>")
@require_api_key(scope="orders:read")
def orders_detail(order_id):
    query = _scoped_orders_query()
    if query is None:
        return api_error("FORBIDDEN", "API key owner is not a seller.", 403)
    order = query.filter_by(id=order_id).first()
    if order is None:
        return api_error("NOT_FOUND", "Order not found.", 404)
    return api_success(_serialize_order(order))


@api_v1_bp.route("/orders/<int:order_id>/status", methods=["POST"])
@require_api_key(scope="orders:write")
def orders_update_status(order_id):
    from app.models.order import FulfilmentStatus

    seller = SellerProfile.query.filter_by(user_id=g.api_user.id).first()
    if seller is None:
        return api_error("FORBIDDEN", "API key owner is not a seller.", 403)
    order = Order.query.filter_by(id=order_id, seller_id=seller.id).first()
    if order is None:
        return api_error("NOT_FOUND", "Order not found.", 404)

    payload = request.get_json(silent=True) or {}
    new_status = payload.get("fulfilment_status")
    if new_status not in FulfilmentStatus._value2member_map_:
        return api_error("VALIDATION_ERROR", "Invalid fulfilment_status.", 400)

    order.fulfilment_status = FulfilmentStatus(new_status)
    db.session.commit()
    return api_success(_serialize_order(order))
