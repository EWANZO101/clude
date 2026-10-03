from flask import render_template, redirect, url_for, request, flash, abort
from flask_login import current_user

from app.extensions import db
from app.models.support import SupportTicket, TicketMessage, TicketStatus
from app.models.user import User, AccountType
from app.support.forms import TicketMessageForm
from app.utils.helpers import log_audit, paginate_query
from app.utils.permissions import permission_required


def register_admin_support_views(admin_bp):
    @admin_bp.route("/tickets")
    @permission_required("tickets.view")
    def tickets():
        page = request.args.get("page", 1, type=int)
        status_filter = request.args.get("status", "")
        query = SupportTicket.query.order_by(SupportTicket.created_at.desc())
        if status_filter and status_filter in TicketStatus._value2member_map_:
            query = query.filter_by(status=TicketStatus(status_filter))
        pagination = paginate_query(query, page, 25)
        return render_template(
            "admin/tickets/list.html", pagination=pagination, status_filter=status_filter, statuses=list(TicketStatus)
        )

    @admin_bp.route("/tickets/<int:ticket_id>", methods=["GET", "POST"])
    @permission_required("tickets.edit")
    def ticket_detail(ticket_id):
        ticket = db.session.get(SupportTicket, ticket_id) or abort(404)

        message_form = TicketMessageForm()
        if request.method == "POST":
            action = request.form.get("action", "reply")
            if action == "reply" and message_form.validate_on_submit():
                db.session.add(
                    TicketMessage(
                        ticket_id=ticket.id, sender_id=current_user.id,
                        body=message_form.body.data, is_internal_note=message_form.is_internal_note.data,
                    )
                )
            elif action == "set_status":
                new_status = request.form.get("status")
                if new_status in TicketStatus._value2member_map_:
                    ticket.status = TicketStatus(new_status)
                    log_audit("support_ticket.status_changed", "SupportTicket", ticket.id, None, {"status": new_status})
            elif action == "assign_staff":
                ticket.assigned_staff_id = request.form.get("staff_id", type=int) or None
            db.session.commit()
            flash("Ticket updated.", "success")
            return redirect(url_for("admin.ticket_detail", ticket_id=ticket.id))

        staff_users = User.query.filter(User.account_type.in_([AccountType.STAFF, AccountType.ADMIN])).all()
        return render_template(
            "admin/tickets/detail.html", ticket=ticket, form=message_form, staff_users=staff_users,
            statuses=list(TicketStatus),
        )
