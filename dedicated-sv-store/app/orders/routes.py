from flask import Blueprint, render_template, redirect, url_for, request, flash, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models.server import Server, ServerStatus, InventoryStatus
from app.models.configuration import ServerConfiguration
from app.models.order import CartItem, OrderItemType
from app.orders.services import cart_summary, checkout

orders_bp = Blueprint("orders", __name__, template_folder="../templates/orders")


@orders_bp.route("/cart")
@login_required
def cart():
    summary = cart_summary(current_user.id)
    return render_template("orders/cart.html", summary=summary)


@orders_bp.route("/cart/add", methods=["POST"])
@login_required
def cart_add():
    item_type = request.form.get("item_type")
    item_id = request.form.get("item_id", type=int)
    quantity = max(1, request.form.get("quantity", 1, type=int))

    if item_type == OrderItemType.SERVER.value:
        server = db.session.get(Server, item_id)
        if not server or server.status != ServerStatus.PUBLISHED or not server.is_active:
            flash("That server is not available.", "error")
            return redirect(request.referrer or url_for("marketplace.servers"))
        if server.inventory_status != InventoryStatus.AVAILABLE:
            flash("That server is no longer available.", "error")
            return redirect(request.referrer or url_for("marketplace.servers"))

        existing = CartItem.query.filter_by(
            user_id=current_user.id, item_type=OrderItemType.SERVER, server_id=server.id
        ).first()
        if existing:
            flash("That server is already in your cart.", "info")
        else:
            db.session.add(
                CartItem(user_id=current_user.id, item_type=OrderItemType.SERVER, server_id=server.id, quantity=1)
            )
            db.session.commit()
            flash("Added to cart.", "success")

    elif item_type == OrderItemType.CONFIGURATION.value:
        config = db.session.get(ServerConfiguration, item_id)
        if not config or config.user_id != current_user.id:
            abort(404)
        existing = CartItem.query.filter_by(
            user_id=current_user.id, item_type=OrderItemType.CONFIGURATION, configuration_id=config.id
        ).first()
        if existing:
            flash("That configuration is already in your cart.", "info")
        else:
            db.session.add(
                CartItem(
                    user_id=current_user.id, item_type=OrderItemType.CONFIGURATION,
                    configuration_id=config.id, quantity=quantity,
                )
            )
            db.session.commit()
            flash("Added to cart.", "success")
    else:
        flash("Invalid item.", "error")

    return redirect(request.referrer or url_for("orders.cart"))


@orders_bp.route("/cart/<int:cart_item_id>/remove", methods=["POST"])
@login_required
def cart_remove(cart_item_id):
    item = db.session.get(CartItem, cart_item_id)
    if item is None or item.user_id != current_user.id:
        abort(404)
    db.session.delete(item)
    db.session.commit()
    flash("Removed from cart.", "success")
    return redirect(url_for("orders.cart"))


@orders_bp.route("/checkout", methods=["GET", "POST"])
@login_required
def checkout_view():
    if request.method == "GET":
        summary = cart_summary(current_user.id)
        return render_template("orders/checkout.html", summary=summary)

    result = checkout(current_user.id, coupon_code=request.form.get("coupon_code"))
    for error in result.errors:
        flash(error, "error")
    if result.orders:
        order_numbers = ", ".join(o.order_number for o in result.orders)
        flash(f"Order(s) created: {order_numbers}. Proceed to payment from your invoices.", "success")
        return redirect(url_for("customer.orders"))

    return redirect(url_for("orders.cart"))
