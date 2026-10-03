"""Turns booking events into emails.

Every send goes through app.services.email.send_email, and every send is
wrapped in a try/except here — a broken mail server should never block a
booking from being created or cancelled in the app itself. Failures are
logged so they're visible without becoming user-facing errors.
"""

import logging

from flask import render_template, url_for

from app.models.settings import Settings
from app.services.email import send_email
from app.services.push import push_cancelled_booking, push_new_booking

logger = logging.getLogger(__name__)


def _booking_context(booking, extra=None):
    ctx = {
        "app_name": "Scheduler",
        "booking_type_name": booking.booking_type.name if booking.booking_type else "Meeting",
        "start_display": booking.start_datetime.strftime("%A %d %B %Y"),
        "time_display": f"{booking.start_datetime.strftime('%H:%M')} - {booking.end_datetime.strftime('%H:%M')}",
        "notes": booking.notes,
    }
    if extra:
        ctx.update(extra)
    return ctx


def _send(to_email, subject, **context):
    html_body = render_template("email/booking_notification.html", subject=subject, **context)
    text_lines = [
        context["heading"],
        "",
        context["intro"],
        "",
        context["booking_type_name"],
        context["start_display"],
        context["time_display"],
    ]
    if context.get("notes"):
        text_lines += ["", '"' + context["notes"] + '"']
    if context.get("cta_url"):
        text_lines += ["", context["cta_label"] + ": " + context["cta_url"]]
    text_body = "\n".join(text_lines)

    try:
        send_email(to_email, subject, html_body, text_body)
    except Exception:  # noqa: BLE001 - a mail failure must never break the booking flow
        logger.exception("Failed to send email '%s' to %s", subject, to_email)


def notify_new_booking(booking):
    """Sends the booker their confirmation, and the owner a heads-up, if enabled."""
    manage_url = url_for("public.manage_booking", token=booking.manage_token, _external=True)

    _send(
        booking.email,
        "Booking confirmed: " + (booking.booking_type.name if booking.booking_type else "Meeting"),
        **_booking_context(
            booking,
            {
                "heading": "You're booked in",
                "intro": "This confirms your booking with " + booking.user.name + ".",
                "cta_url": manage_url,
                "cta_label": "Manage this booking",
            },
        ),
    )

    settings = Settings.for_user(booking.user)
    if settings.notify_on_new_booking:
        _send(
            booking.user.email,
            "New booking: " + booking.name,
            **_booking_context(
                booking,
                {
                    "heading": "New booking",
                    "intro": booking.name + " (" + booking.email + ") just booked time with you.",
                },
            ),
        )

    # Push to the mobile app regardless of the email toggle — each phone
    # controls its own notifications in iOS Settings.
    try:
        push_new_booking(booking)
    except Exception:  # noqa: BLE001 - a push failure must never break the booking flow
        logger.exception("Failed to queue new-booking push for booking %s", booking.id)


def notify_cancelled_booking(booking, cancelled_by):
    """cancelled_by is 'guest' or 'admin' — only the *other* party gets a heads-up."""
    settings = Settings.for_user(booking.user)

    if cancelled_by == "guest" and settings.notify_on_cancellation:
        _send(
            booking.user.email,
            "Cancelled: " + booking.name,
            **_booking_context(
                booking,
                {
                    "heading": "Booking cancelled",
                    "intro": booking.name + " (" + booking.email + ") cancelled their booking.",
                },
            ),
        )

    if cancelled_by == "guest":
        try:
            push_cancelled_booking(booking)
        except Exception:  # noqa: BLE001 - a push failure must never break the cancel flow
            logger.exception("Failed to queue cancellation push for booking %s", booking.id)

    if cancelled_by == "admin":
        _send(
            booking.email,
            "Your booking has been cancelled",
            **_booking_context(
                booking,
                {
                    "heading": "Booking cancelled",
                    "intro": booking.user.name
                    + " cancelled this booking. Get in touch with them if you'd like to reschedule.",
                },
            ),
        )


def notify_rescheduled_booking(booking, old_start_display, old_time_display):
    """Tells the customer their booking moved to a new time. Only the
    customer needs this — the admin is the one who just made the change."""
    manage_url = url_for("public.manage_booking", token=booking.manage_token, _external=True)
    _send(
        booking.email,
        "Your booking has been rescheduled",
        **_booking_context(
            booking,
            {
                "heading": "Your booking moved",
                "intro": (
                    booking.user.name + " moved your booking from " + old_start_display
                    + " at " + old_time_display + " to the new time below."
                ),
                "cta_url": manage_url,
                "cta_label": "Manage this booking",
            },
        ),
    )


def notify_running_late(booking, minutes_late=None):
    """A one-off heads-up to the customer that the admin is running behind.
    Doesn't change the booking itself — purely informational."""
    if minutes_late:
        intro = f"{booking.user.name} is running about {minutes_late} minutes behind schedule for your booking."
    else:
        intro = f"{booking.user.name} is running a little behind schedule for your booking."
    _send(
        booking.email,
        "Running a little late",
        **_booking_context(
            booking,
            {
                "heading": "Running a bit late",
                "intro": intro,
            },
        ),
    )
