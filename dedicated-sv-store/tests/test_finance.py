from decimal import Decimal

from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.models.server import Server, ServerStatus, InventoryStatus
from app.models.order import Order
from app.models.finance import Invoice, Payment, PaymentStatus, Coupon, DiscountType, SellerPayout
from app.payments.service import charge_invoice, refund_payment
from tests.conftest import login


def _make_seller_and_server(make_user, price=100):
    user = make_user(email="finseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=user.id, business_name="Acme", slug="acme-fin", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.commit()

    server = Server(
        seller_id=seller.id, title="Fin Server", slug="fin-server",
        cpu_summary="CPU", ram_summary="RAM", storage_summary="Storage", network_summary="Net",
        monthly_price=price, status=ServerStatus.PUBLISHED, inventory_status=InventoryStatus.AVAILABLE,
    )
    db.session.add(server)
    db.session.commit()
    return seller, server


def _checkout(client, make_user, email="finbuyer@example.com", server=None, coupon_code=None):
    buyer = make_user(email=email, password="Password123")
    login(client, email, "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    data = {"coupon_code": coupon_code} if coupon_code else {}
    client.post("/checkout", data=data)
    return buyer


def test_checkout_generates_invoice_with_tax(client, make_user):
    _, server = _make_seller_and_server(make_user, price=100)
    buyer = _checkout(client, make_user, server=server)

    order = Order.query.filter_by(user_id=buyer.id).first()
    invoice = Invoice.query.filter_by(order_id=order.id).first()
    assert invoice is not None
    assert invoice.subtotal == 100
    assert invoice.tax_amount == 20  # default 20% tax
    assert invoice.total == 120
    assert invoice.balance_due == 120


def test_paying_invoice_marks_order_paid_and_creates_payout(client, make_user, app):
    seller, server = _make_seller_and_server(make_user, price=100)
    buyer = _checkout(client, make_user, server=server)

    order = Order.query.filter_by(user_id=buyer.id).first()
    invoice = Invoice.query.filter_by(order_id=order.id).first()

    payment = charge_invoice(invoice, buyer)
    assert payment.status == PaymentStatus.COMPLETED

    db.session.refresh(order)
    db.session.refresh(invoice)
    assert invoice.balance_due == 0
    assert order.payment_status.value == "paid"
    assert order.status.value == "paid"

    payout = SellerPayout.query.filter_by(order_id=order.id).first()
    assert payout is not None
    assert payout.gross_amount == 100
    assert payout.net_amount == payout.gross_amount - payout.commission_amount


def test_refund_reverts_order_status(client, make_user):
    seller, server = _make_seller_and_server(make_user, price=50)
    buyer = _checkout(client, make_user, server=server)

    order = Order.query.filter_by(user_id=buyer.id).first()
    invoice = Invoice.query.filter_by(order_id=order.id).first()
    payment = charge_invoice(invoice, buyer)

    admin = make_user(email="finadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    success = refund_payment(payment, admin)
    assert success is True

    db.session.refresh(payment)
    db.session.refresh(order)
    assert payment.status == PaymentStatus.REFUNDED
    assert order.status.value == "refunded"


def test_coupon_applies_discount_at_checkout(client, make_user):
    _, server = _make_seller_and_server(make_user, price=200)
    coupon = Coupon(code="TENOFF", discount_type=DiscountType.PERCENT, value=10, is_active=True)
    db.session.add(coupon)
    db.session.commit()

    buyer = _checkout(client, make_user, server=server, coupon_code="tenoff")

    order = Order.query.filter_by(user_id=buyer.id).first()
    assert order.discount == 20  # 10% of 200
    assert order.subtotal == 200

    db.session.refresh(coupon)
    assert coupon.used_count == 1


def test_invalid_coupon_reports_error_but_still_checks_out(client, make_user):
    _, server = _make_seller_and_server(make_user, price=100)
    buyer = make_user(email="badcoupon@example.com", password="Password123")
    login(client, "badcoupon@example.com", "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})

    resp = client.post("/checkout", data={"coupon_code": "NOTREAL"}, follow_redirects=True)
    assert b"invalid or has expired" in resp.data

    order = Order.query.filter_by(user_id=buyer.id).first()
    assert order is not None
    assert order.discount == 0
