"""Email dispatch. Runs in a background thread so request handlers never block.
If no SMTP_HOST is configured, emails are logged to stdout instead of sent —
keeps the platform fully functional out of the box without a mail server."""
import smtplib
import threading
from email.message import EmailMessage
from email.utils import formataddr
from flask import current_app


def _send_sync(app, to_addr, subject, html_body, text_body):
    with app.app_context():
        cfg = app.config
        host = cfg.get("SMTP_HOST")
        sender = formataddr((cfg["MAIL_SENDER_NAME"], cfg["MAIL_FROM"]))
        if not host:
            app.logger.info("[MAIL:console] To=%s | %s", to_addr, subject)
            app.logger.info("[MAIL:console] %s", text_body)
            return
        msg = EmailMessage()
        msg["Subject"] = subject
        msg["From"] = sender
        msg["To"] = to_addr
        msg.set_content(text_body or "")
        if html_body:
            msg.add_alternative(html_body, subtype="html")
        try:
            with smtplib.SMTP(host, cfg["SMTP_PORT"], timeout=20) as s:
                if cfg.get("SMTP_TLS"):
                    s.starttls()
                if cfg.get("SMTP_USER"):
                    s.login(cfg["SMTP_USER"], cfg["SMTP_PASS"])
                s.send_message(msg)
            app.logger.info("[MAIL:sent] To=%s | %s", to_addr, subject)
        except Exception as exc:  # noqa: BLE001
            app.logger.error("[MAIL:error] To=%s | %s | %s", to_addr, subject, exc)


def send_email(to_addr, subject, html_body, text_body=""):
    app = current_app._get_current_object()
    t = threading.Thread(
        target=_send_sync, args=(app, to_addr, subject, html_body, text_body), daemon=True
    )
    t.start()
