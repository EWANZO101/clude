"""
Book a call-out / meeting requests.

Public (no auth):
  GET  /callout            booking form
  POST /callout            submit request

Admin (staff+):
  GET  /admin/callouts                 list
  POST /admin/callouts/<id>/status     update status
  POST /admin/callouts/<id>/delete     remove
"""
from datetime import datetime

from flask import render_template, request, redirect, url_for, flash, jsonify
from flask_login import current_user

from . import callouts_bp
from .services import SERVICE_GROUPS, OTHER_LABEL, all_labels, price_display
from .. import db
from ..models_business import (MeetingRequest, MEETING_MODE_META,
                               MEETING_STATUS_META, Notification, AuditLog)
from ..models_admin import Setting
from ..rbac import require_role, STAFF, require_admin_page


def _prices():
    """Dict of {service label: stored value} from Settings."""
    data = Setting.get("callout_prices", {})
    return data if isinstance(data, dict) else {}


def _price_texts():
    """{label: display string} for the public form / details."""
    out = {}
    for label, val in _prices().items():
        disp = price_display(val)
        if disp:
            out[label] = disp
    return out


def _price_inputs():
    """{label: editable string} for the admin form (legacy pence -> pounds)."""
    out = {}
    for label, val in _prices().items():
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            out[label] = "{:.2f}".format(val / 100)
        elif val:
            out[label] = str(val)
    return out


def _clean_price(raw):
    """Keep whatever the admin typed (range/text/number), trimmed."""
    raw = (raw or "").strip()
    return raw or None


def _parse_day(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        return None


# ════════════════════════════════════════════════ PUBLIC ═══════════════════
@callouts_bp.route("/callout", methods=["GET", "POST"])
def book():
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        mode = request.form.get("mode")
        if mode not in MEETING_MODE_META:
            mode = "in_person"
        email = (request.form.get("email") or "").strip()
        phone = (request.form.get("phone") or "").strip()
        service = (request.form.get("service") or "").strip()
        other_detail = (request.form.get("other_detail") or "").strip()
        if not name or not phone:
            flash("Please add your name and a phone number so we can reach you.", "error")
            return render_template("public/callout.html", modes=MEETING_MODE_META, form=request.form,
                                   service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)
        if not service:
            flash("Please choose what you need help with.", "error")
            return render_template("public/callout.html", modes=MEETING_MODE_META, form=request.form,
                                   service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)
        if service == OTHER_LABEL and not other_detail:
            flash("Please describe what you need.", "error")
            return render_template("public/callout.html", modes=MEETING_MODE_META, form=request.form,
                                   service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)
        prices = _prices()
        if service == OTHER_LABEL:
            details = "Other: " + other_detail
        else:
            details = service
            est = prices.get(service)
            disp = price_display(est) if est else None
            if disp:
                details = f"{service} (est. {disp})"
        req = MeetingRequest(
            name=name[:120],
            email=email[:160] or None,
            phone=phone[:40] or None,
            mode=mode,
            location=(request.form.get("location") or "").strip()[:200] or None,
            preferred_day=_parse_day(request.form.get("preferred_day")),
            preferred_time=(request.form.get("preferred_time") or "").strip() or None,
            details=details[:2000] or None,
        )
        db.session.add(req)
        db.session.flush()
        AuditLog.log("meeting.request", target_type="meeting_request", target_id=req.id,
                     meta={"name": name, "mode": mode}, ip=request.remote_addr)
        # notify all staff
        from ..models import User
        for u in User.query.filter(User.role.in_(("staff", "support", "admin", "super_admin"))).all():
            Notification.push(u.id, "New call-out request",
                              f"{name} — {req.mode_meta['label']}.",
                              url=url_for("callouts.admin_list"), category="meeting")
        db.session.commit()
        return redirect(url_for("callouts.book", sent=1))
    return render_template("public/callout.html", modes=MEETING_MODE_META,
                           form={}, sent=request.args.get("sent"),
                           service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)


# ════════════════════════════════════════════════ ADMIN ════════════════════
@callouts_bp.route("/admin/callouts")
@require_admin_page("callouts")
def admin_list():
    status = request.args.get("status") or ""
    q = MeetingRequest.query
    if status in MEETING_STATUS_META:
        q = q.filter_by(status=status)
    items = q.order_by(MeetingRequest.created_at.desc()).all()
    return render_template("admin/callouts/list.html", items=items,
                           status_meta=MEETING_STATUS_META, status=status)


@callouts_bp.route("/admin/callouts/<int:rid>/status", methods=["POST"])
@require_admin_page("callouts")
def admin_status(rid):
    req = MeetingRequest.query.get_or_404(rid)
    new = request.form.get("status")
    if new in MEETING_STATUS_META:
        req.status = new
        AuditLog.log("meeting.status", actor=current_user, target_type="meeting_request",
                     target_id=req.id, meta={"status": new}, ip=request.remote_addr)
        db.session.commit()
        flash("Status updated.", "success")
    return redirect(url_for("callouts.admin_list", status=request.args.get("status", "")))


@callouts_bp.route("/admin/callouts/<int:rid>/delete", methods=["POST"])
@require_admin_page("callouts")
def admin_delete(rid):
    req = MeetingRequest.query.get_or_404(rid)
    db.session.delete(req)
    AuditLog.log("meeting.delete", actor=current_user, target_type="meeting_request",
                 target_id=rid, ip=request.remote_addr)
    db.session.commit()
    flash("Request deleted.", "success")
    return redirect(url_for("callouts.admin_list", status=request.args.get("status", "")))


@callouts_bp.route("/admin/callout-prices", methods=["GET"])
@require_admin_page("callouts")
def admin_prices():
    return render_template("admin/callouts/prices.html",
                           service_groups=SERVICE_GROUPS, prices=_price_inputs(),
                           other_label=OTHER_LABEL)


# ── Public, live-updating price list ─────────────────────────────────────
@callouts_bp.route("/pricing")
def pricing():
    return render_template("public/pricing.html",
                           service_groups=SERVICE_GROUPS, prices=_price_texts(),
                           other_label=OTHER_LABEL)


@callouts_bp.route("/pricing.json")
def pricing_json():
    return jsonify(_price_texts())


@callouts_bp.route("/admin/callout-prices", methods=["POST"])
@require_admin_page("callouts")
def admin_prices_save():
    new = {}
    for label in all_labels():
        if label == OTHER_LABEL:
            continue
        val = _clean_price(request.form.get(label))
        if val is not None:
            new[label] = val
    Setting.set("callout_prices", new, kind="json", category="callouts")
    AuditLog.log("meeting.prices", actor=current_user, ip=request.remote_addr)
    flash("Estimated prices saved.", "success")
    return redirect(url_for("callouts.admin_prices"))
