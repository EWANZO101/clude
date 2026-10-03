"""
Minimal SMTP sender for verification/reset emails.

Uses smtplib directly (not Flask-Mail) so the SMTP host/port/auth can be
read fresh from admin-configured Settings at send time, not locked in at
app-init time.

If no mail server is configured, send_email() returns False instead of
raising — callers fall back to surfacing the link directly (as they did
before this was wired up), so local/dev use without SMTP creds keeps working.
"""

import smtplib
from email.mime.text import MIMEText

from flask import current_app


def _mail_settings():
    """Admin-configured Settings take priority; falls back to app.config
    (i.e. the .env-provided defaults) if a Setting hasn't been set."""
    from app.models import Setting

    server = Setting.get("mail_server") or current_app.config.get("MAIL_SERVER", "")
    sender = Setting.get("mail_from") or current_app.config.get("MAIL_DEFAULT_SENDER", "")
    return {
        "server": server,
        "port": current_app.config.get("MAIL_PORT", 587),
        "use_tls": current_app.config.get("MAIL_USE_TLS", True),
        "username": current_app.config.get("MAIL_USERNAME", ""),
        "password": current_app.config.get("MAIL_PASSWORD", ""),
        "sender": sender,
    }


def mail_is_configured() -> bool:
    settings = _mail_settings()
    return bool(settings["server"] and settings["sender"])


def send_email(to: str, subject: str, body_text: str) -> bool:
    """Returns True if the email was actually sent, False if mail isn't
    configured (caller should fall back to another delivery method)."""
    settings = _mail_settings()
    if not settings["server"] or not settings["sender"]:
        return False

    msg = MIMEText(body_text)
    msg["Subject"] = subject
    msg["From"] = settings["sender"]
    msg["To"] = to

    try:
        with smtplib.SMTP(settings["server"], settings["port"], timeout=15) as smtp:
            if settings["use_tls"]:
                smtp.starttls()
            if settings["username"]:
                smtp.login(settings["username"], settings["password"])
            smtp.sendmail(settings["sender"], [to], msg.as_string())
        return True
    except (smtplib.SMTPException, OSError) as e:
        current_app.logger.error(f"Failed to send email to {to}: {e}")
        return False
