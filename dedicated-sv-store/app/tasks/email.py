import logging

logger = logging.getLogger(__name__)


def _get_app():
    from app import create_app

    return create_app()


def send_email_now(subject, recipients, html_body, text_body=None, sender=None):
    """Runs inside an RQ worker process (no Flask app context by default),
    so it builds its own app context to access Flask-Mail config."""
    app = _get_app()
    with app.app_context():
        from flask_mail import Message
        from app.extensions import mail

        msg = Message(
            subject=subject,
            recipients=recipients,
            html=html_body,
            body=text_body or "",
            sender=sender or app.config["MAIL_DEFAULT_SENDER"],
        )
        try:
            mail.send(msg)
        except Exception:
            logger.exception("Failed to send email to %s", recipients)
            raise


def queue_email(subject, recipients, html_body, text_body=None, sender=None):
    from app.tasks.queue import enqueue

    return enqueue(
        send_email_now,
        subject,
        recipients,
        html_body,
        text_body,
        sender,
        queue_name="emails",
    )
