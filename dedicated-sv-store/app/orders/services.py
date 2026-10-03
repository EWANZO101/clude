from collections import defaultdict
from datetime import timedelta
from decimal import Decimal

from app.extensions import db
from app.models.base import utcnow
from app.models.server import Server
from app.models.order import Order, OrderItem, CartItem, OrderItemType, OrderStatus
from app.models.finance import Invoice, InvoiceItem, InvoiceStatus, Coupon, Discount
from app.models.settings import SystemSetting
from app.utils.helpers import log_audit


def get_cart_items(user_id):
    return CartItem.query.filter_by(user_id=user_id).order_by(CartItem.created_at).all()


def cart_grouped_by_seller(user_id):
    """Returns dict: seller_id_or_None -> list[CartItem]. None groups
    platform-fulfilled items (custom configurations have no marketplace seller)."""
    groups = defaultdict(list)
    for item in get_cart_items(user_id):
        groups[item.resolve_seller_id()].append(item)
    return groups


def cart_line(item):
    unit_price = Decimal(str(item.resolve_monthly_price() or 0))
    setup_fee = Decimal(str(item.resolve_setup_fee() or 0))
    return {
        "item": item,
        "title": item.resolve_title(),
        "unit_price": unit_price,
        "setup_fee": setup_fee,
        "quantity": item.quantity,
        "line_total": unit_price * item.quantity,
    }


def cart_summary(user_id):
    items = get_cart_items(user_id)
    lines = [cart_line(i) for i in items]
    subtotal = sum((l["line_total"] for l in lines), Decimal("0"))
    setup_total = sum((l["setup_fee"] * l["item"].quantity for l in lines), Decimal("0"))
    return {"lines": lines, "subtotal": subtotal, "setup_total": setup_total}


def find_valid_coupon(code):
    if not code:
        return None
    coupon = Coupon.query.filter_by(code=code.strip().upper()).first()
    if coupon and coupon.is_valid():
        return coupon
    return None


class CheckoutResult:
    def __init__(self):
        self.orders = []
        self.errors = []


def _generate_invoice_for_order(order, discount_amount=Decimal("0")):
    tax_rate = Decimal(str(SystemSetting.get("default_tax_rate", 20)))
    taxable_amount = order.subtotal - discount_amount
    tax_amount = (taxable_amount * tax_rate / 100).quantize(Decimal("0.01"))

    order.discount = discount_amount
    order.tax = tax_amount
    order.total = order.subtotal - discount_amount + tax_amount + order.shipping

    due_days = int(SystemSetting.get("invoice_due_days", 14))
    customer_profile = order.user.customer_profile

    invoice = Invoice(
        user_id=order.user_id,
        order_id=order.id,
        billing_name=order.user.full_name,
        billing_address_line1=customer_profile.billing_address_line1 if customer_profile else None,
        billing_city=customer_profile.billing_city if customer_profile else None,
        billing_region=customer_profile.billing_region if customer_profile else None,
        billing_postal_code=customer_profile.billing_postal_code if customer_profile else None,
        billing_country=customer_profile.billing_country if customer_profile else None,
        subtotal=order.subtotal,
        tax_rate=tax_rate,
        tax_amount=tax_amount,
        discount_amount=discount_amount,
        shipping_amount=order.shipping,
        total=order.total,
        currency=order.currency,
        status=InvoiceStatus.ISSUED,
        due_date=(utcnow() + timedelta(days=due_days)).date(),
    )
    db.session.add(invoice)
    db.session.flush()

    for item in order.items:
        db.session.add(
            InvoiceItem(
                invoice_id=invoice.id,
                description=item.title_snapshot,
                quantity=item.quantity,
                unit_price=item.unit_monthly_price,
                line_total=item.line_total,
            )
        )
    if order.setup_total:
        db.session.add(
            InvoiceItem(
                invoice_id=invoice.id, description="Setup fee",
                quantity=1, unit_price=order.setup_total, line_total=order.setup_total,
            )
        )
    return invoice


def checkout(user_id, coupon_code=None):
    """Groups the user's cart by seller (None = platform-fulfilled custom
    builds) and creates one Order (and matching Invoice) per group.
    Marketplace servers are atomically reserved via Server.try_reserve so two
    customers can't buy the same physical server; any item that loses that
    race is reported as an error and left in the cart rather than silently
    dropped. An optional coupon is applied to whichever order is created
    first (simplification for multi-seller carts)."""
    result = CheckoutResult()
    groups = cart_grouped_by_seller(user_id)
    if not groups:
        result.errors.append("Your cart is empty.")
        return result

    coupon = find_valid_coupon(coupon_code)
    if coupon_code and not coupon:
        result.errors.append("That coupon code is invalid or has expired.")

    coupon_applied = False

    for seller_id, cart_items in groups.items():
        order = Order(user_id=user_id, seller_id=seller_id, status=OrderStatus.PENDING)
        db.session.add(order)
        db.session.flush()

        subtotal = Decimal("0")
        setup_total = Decimal("0")
        items_added = 0
        cart_items_to_remove = []

        for cart_item in cart_items:
            if cart_item.item_type == OrderItemType.SERVER:
                if not Server.try_reserve(cart_item.server_id):
                    result.errors.append(
                        f"{cart_item.resolve_title()} is no longer available and was removed from your cart."
                    )
                    cart_items_to_remove.append(cart_item)
                    continue

            unit_price = Decimal(str(cart_item.resolve_monthly_price() or 0))
            setup_fee = Decimal(str(cart_item.resolve_setup_fee() or 0))
            line_total = unit_price * cart_item.quantity

            db.session.add(
                OrderItem(
                    order_id=order.id,
                    item_type=cart_item.item_type,
                    server_id=cart_item.server_id,
                    configuration_id=cart_item.configuration_id,
                    title_snapshot=cart_item.resolve_title(),
                    unit_monthly_price=unit_price,
                    unit_setup_fee=setup_fee,
                    quantity=cart_item.quantity,
                    line_total=line_total,
                )
            )
            subtotal += line_total
            setup_total += setup_fee * cart_item.quantity
            items_added += 1
            cart_items_to_remove.append(cart_item)

        if items_added == 0:
            db.session.delete(order)
            continue

        order.subtotal = subtotal
        order.setup_total = setup_total

        discount_amount = Decimal("0")
        if coupon and not coupon_applied:
            discount_amount = min(coupon.compute_discount(subtotal), subtotal)
            coupon.used_count += 1
            db.session.add(Discount(order_id=order.id, coupon_id=coupon.id, amount=discount_amount))
            coupon_applied = True

        invoice = _generate_invoice_for_order(order, discount_amount)
        order.set_status(OrderStatus.AWAITING_PAYMENT, note=f"Order created; invoice {invoice.invoice_number} issued")

        for cart_item in cart_items_to_remove:
            db.session.delete(cart_item)

        log_audit("order.created", "Order", order.id, None, {"total": str(order.total)})

        from app.api.v1.webhooks import dispatch_webhook

        dispatch_webhook("order.created", {"order_id": order.id, "order_number": order.order_number})

        result.orders.append(order)

    db.session.commit()
    return result
