from flask import Blueprint, render_template, redirect, url_for, flash, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models import SupportTicket, TicketMessage, TicketStatus
from app.support.forms import NewTicketForm, ReplyForm
from app.auth.routes import log_action

support_bp = Blueprint("support", __name__, url_prefix="/support")


def _owned_ticket_or_404(ticket_id):
    ticket = SupportTicket.query.get_or_404(ticket_id)
    if ticket.user_id != current_user.id and not current_user.is_admin():
        abort(404)
    return ticket


@support_bp.route("/")
@login_required
def list_tickets():
    tickets = SupportTicket.query.filter_by(user_id=current_user.id).order_by(
        SupportTicket.updated_at.desc()
    ).all()
    return render_template("support/list.html", tickets=tickets)


@support_bp.route("/new", methods=["GET", "POST"])
@login_required
def new_ticket():
    form = NewTicketForm()
    if form.validate_on_submit():
        ticket = SupportTicket(user_id=current_user.id, subject=form.subject.data)
        db.session.add(ticket)
        db.session.flush()

        message = TicketMessage(
            ticket_id=ticket.id, sender_id=current_user.id,
            is_staff_reply=False, body=form.message.data,
        )
        db.session.add(message)
        db.session.commit()
        log_action(current_user.id, "support_ticket_created", detail=ticket.id)
        flash("Ticket created — our team will get back to you soon.", "success")
        return redirect(url_for("support.ticket_detail", ticket_id=ticket.id))

    return render_template("support/new.html", form=form)


@support_bp.route("/<ticket_id>", methods=["GET", "POST"])
@login_required
def ticket_detail(ticket_id):
    ticket = _owned_ticket_or_404(ticket_id)
    form = ReplyForm()

    if form.validate_on_submit():
        if ticket.status in (TicketStatus.RESOLVED, TicketStatus.CLOSED):
            flash("This ticket is closed. Create a new one if you still need help.", "warning")
            return redirect(url_for("support.ticket_detail", ticket_id=ticket_id))

        message = TicketMessage(
            ticket_id=ticket.id, sender_id=current_user.id,
            is_staff_reply=False, body=form.body.data,
        )
        db.session.add(message)
        ticket.status = TicketStatus.PENDING_SUPPORT
        db.session.commit()
        log_action(current_user.id, "support_ticket_replied", detail=ticket_id)
        return redirect(url_for("support.ticket_detail", ticket_id=ticket_id))

    return render_template("support/detail.html", ticket=ticket, form=form)
