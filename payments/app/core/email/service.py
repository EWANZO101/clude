"""Real email delivery via SMTP, replacing the Part 2 logging stub.

Same pattern as the Monzo bank provider and Companies House sync: a
documented no-op (falls back to logging) without real credentials at
deployment time, rather than a silent failure or a fake success. Configure
SMTP_HOST/SMTP_PORT/SMTP_USERNAME/SMTP_PASSWORD/SMTP_FROM_ADDRESS (and
optionally SMTP_USE_TLS, default true) via environment variables / .env
to enable real delivery.
"""
import logging
import os
import smtplib
from email.message import EmailMessage

logger = logging.getLogger(__name__)


def is_configured():
    return bool(os.environ.get("SMTP_HOST") and os.environ.get("SMTP_FROM_ADDRESS"))


def send_email(to_address, subject, body_text, body_html=None):
    """Sends an email. Returns True if actually sent via SMTP, False if it
    fell back to the console-log stub (not configured, or a send error —
    the caller shouldn't treat either as fatal since email is best-effort
    for a personal single-user app)."""
    if not is_configured():
        logger.info(f"[email:stub] To: {to_address} | Subject: {subject}\n{body_text}")
        return False

    host = os.environ.get("SMTP_HOST")
    port = int(os.environ.get("SMTP_PORT", "587"))
    username = os.environ.get("SMTP_USERNAME")
    password = os.environ.get("SMTP_PASSWORD")
    from_address = os.environ.get("SMTP_FROM_ADDRESS")
    use_tls = os.environ.get("SMTP_USE_TLS", "true").lower() != "false"

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = from_address
    msg["To"] = to_address
    msg.set_content(body_text)
    if body_html:
        msg.add_alternative(body_html, subtype="html")

    try:
        with smtplib.SMTP(host, port, timeout=10) as server:
            if use_tls:
                server.starttls()
            if username and password:
                server.login(username, password)
            server.send_message(msg)
        return True
    except Exception as e:
        logger.error(f"SMTP send failed, falling back to log: {e}")
        logger.info(f"[email:stub] To: {to_address} | Subject: {subject}\n{body_text}")
        return False


def send_verification_email(user, token):
    link = f"{os.environ.get('APP_BASE_URL', 'http://localhost:5000')}/verify-email/{token}"
    send_email(
        user.email, "Verify your email",
        f"Hi {user.name},\n\nVerify your email by visiting:\n{link}\n\nIf you didn't create this account, ignore this email.",
    )


def send_password_reset_email(user, token):
    link = f"{os.environ.get('APP_BASE_URL', 'http://localhost:5000')}/reset-password/{token}"
    send_email(
        user.email, "Reset your password",
        f"Hi {user.name},\n\nReset your password by visiting:\n{link}\n\nIf you didn't request this, ignore this email — your password won't change.",
    )
