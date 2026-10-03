from flask import Blueprint, render_template, redirect, url_for, abort, flash, request
from flask_login import login_required, current_user

customer_bp = Blueprint("customer", __name__, template_folder="../templates/customer")


@customer_bp.before_request
@login_required
def require_login():
    return None


@customer_bp.route("/")
def dashboard():
    from app.models.order import Order, OrderStatus

    open_orders = Order.query.filter(
        Order.user_id == current_user.id,
        Order.status.notin_([OrderStatus.COMPLETED, OrderStatus.CANCELLED, OrderStatus.REFUNDED]),
    ).count()

    from app.models.finance import Invoice, InvoiceStatus

    outstanding_invoices = Invoice.query.filter(
        Invoice.user_id == current_user.id,
        Invoice.status.in_([InvoiceStatus.ISSUED, InvoiceStatus.PENDING, InvoiceStatus.OVERDUE, InvoiceStatus.PARTIALLY_PAID]),
    ).count()

    from app.models.equipment import CustomerEquipmentRequest, RequestStatus
    from app.models.shipping import Shipment, ShipmentStatus

    pending_requests = CustomerEquipmentRequest.query.filter(
        CustomerEquipmentRequest.user_id == current_user.id,
        CustomerEquipmentRequest.status.notin_([RequestStatus.COMPLETED, RequestStatus.REJECTED]),
    ).count()

    active_shipments = (
        Shipment.query.join(CustomerEquipmentRequest)
        .filter(
            CustomerEquipmentRequest.user_id == current_user.id,
            Shipment.status.notin_([ShipmentStatus.DELIVERED, ShipmentStatus.RETURNED]),
        )
        .count()
    )

    stats = {
        "active_servers": 0,
        "open_orders": open_orders,
        "pending_requests": pending_requests,
        "outstanding_invoices": outstanding_invoices,
        "shipments": active_shipments,
        "unread_messages": 0,
    }
    return render_template("customer/dashboard.html", stats=stats)


@customer_bp.route("/orders")
def orders():
    from app.models.order import Order

    order_list = Order.query.filter_by(user_id=current_user.id).order_by(Order.created_at.desc()).all()
    return render_template("customer/orders/list.html", orders=order_list)


@customer_bp.route("/orders/<int:order_id>")
def order_detail(order_id):
    from app.models.order import Order

    order = Order.query.filter_by(id=order_id, user_id=current_user.id).first()
    if order is None:
        abort(404)
    return render_template("customer/orders/detail.html", order=order)


@customer_bp.route("/orders/<int:order_id>/chat")
def order_chat(order_id):
    from app.models.order import Order
    from app.models.chat import ConversationContext
    from app.chat.service import get_or_create_conversation
    from app.extensions import db

    order = Order.query.filter_by(id=order_id, user_id=current_user.id).first()
    if order is None or order.seller_id is None:
        abort(404)

    conversation = get_or_create_conversation(
        ConversationContext.ORDER, order.id, f"Order {order.order_number}", [order.user_id],
    )
    db.session.commit()
    return redirect(url_for("customer.conversation_detail", conversation_id=conversation.id))


@customer_bp.route("/servers")
def servers():
    from app.models.order import Order, OrderItem, OrderItemType, OrderStatus

    items = (
        OrderItem.query.join(Order)
        .filter(
            Order.user_id == current_user.id,
            OrderItem.item_type == OrderItemType.SERVER,
            Order.status.notin_([OrderStatus.CANCELLED, OrderStatus.REFUNDED]),
        )
        .order_by(OrderItem.created_at.desc())
        .all()
    )
    return render_template("customer/servers.html", items=items)


@customer_bp.route("/equipment")
def equipment():
    from app.models.equipment import CustomerEquipmentItem, CustomerEquipmentRequest

    items = (
        CustomerEquipmentItem.query.join(CustomerEquipmentRequest)
        .filter(CustomerEquipmentRequest.user_id == current_user.id)
        .order_by(CustomerEquipmentItem.created_at.desc())
        .all()
    )
    return render_template("customer/equipment.html", items=items)


@customer_bp.route("/settings", methods=["GET", "POST"])
def settings():
    from app.extensions import db
    from app.customer.forms import AccountSettingsForm

    profile = current_user.customer_profile
    form = AccountSettingsForm(obj=current_user)

    if request.method == "GET" and profile:
        form.company_name.data = profile.company_name
        form.vat_number.data = profile.vat_number
        form.billing_address_line1.data = profile.billing_address_line1
        form.billing_address_line2.data = profile.billing_address_line2
        form.billing_city.data = profile.billing_city
        form.billing_region.data = profile.billing_region
        form.billing_postal_code.data = profile.billing_postal_code
        form.billing_country.data = profile.billing_country
        form.marketing_opt_in.data = profile.marketing_opt_in

    if form.validate_on_submit():
        current_user.first_name = form.first_name.data
        current_user.last_name = form.last_name.data
        current_user.phone = form.phone.data

        if profile is None:
            from app.models.customer import CustomerProfile

            profile = CustomerProfile(user_id=current_user.id)
            db.session.add(profile)

        profile.company_name = form.company_name.data
        profile.vat_number = form.vat_number.data
        profile.billing_address_line1 = form.billing_address_line1.data
        profile.billing_address_line2 = form.billing_address_line2.data
        profile.billing_city = form.billing_city.data
        profile.billing_region = form.billing_region.data
        profile.billing_postal_code = form.billing_postal_code.data
        profile.billing_country = form.billing_country.data
        profile.marketing_opt_in = form.marketing_opt_in.data

        db.session.commit()
        flash("Account settings saved.", "success")
        return redirect(url_for("customer.settings"))

    return render_template("customer/settings.html", form=form)


@customer_bp.route("/browse")
def browse():
    return redirect(url_for("marketplace.servers"))


@customer_bp.route("/build")
def build():
    return redirect(url_for("marketplace.build_server"))


@customer_bp.route("/configurations")
def configurations():
    from app.models.configuration import ServerConfiguration

    configs = (
        ServerConfiguration.query.filter_by(user_id=current_user.id)
        .order_by(ServerConfiguration.created_at.desc())
        .all()
    )
    return render_template("customer/configurations.html", configurations=configs)


@customer_bp.route("/invoices")
def invoices():
    from app.models.finance import Invoice

    invoice_list = Invoice.query.filter_by(user_id=current_user.id).order_by(Invoice.created_at.desc()).all()
    return render_template("customer/invoices/list.html", invoices=invoice_list)


@customer_bp.route("/invoices/<int:invoice_id>", methods=["GET", "POST"])
def invoice_detail(invoice_id):
    from flask import request
    from app.models.finance import Invoice
    from app.payments.service import charge_invoice

    invoice = Invoice.query.filter_by(id=invoice_id, user_id=current_user.id).first()
    if invoice is None:
        abort(404)

    if request.method == "POST":
        if invoice.balance_due <= 0:
            flash("This invoice is already paid.", "info")
        else:
            payment = charge_invoice(invoice, current_user)
            if payment.status.value == "completed":
                flash("Payment successful.", "success")
            else:
                flash("Payment failed. Please try again.", "error")
        return redirect(url_for("customer.invoice_detail", invoice_id=invoice.id))

    return render_template("customer/invoices/detail.html", invoice=invoice)


@customer_bp.route("/payments")
def payments():
    from app.models.finance import Payment

    payment_list = (
        Payment.query.filter_by(user_id=current_user.id).order_by(Payment.created_at.desc()).all()
    )
    return render_template("customer/payments.html", payments=payment_list)


@customer_bp.route("/favourites")
def favourites():
    from app.models.server import Favourite

    favs = (
        Favourite.query.filter_by(user_id=current_user.id)
        .order_by(Favourite.created_at.desc())
        .all()
    )
    return render_template("customer/favourites.html", favourites=favs)


from app.equipment.customer_views import register_customer_equipment_views  # noqa: E402
from app.shipping.customer_views import register_customer_shipping_views  # noqa: E402
from app.chat.customer_views import register_customer_chat_views  # noqa: E402
from app.support.customer_views import register_customer_support_views  # noqa: E402

register_customer_equipment_views(customer_bp)
register_customer_shipping_views(customer_bp)
register_customer_chat_views(customer_bp)
register_customer_support_views(customer_bp)
