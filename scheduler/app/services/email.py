"""Sends email over SMTP, or captures it instead when MAIL_SUPPRESS_SEND is on.

Kept deliberately provider-agnostic per the plan's "SMTP or Resend/Postmark/
Mailgun/SES" options: this module only assumes it can hand off a rendered
message. Swapping to an HTTP-based provider later means changing
`send_email`'s body, not any of its callers in services/notifications.py.
"""

import logging
import smtplib
from email.message import EmailMessage

from flask import current_app

logger = logging.getLogger(__name__)

# Captures suppressed sends for local development and tests to inspect,
# e.g. `from app.services.email import OUTBOX`. Not persisted anywhere.
OUTBOX = []


def send_email(to_email, subject, html_body, text_body):
    message = EmailMessage()
    message["Subject"] = subject
    from_name = current_app.config.get("MAIL_FROM_NAME", "Scheduler")
    message["From"] = f"{from_name} <{current_app.config['MAIL_FROM']}>"
    message["To"] = to_email
    message.set_content(text_body)
    message.add_alternative(html_body, subtype="html")

    if current_app.config.get("MAIL_SUPPRESS_SEND"):
        OUTBOX.append(message)
        logger.info("MAIL_SUPPRESS_SEND is on — captured email to %s: %s", to_email, subject)
        return

    host = current_app.config["MAIL_SERVER"]
    port = current_app.config["MAIL_PORT"]
    username = current_app.config.get("MAIL_USERNAME")
    password = current_app.config.get("MAIL_PASSWORD")

    with smtplib.SMTP(host, port, timeout=10) as smtp:
        if current_app.config.get("MAIL_USE_TLS"):
            smtp.starttls()
        if username:
            smtp.login(username, password)
        smtp.send_message(message)
