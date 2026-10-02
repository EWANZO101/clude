import logging

logger = logging.getLogger(__name__)


def mark_overdue_invoices():
    """Runs in an RQ worker process; builds its own app context."""
    from app import create_app
    from app.extensions import db
    from app.models.base import utcnow
    from app.models.finance import Invoice, InvoiceStatus

    app = create_app()
    with app.app_context():
        today = utcnow().date()
        overdue = Invoice.query.filter(
            Invoice.due_date < today,
            Invoice.status.in_([InvoiceStatus.ISSUED, InvoiceStatus.PENDING, InvoiceStatus.PARTIALLY_PAID]),
        ).all()
        for invoice in overdue:
            invoice.status = InvoiceStatus.OVERDUE
        db.session.commit()
        logger.info("Marked %d invoice(s) overdue", len(overdue))


def cleanup_expired_tokens():
    """Runs in an RQ worker process; builds its own app context."""
    from app import create_app
    from app.extensions import db
    from app.models.base import utcnow
    from app.models.user import EmailVerificationToken, PasswordResetToken

    app = create_app()
    with app.app_context():
        now = utcnow()
        deleted = (
            EmailVerificationToken.query.filter(EmailVerificationToken.expires_at < now).delete()
            + PasswordResetToken.query.filter(PasswordResetToken.expires_at < now).delete()
        )
        db.session.commit()
        logger.info("Cleaned up %d expired token(s)", deleted)
