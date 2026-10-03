from flask import render_template, redirect, url_for, request, flash, abort
from flask_login import current_user

from app.extensions import db
from app.models.order import Order, FulfilmentStatus
from app.utils.helpers import log_audit, paginate_query
from app.seller.server_views import _active_seller_or_redirect


def register_seller_order_views(seller_bp):
    @seller_bp.route("/orders")
    def orders():
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        page = request.args.get("page", 1, type=int)
        query = Order.query.filter_by(seller_id=profile.id).order_by(Order.created_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("seller/orders/list.html", pagination=pagination)

    @seller_bp.route("/orders/<int:order_id>", methods=["GET", "POST"])
    def order_detail(order_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        order = Order.query.filter_by(id=order_id, seller_id=profile.id).first()
        if order is None:
            abort(404)

        if request.method == "POST":
            new_status = request.form.get("fulfilment_status")
            if new_status in FulfilmentStatus._value2member_map_:
                old = order.fulfilment_status
                order.fulfilment_status = FulfilmentStatus(new_status)
                log_audit(
                    "order.fulfilment_status_changed", "Order", order.id,
                    {"fulfilment_status": old.value}, {"fulfilment_status": new_status},
                )
                db.session.commit()
                flash("Fulfilment status updated.", "success")
            return redirect(url_for("seller.order_detail", order_id=order.id))

        return render_template("seller/orders/detail.html", order=order, statuses=list(FulfilmentStatus))
