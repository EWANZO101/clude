from flask import Blueprint, render_template, request, redirect, url_for, flash, jsonify
from flask_login import current_user, login_required

from app.extensions import db
from app.models.server import Server, ServerStatus, InventoryStatus, Category, Favourite
from app.models.seller import SellerProfile
from app.utils.helpers import paginate_query

marketplace_bp = Blueprint("marketplace", __name__, template_folder="../templates/marketplace")


@marketplace_bp.route("/")
def index():
    featured = (
        Server.query.filter_by(status=ServerStatus.PUBLISHED, is_active=True)
        .filter(Server.inventory_status == InventoryStatus.AVAILABLE)
        .order_by(Server.created_at.desc())
        .limit(6)
        .all()
    )
    return render_template("marketplace/index.html", featured=featured)


def _base_query():
    return Server.query.filter_by(status=ServerStatus.PUBLISHED, is_active=True)


def _apply_filters(query, args):
    if args.get("q"):
        like = f"%{args['q'].strip()}%"
        query = query.filter(
            db.or_(Server.title.ilike(like), Server.cpu_summary.ilike(like), Server.description.ilike(like))
        )
    if args.get("category"):
        query = query.join(Category, isouter=True).filter(Category.slug == args["category"])
    if args.get("seller"):
        query = query.join(SellerProfile).filter(SellerProfile.slug == args["seller"])
    if args.get("country"):
        from app.models.server import ServerLocation

        query = query.join(ServerLocation).filter(ServerLocation.country == args["country"].upper())
    if args.get("min_price"):
        query = query.filter(Server.monthly_price >= args["min_price"])
    if args.get("max_price"):
        query = query.filter(Server.monthly_price <= args["max_price"])
    if args.get("min_cores"):
        query = query.filter(Server.cpu_cores >= args["min_cores"])
    if args.get("min_ram"):
        query = query.filter(Server.ram_capacity_gb >= args["min_ram"])
    if args.get("min_storage"):
        query = query.filter(Server.storage_capacity_gb >= args["min_storage"])
    if args.get("storage_type"):
        query = query.filter(Server.storage_type == args["storage_type"])
    if args.get("gpu_only") == "1":
        query = query.filter(Server.gpu_count > 0)
    if args.get("min_bandwidth"):
        query = query.filter(Server.bandwidth_mbps >= args["min_bandwidth"])
    if args.get("availability_only") == "1":
        query = query.filter(Server.inventory_status == InventoryStatus.AVAILABLE)
    return query


SORT_OPTIONS = {
    "price_asc": Server.monthly_price.asc(),
    "price_desc": Server.monthly_price.desc(),
    "newest": Server.created_at.desc(),
    "cores_desc": Server.cpu_cores.desc(),
}


@marketplace_bp.route("/servers")
def servers():
    args = {
        "q": request.args.get("q", "").strip(),
        "category": request.args.get("category", ""),
        "seller": request.args.get("seller", ""),
        "country": request.args.get("country", ""),
        "min_price": request.args.get("min_price", type=float),
        "max_price": request.args.get("max_price", type=float),
        "min_cores": request.args.get("min_cores", type=int),
        "min_ram": request.args.get("min_ram", type=int),
        "min_storage": request.args.get("min_storage", type=int),
        "storage_type": request.args.get("storage_type", ""),
        "gpu_only": "1" if request.args.get("gpu_only") == "1" else "",
        "min_bandwidth": request.args.get("min_bandwidth", type=int),
        "availability_only": "1" if request.args.get("availability_only", "1") == "1" else "",
    }
    sort = request.args.get("sort", "newest")
    page = request.args.get("page", 1, type=int)

    query = _apply_filters(_base_query(), args)
    query = query.order_by(SORT_OPTIONS.get(sort, SORT_OPTIONS["newest"]))
    pagination = paginate_query(query, page, 12)

    favourite_ids = set()
    if current_user.is_authenticated:
        favourite_ids = {
            f.server_id for f in Favourite.query.filter_by(user_id=current_user.id).all()
        }

    categories = Category.query.filter_by(is_active=True).order_by(Category.sort_order, Category.name).all()

    return render_template(
        "marketplace/servers.html",
        pagination=pagination,
        args=args,
        sort=sort,
        categories=categories,
        favourite_ids=favourite_ids,
    )


@marketplace_bp.route("/servers/<slug>")
def server_detail(slug):
    server = Server.query.filter_by(slug=slug, status=ServerStatus.PUBLISHED, is_active=True).first_or_404()
    is_favourited = False
    if current_user.is_authenticated:
        is_favourited = (
            Favourite.query.filter_by(user_id=current_user.id, server_id=server.id).first() is not None
        )
    similar = (
        _base_query()
        .filter(Server.id != server.id, Server.category_id == server.category_id)
        .limit(4)
        .all()
    )
    return render_template(
        "marketplace/server_detail.html", server=server, is_favourited=is_favourited, similar=similar
    )


@marketplace_bp.route("/compare")
def compare():
    ids = [int(i) for i in request.args.getlist("id") if i.isdigit()][:4]
    compared = _base_query().filter(Server.id.in_(ids)).all() if ids else []
    compared.sort(key=lambda s: ids.index(s.id))
    return render_template("marketplace/compare.html", servers=compared)


@marketplace_bp.route("/servers/<int:server_id>/favourite", methods=["POST"])
@login_required
def toggle_favourite(server_id):
    server = db.session.get(Server, server_id)
    if server is None:
        return jsonify({"success": False, "error": {"code": "NOT_FOUND", "message": "Server not found."}}), 404

    existing = Favourite.query.filter_by(user_id=current_user.id, server_id=server_id).first()
    if existing:
        db.session.delete(existing)
        favourited = False
    else:
        db.session.add(Favourite(user_id=current_user.id, server_id=server_id))
        favourited = True
    db.session.commit()

    if request.accept_mimetypes.best == "application/json" or request.headers.get("X-Requested-With") == "XMLHttpRequest":
        return jsonify({"success": True, "data": {"favourited": favourited}})

    flash("Added to favourites." if favourited else "Removed from favourites.", "success")
    return redirect(request.referrer or url_for("marketplace.servers"))


from app.marketplace.builder_routes import register_builder_routes  # noqa: E402

register_builder_routes(marketplace_bp)
