from flask import render_template, url_for, current_app

from app.tasks.email import queue_email, send_email_now


def _dispatch(subject, recipient, template, **context):
    html_body = render_template(template, **context)
    if current_app.config.get("TESTING"):
        send_email_now(subject, [recipient], html_body)
    else:
        queue_email(subject, [recipient], html_body)


def send_verification_email(user, token):
    link = url_for("auth.verify_email", token=token, _external=True)
    _dispatch(
        "Verify your email address",
        user.email,
        "emails/verify_email.html",
        user=user,
        link=link,
    )


def send_password_reset_email(user, token):
    link = url_for("auth.reset_password", token=token, _external=True)
    _dispatch(
        "Reset your password",
        user.email,
        "emails/reset_password.html",
        user=user,
        link=link,
    )


def send_welcome_email(user):
    _dispatch(
        "Welcome to OpsLabs Servers",
        user.email,
        "emails/welcome.html",
        user=user,
    )
