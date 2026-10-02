from flask import request, g

from app.api.v1 import api_v1_bp
from app.api.v1.helpers import api_success, api_error, pagination_meta
from app.api.v1.auth import require_api_key
from app.models.user import User, AccountType
from app.models.seller import SellerProfile


def _require_admin():
    if g.api_user.account_type != AccountType.ADMIN:
        return api_error("FORBIDDEN", "This endpoint requires an admin API key.", 403)
    return None


@api_v1_bp.route("/customers")
@require_api_key(scope="admin:read")
def customers_list():
    denied = _require_admin()
    if denied:
        return denied
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = User.query.filter_by(account_type=AccountType.CUSTOMER).order_by(User.created_at.desc())
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [{"id": u.id, "email": u.email, "full_name": u.full_name, "is_active": u.is_active} for u in pagination.items],
        meta=pagination_meta(pagination),
    )


@api_v1_bp.route("/sellers")
@require_api_key(scope="admin:read")
def sellers_list():
    denied = _require_admin()
    if denied:
        return denied
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = SellerProfile.query.order_by(SellerProfile.created_at.desc())
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [
            {"id": s.id, "business_name": s.business_name, "status": s.status.value}
            for s in pagination.items
        ],
        meta=pagination_meta(pagination),
    )
