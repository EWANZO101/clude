import smtplib
from email.message import EmailMessage
from flask import current_app


def send_email(to: str, subject: str, body: str):
    """Sends plain-text email via SMTP if configured, otherwise logs it.

    Wire this up to your actual mail provider by filling in MAIL_* vars in
    .env. Until then, emails are written to the app logger so the flow can
    be tested end-to-end without a mail server.
    """
    server = current_app.config.get("MAIL_SERVER")

    if not server:
        current_app.logger.info(
            "EMAIL (no MAIL_SERVER configured) -> to=%s subject=%r\n%s", to, subject, body
        )
        return

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = current_app.config["MAIL_DEFAULT_SENDER"]
    msg["To"] = to
    msg.set_content(body)

    with smtplib.SMTP(server, current_app.config["MAIL_PORT"]) as smtp:
        if current_app.config.get("MAIL_USE_TLS"):
            smtp.starttls()
        username = current_app.config.get("MAIL_USERNAME")
        password = current_app.config.get("MAIL_PASSWORD")
        if username and password:
            smtp.login(username, password)
        smtp.send_message(msg)
