from datetime import timedelta

from app.extensions import db
from app.models.base import utcnow
from app.models.user import User, AccountType, EmailVerificationToken
from app.models.seller import SellerProfile, SellerStatus
from app.models.finance import Invoice, InvoiceStatus
from app.tasks.scheduled import mark_overdue_invoices, cleanup_expired_tokens


def test_security_headers_present(client):
    resp = client.get("/")
    assert resp.headers["X-Content-Type-Options"] == "nosniff"
    assert resp.headers["X-Frame-Options"] == "DENY"
    assert "default-src 'self'" in resp.headers["Content-Security-Policy"]
    assert "'unsafe-eval'" in resp.headers["Content-Security-Policy"]


def test_openapi_json_is_valid(client):
    resp = client.get("/api/v1/openapi.json")
    assert resp.status_code == 200
    spec = resp.get_json()
    assert spec["openapi"].startswith("3.")
    assert "/servers" in spec["paths"]
    assert "/orders" in spec["paths"]


def test_api_docs_page_renders(client):
    resp = client.get("/api/v1/docs")
    assert resp.status_code == 200
    assert b"swagger-ui" in resp.data


def test_mark_overdue_invoices(app, make_user):
    with app.app_context():
        user = make_user(email="overdue@example.com")
        invoice = Invoice(
            user_id=user.id, subtotal=100, tax_amount=0, total=100,
            status=InvoiceStatus.ISSUED, due_date=(utcnow() - timedelta(days=1)).date(),
        )
        db.session.add(invoice)
        db.session.commit()

        mark_overdue_invoices()

        db.session.refresh(invoice)
        assert invoice.status == InvoiceStatus.OVERDUE


def test_mark_overdue_invoices_leaves_current_ones_alone(app, make_user):
    with app.app_context():
        user = make_user(email="current@example.com")
        invoice = Invoice(
            user_id=user.id, subtotal=100, tax_amount=0, total=100,
            status=InvoiceStatus.ISSUED, due_date=(utcnow() + timedelta(days=5)).date(),
        )
        db.session.add(invoice)
        db.session.commit()

        mark_overdue_invoices()

        db.session.refresh(invoice)
        assert invoice.status == InvoiceStatus.ISSUED


def test_cleanup_expired_tokens(app, make_user):
    with app.app_context():
        user = make_user(email="tokencleanup@example.com")
        expired = EmailVerificationToken(user_id=user.id, expires_at=utcnow() - timedelta(hours=1))
        valid = EmailVerificationToken(user_id=user.id, expires_at=utcnow() + timedelta(hours=1))
        db.session.add_all([expired, valid])
        db.session.commit()
        valid_id = valid.id

        cleanup_expired_tokens()

        remaining = EmailVerificationToken.query.filter_by(user_id=user.id).all()
        assert len(remaining) == 1
        assert remaining[0].id == valid_id
