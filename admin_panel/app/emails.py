from flask import current_app
from flask_mail import Message

from app.extensions import mail


def _send(subject: str, recipient: str, body: str):
    if not current_app.config.get("MAIL_SERVER"):
        # No SMTP configured (e.g. local dev) — log instead of failing signup/reset flows.
        current_app.logger.info("[email suppressed - no MAIL_SERVER] To: %s\nSubject: %s\n%s",
                                 recipient, subject, body)
        return
    msg = Message(subject=subject, recipients=[recipient], body=body)
    try:
        mail.send(msg)
    except Exception as e:
        # A broken/misconfigured SMTP server should never 500 the request that
        # triggered the email (signup, invite, password reset) — the action
        # itself (account created, invite row written) already succeeded.
        current_app.logger.error("Failed to send email to %s: %s", recipient, e)


def send_verification_email(user, token: str):
    link = f"{current_app.config['BASE_URL']}/auth/verify-email/{token}"
    _send(
        "Verify your OpsLab Admin Panel account",
        user.email,
        f"Hi {user.full_name},\n\n"
        f"Please verify your email address to activate your account:\n{link}\n\n"
        f"This link expires in 24 hours.\n",
    )


def send_password_reset_email(user, token: str):
    link = f"{current_app.config['BASE_URL']}/auth/reset-password/{token}"
    _send(
        "Reset your OpsLab Admin Panel password",
        user.email,
        f"Hi {user.full_name},\n\n"
        f"A password reset was requested for your account. If this wasn't you, "
        f"ignore this email.\n\nReset your password here:\n{link}\n\n"
        f"This link expires in 1 hour.\n",
    )


def send_company_invite_email(invite):
    link = f"{current_app.config['BASE_URL']}/auth/accept-invite/{invite.token}"
    _send(
        f"You've been invited to join {invite.company.name} on OpsLab",
        invite.email,
        f"You've been invited to join {invite.company.name} as {invite.role}.\n\n"
        f"Accept the invite here:\n{link}\n",
    )
