from flask import render_template, redirect, url_for, abort
from flask_login import current_user

from app.extensions import db
from app.models.support import SupportTicket, TicketMessage
from app.support.forms import TicketForm, CustomerTicketMessageForm
from app.utils.helpers import log_audit


def register_customer_support_views(customer_bp):
    @customer_bp.route("/support", endpoint="support")
    def support_list():
        tickets = (
            SupportTicket.query.filter_by(user_id=current_user.id)
            .order_by(SupportTicket.created_at.desc())
            .all()
        )
        return render_template("customer/support/list.html", tickets=tickets)

    @customer_bp.route("/support/new", methods=["GET", "POST"])
    def support_new():
        form = TicketForm()
        if form.validate_on_submit():
            ticket = SupportTicket(user_id=current_user.id)
            form.populate_obj(ticket)
            db.session.add(ticket)
            db.session.flush()
            log_audit("support_ticket.created", "SupportTicket", ticket.id)
            db.session.commit()
            return redirect(url_for("customer.support_detail", ticket_id=ticket.id))
        return render_template("customer/support/form.html", form=form)

    @customer_bp.route("/support/<int:ticket_id>", methods=["GET", "POST"])
    def support_detail(ticket_id):
        ticket = SupportTicket.query.filter_by(id=ticket_id, user_id=current_user.id).first()
        if ticket is None:
            abort(404)

        form = CustomerTicketMessageForm()
        if form.validate_on_submit():
            db.session.add(TicketMessage(ticket_id=ticket.id, sender_id=current_user.id, body=form.body.data))
            db.session.commit()
            return redirect(url_for("customer.support_detail", ticket_id=ticket.id))

        return render_template(
            "customer/support/detail.html", ticket=ticket, form=form,
            visible_messages=ticket.visible_messages(False),
        )
