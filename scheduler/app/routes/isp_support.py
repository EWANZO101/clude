from flask import Blueprint, abort, flash, redirect, render_template, request, session, url_for
from flask_login import current_user, login_required

from app import db
from app.forms import CSRFOnlyForm, ISPFeeForm, ISPSupportForm, SupportRequestLookupForm, SupportRequestStatusForm
from app.models.isp_support import STATUSES, SupportAccessLog, SupportRequest
from app.models.settings import Settings
from app.models.user import User
from app.services.availability import compute_available_intervals
from app.services.status import local_now

isp_support_bp = Blueprint("isp_support", __name__)


def _is_out_of_hours(owner):
    """Whether right now falls outside `owner`'s normal working hours.

    Reuses the same availability engine the booking system reads from, so
    "out of hours" here means exactly what it means on the Availability
    page — not a separate/duplicated notion of business hours.
    """
    if owner is None:
        return False
    now = local_now(owner)
    intervals = compute_available_intervals(owner, now.date())
    return not any(start <= now < end for start, end in intervals)


@isp_support_bp.route("/support/isp", methods=["GET", "POST"])
def request_form():
    owner = User.get_primary()
    fee = None
    out_of_hours = False
    if owner is not None:
        settings_row = Settings.for_user(owner)
        fee = settings_row.isp_out_of_hours_fee or None
        out_of_hours = _is_out_of_hours(owner)

    form = ISPSupportForm()

    if form.validate_on_submit():
        fee_ack_needed = out_of_hours and fee
        if fee_ack_needed and not form.consent_out_of_hours_fee.data:
            flash(f"Please confirm you accept the {fee} out-of-hours fee to continue.", "error")
        else:
            resolved_isp_name = (
                (form.isp_name_other.data or "").strip()
                if form.isp_name.data == "other"
                else form.isp_name.data
            )
            req = SupportRequest(
                full_name=form.full_name.data.strip(),
                email=(form.email.data or "").strip() or None,
                phone=(form.phone.data or "").strip() or None,
                isp_name=resolved_isp_name,
                problem_description=form.problem_description.data.strip(),
                account_number=(form.account_number.data or "").strip() or None,
                customer_number=(form.customer_number.data or "").strip() or None,
                full_address=(form.full_address.data or "").strip() or None,
                service_address=(form.service_address.data or "").strip() or None,
                date_of_birth=(form.date_of_birth.data or "").strip() or None,
                last_bill_date=(form.last_bill_date.data or "").strip() or None,
                last_bill_amount=(form.last_bill_amount.data or "").strip() or None,
                mothers_maiden_name=(form.mothers_maiden_name.data or "").strip() or None,
                childhood_nickname=(form.childhood_nickname.data or "").strip() or None,
                security_question=(form.security_question.data or "").strip() or None,
                security_answer=(form.security_answer.data or "").strip() or None,
                other_security_info=(form.other_security_info.data or "").strip() or None,
                consent_authorised=bool(form.consent_authorised.data),
                consent_accurate=bool(form.consent_accurate.data),
                consent_purpose=bool(form.consent_purpose.data),
                consent_additional_verification=bool(form.consent_additional_verification.data),
                consent_no_password_request=bool(form.consent_no_password_request.data),
                submitted_out_of_hours=bool(fee_ack_needed),
                out_of_hours_fee_shown=fee if fee_ack_needed else None,
            )
            db.session.add(req)
            db.session.commit()
            session["isp_support_last_reference"] = req.reference
            return redirect(url_for("isp_support.thank_you"))

    return render_template(
        "public/isp_support_form.html", form=form, out_of_hours=out_of_hours, fee=fee
    )


@isp_support_bp.route("/support/isp/thank-you")
def thank_you():
    reference = session.pop("isp_support_last_reference", None)
    return render_template("public/isp_support_thanks.html", reference=reference)


@isp_support_bp.route("/support/isp/status", methods=["GET", "POST"])
def check_status():
    form = SupportRequestLookupForm()
    result = None
    searched = False

    if form.validate_on_submit():
        searched = True
        result = SupportRequest.query.filter_by(
            reference=form.reference.data.strip().upper(),
        ).first()
        if result and (result.email or "").strip().lower() != form.email.data.strip().lower():
            result = None
        if not result:
            flash("No request found with that reference code and email.", "error")

    return render_template("public/isp_support_status.html", form=form, result=result, searched=searched)


@isp_support_bp.route("/admin/isp-support")
@login_required
def admin_list():
    status_filter = request.args.get("status", "").strip()
    query = SupportRequest.query
    if status_filter in STATUSES:
        query = query.filter_by(status=status_filter)
    requests_ = query.order_by(SupportRequest.submitted_at.desc()).all()
    return render_template(
        "admin/isp_support_list.html",
        requests=requests_,
        status_filter=status_filter,
        statuses=STATUSES,
        active_page="isp_support",
    )


@isp_support_bp.route("/admin/isp-support/<int:request_id>", methods=["GET", "POST"])
@login_required
def admin_detail(request_id):
    req = SupportRequest.query.get_or_404(request_id)

    # Audit log — every view of a request's details is recorded, per the
    # policy's access-log requirement.
    db.session.add(SupportAccessLog(support_request_id=req.id, user_id=current_user.id))
    db.session.commit()

    status_form = SupportRequestStatusForm(status=req.status, admin_notes=req.admin_notes or "")
    delete_form = CSRFOnlyForm()

    if request.method == "POST" and status_form.validate_on_submit():
        from datetime import datetime, timezone as dt_timezone

        req.status = status_form.status.data
        req.admin_notes = status_form.admin_notes.data.strip() if status_form.admin_notes.data else None
        if req.status in ("resolved", "closed") and not req.resolved_at:
            req.resolved_at = datetime.now(dt_timezone.utc)
        elif req.status not in ("resolved", "closed"):
            req.resolved_at = None
        db.session.commit()
        flash("Request updated.", "success")
        return redirect(url_for("isp_support.admin_detail", request_id=req.id))

    recent_access = req.access_logs.order_by(SupportAccessLog.accessed_at.desc()).limit(10).all()

    return render_template(
        "admin/isp_support_detail.html",
        req=req,
        status_form=status_form,
        delete_form=delete_form,
        recent_access=recent_access,
        active_page="isp_support",
    )


@isp_support_bp.route("/admin/isp-support/<int:request_id>/delete", methods=["POST"])
@login_required
def admin_delete(request_id):
    req = SupportRequest.query.get_or_404(request_id)
    db.session.delete(req)
    db.session.commit()
    flash("Request deleted.", "success")
    return redirect(url_for("isp_support.admin_list"))
