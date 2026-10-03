from flask import request

from app.extensions import db
from app.api.v1 import api_v1_bp
from app.api.v1.helpers import api_success, api_error, pagination_meta
from app.api.v1.auth import require_api_key
from app.models.server import Server, ServerStatus, ServerLocation
from app.models.seller import SellerProfile
from app.utils.helpers import generate_unique_slug


def _serialize_server(s):
    return {
        "id": s.id,
        "title": s.title,
        "slug": s.slug,
        "manufacturer": s.manufacturer,
        "model": s.model,
        "cpu_summary": s.cpu_summary,
        "ram_summary": s.ram_summary,
        "storage_summary": s.storage_summary,
        "gpu_summary": s.gpu_summary,
        "network_summary": s.network_summary,
        "monthly_price": float(s.monthly_price or 0),
        "one_time_price": float(s.one_time_price or 0) if s.one_time_price else None,
        "setup_fee": float(s.setup_fee or 0) if s.setup_fee else None,
        "currency": s.currency,
        "status": s.status.value,
        "inventory_status": s.inventory_status.value,
        "seller_id": s.seller_id,
        "location": {
            "country": s.location.country, "city": s.location.city,
            "datacenter": s.location.datacenter_name,
        } if s.location else None,
    }


@api_v1_bp.route("/servers")
def servers_list():
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = Server.query.filter_by(status=ServerStatus.PUBLISHED, is_active=True).order_by(Server.created_at.desc())
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [_serialize_server(s) for s in pagination.items], meta=pagination_meta(pagination)
    )


@api_v1_bp.route("/servers/<int:server_id>")
def servers_detail(server_id):
    server = db.session.get(Server, server_id)
    if server is None or server.status != ServerStatus.PUBLISHED:
        return api_error("NOT_FOUND", "Server not found.", 404)
    return api_success(_serialize_server(server))


@api_v1_bp.route("/servers", methods=["POST"])
@require_api_key(scope="servers:write")
def servers_create():
    from flask import g

    seller = SellerProfile.query.filter_by(user_id=g.api_user.id).first()
    if seller is None:
        return api_error("FORBIDDEN", "API key owner is not a seller.", 403)

    payload = request.get_json(silent=True) or {}
    required = ["title", "cpu_summary", "ram_summary", "storage_summary", "network_summary", "monthly_price"]
    missing = [f for f in required if not payload.get(f)]
    if missing:
        return api_error("VALIDATION_ERROR", f"Missing required fields: {', '.join(missing)}.", 400)

    server = Server(
        seller_id=seller.id,
        slug=generate_unique_slug(Server, payload["title"]),
        title=payload["title"],
        cpu_summary=payload["cpu_summary"],
        ram_summary=payload["ram_summary"],
        storage_summary=payload["storage_summary"],
        network_summary=payload["network_summary"],
        monthly_price=payload["monthly_price"],
        status=ServerStatus.DRAFT,
    )
    db.session.add(server)
    db.session.commit()

    from app.api.v1.webhooks import dispatch_webhook

    dispatch_webhook("server.created", {"server_id": server.id, "seller_id": seller.id})
    return api_success(_serialize_server(server), status=201)


@api_v1_bp.route("/servers/<int:server_id>", methods=["PUT"])
@require_api_key(scope="servers:write")
def servers_update(server_id):
    from flask import g

    server = db.session.get(Server, server_id)
    if server is None:
        return api_error("NOT_FOUND", "Server not found.", 404)
    seller = SellerProfile.query.filter_by(user_id=g.api_user.id).first()
    if seller is None or server.seller_id != seller.id:
        return api_error("FORBIDDEN", "You do not own this server.", 403)

    payload = request.get_json(silent=True) or {}
    for field_name in ("title", "cpu_summary", "ram_summary", "storage_summary", "network_summary", "monthly_price"):
        if field_name in payload:
            setattr(server, field_name, payload[field_name])
    db.session.commit()

    from app.api.v1.webhooks import dispatch_webhook

    dispatch_webhook("server.updated", {"server_id": server.id})
    return api_success(_serialize_server(server))


@api_v1_bp.route("/servers/<int:server_id>", methods=["DELETE"])
@require_api_key(scope="servers:write")
def servers_delete(server_id):
    from flask import g

    server = db.session.get(Server, server_id)
    if server is None:
        return api_error("NOT_FOUND", "Server not found.", 404)
    seller = SellerProfile.query.filter_by(user_id=g.api_user.id).first()
    if seller is None or server.seller_id != seller.id:
        return api_error("FORBIDDEN", "You do not own this server.", 403)

    server.is_active = False
    db.session.commit()
    return api_success({"deleted": True})


@api_v1_bp.route("/inventory")
@require_api_key(scope="servers:read")
def inventory():
    from flask import g

    seller = SellerProfile.query.filter_by(user_id=g.api_user.id).first()
    if seller is None:
        return api_error("FORBIDDEN", "API key owner is not a seller.", 403)
    servers = Server.query.filter_by(seller_id=seller.id).all()
    return api_success(
        [{"id": s.id, "title": s.title, "inventory_status": s.inventory_status.value} for s in servers]
    )
