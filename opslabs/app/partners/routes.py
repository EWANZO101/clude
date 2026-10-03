"""Partner Portal — agreement acceptance, company registration, status
dashboard, public company page, and admin review workflow."""
from flask import (render_template, request, redirect, url_for, flash, abort)
from flask_login import login_required, current_user

from . import partners_bp
from .. import db
from ..models_business import (PartnerCompany, PartnerAgreementAcceptance,
                               PARTNER_TYPE_CHOICES, PARTNER_LEGAL_CHOICES,
                               PARTNER_STATUS_META, AGREEMENT_VERSION_DEFAULT, AuditLog)
from ..models_admin import Setting
from ..rbac import require_role, STAFF, require_admin_page

RESERVED_SLUGS = {"new", "mine", "agreement", "admin", "p"}

DEFAULT_AGREEMENT = """OpsLab Systems — Partner & Independent Service Provider Agreement

This is a template agreement provided for convenience. Replace it with your own
solicitor-reviewed text in Admin → Partners before relying on it.

1. Independent Contractor Status
You operate as an independent business. Nothing in this agreement creates an
employment, partnership, agency or joint-venture relationship between you and
OpsLab Systems. You are solely responsible for your own taxes, insurance and
legal obligations.

2. Service Responsibility
You are responsible for the services, goods and support you offer through your
company profile. OpsLab Systems provides the hosting platform only and is not a
party to transactions between you and your customers.

3. Refund Policy Requirements
You must offer a clear refund policy. For digital goods you must provide a
minimum 24-hour refund window from the time of purchase, unless a longer period
is required by law in your or your customer's jurisdiction.

4. Complaints & Warning System
Customer complaints may be reviewed by OpsLab Systems. Repeated or serious
complaints may result in warnings. Accumulated warnings may lead to suspension
or removal of your company profile.

5. Prohibited Conduct
You must not use the platform for unlawful activity, fraud, misleading claims,
infringement of intellectual property, harassment, malware, or any content that
is illegal or harmful. You must provide accurate legal information.

6. Termination Rights
Either party may end this arrangement at any time. OpsLab Systems may suspend or
remove a company profile at its discretion, including for breach of this
agreement or false information.

7. Liability Limitations
The platform is provided "as is". To the maximum extent permitted by law,
OpsLab Systems is not liable for losses arising from your services, downtime,
or data loss. Nothing limits liability that cannot be limited by law.

8. Conduct Expectations
You agree to deal honestly and professionally with customers and with OpsLab
Systems, to respond to reasonable requests, and to keep your profile accurate.

By signing below you confirm you have read and accept this agreement and that
the information you provide is true.
"""


def agreement_version():
    return Setting.get("partner_agreement_version") or AGREEMENT_VERSION_DEFAULT


def agreement_text():
    return Setting.get("partner_agreement_text") or DEFAULT_AGREEMENT


def has_accepted(user):
    if not getattr(user, "is_authenticated", False):
        return False
    return PartnerAgreementAcceptance.query.filter_by(
        user_id=user.id, version=agreement_version()).first() is not None


@partners_bp.app_context_processor
def _inject_partner_flags():
    try:
        accepted = has_accepted(current_user)
    except Exception:
        accepted = False
    return dict(partner_agreement_accepted=accepted,
                partner_agreement_version=agreement_version())


# ── Landing ──────────────────────────────────────────────────────────────
@partners_bp.route("/partners")
def landing():
    return render_template("partners/landing.html", accepted=has_accepted(current_user))


# ── Agreement: read + sign ─────────────────────────────────────────────────
@partners_bp.route("/partners/agreement")
def agreement():
    acc = None
    if current_user.is_authenticated:
        acc = PartnerAgreementAcceptance.query.filter_by(
            user_id=current_user.id, version=agreement_version()).order_by(
            PartnerAgreementAcceptance.accepted_at.desc()).first()
    return render_template("partners/agreement.html", text=agreement_text(),
                           version=agreement_version(), acceptance=acc)


@partners_bp.route("/partners/agreement/accept", methods=["POST"])
@login_required
def accept():
    name = (request.form.get("full_legal_name") or "").strip()
    agreed = request.form.get("agree") == "on"
    if not name or not agreed:
        flash("Please enter your full legal name and tick the box to accept.", "error")
        return redirect(url_for("partners.agreement"))
    if not has_accepted(current_user):
        db.session.add(PartnerAgreementAcceptance(
            user_id=current_user.id, full_legal_name=name[:160],
            version=agreement_version(), ip=request.remote_addr))
        AuditLog.log("partner.agreement_accept", actor=current_user,
                     meta={"version": agreement_version()}, ip=request.remote_addr)
        db.session.commit()
    flash("Agreement signed — you can now create a company.", "success")
    return redirect(url_for("partners.new"))


# ── Company registration ────────────────────────────────────────────────────
@partners_bp.route("/partners/new", methods=["GET", "POST"])
@login_required
def new():
    if not has_accepted(current_user):
        flash("Please read and sign the Partner Agreement first.", "error")
        return redirect(url_for("partners.agreement"))
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        if not name:
            flash("Company name is required.", "error")
            return render_template("partners/register.html", form=request.form,
                                   types=PARTNER_TYPE_CHOICES, legal=PARTNER_LEGAL_CHOICES)
        c = PartnerCompany(
            slug=PartnerCompany.unique_slug(name),
            name=name[:160],
            ctype=(request.form.get("ctype") or "Developer"),
            legal_status=(request.form.get("legal_status") or "Unregistered"),
            owner_user_id=current_user.id,
            owner_legal_name=(request.form.get("owner_legal_name") or "").strip()[:160] or None,
            country=(request.form.get("country") or "").strip()[:80] or None,
            description=(request.form.get("description") or "").strip() or None,
            services=(request.form.get("services") or "").strip() or None,
            pricing=(request.form.get("pricing") or "").strip() or None,
            external_url=(request.form.get("external_url") or "").strip()[:300] or None,
            terms=(request.form.get("terms") or "").strip() or None,
            privacy=(request.form.get("privacy") or "").strip() or None,
            status="pending",
        )
        db.session.add(c)
        db.session.flush()
        AuditLog.log("partner.company_create", actor=current_user,
                     target_type="partner_company", target_id=c.id,
                     meta={"name": c.name}, ip=request.remote_addr)
        db.session.commit()
        flash("Company submitted for review.", "success")
        return redirect(url_for("partners.mine"))
    return render_template("partners/register.html", form={},
                           types=PARTNER_TYPE_CHOICES, legal=PARTNER_LEGAL_CHOICES)


# ── User dashboard: my companies + statuses ────────────────────────────────
@partners_bp.route("/partners/mine")
@login_required
def mine():
    companies = (PartnerCompany.query.filter_by(owner_user_id=current_user.id)
                 .order_by(PartnerCompany.created_at.desc()).all())
    return render_template("partners/mine.html", companies=companies)


# ── Public company page (only when approved) ────────────────────────────────
@partners_bp.route("/partners/<slug>")
def public(slug):
    if slug in RESERVED_SLUGS:
        abort(404)
    c = PartnerCompany.query.filter_by(slug=slug).first_or_404()
    is_owner = current_user.is_authenticated and current_user.id == c.owner_user_id
    is_staff = current_user.is_authenticated and (
        getattr(current_user, "is_staff", False) or getattr(current_user, "is_admin", False))
    if not c.is_public and not (is_owner or is_staff):
        abort(404)
    return render_template("partners/public.html", c=c, preview=not c.is_public)


# ════════════════════════════════════════════════ ADMIN ════════════════════
@partners_bp.route("/admin/partners")
@require_admin_page("partners")
def admin_list():
    show = request.args.get("status", "all")
    q = PartnerCompany.query
    if show in PARTNER_STATUS_META:
        q = q.filter_by(status=show)
    items = q.order_by(PartnerCompany.updated_at.desc()).all()
    return render_template("admin/partners/list.html", companies=items, show=show,
                           statuses=PARTNER_STATUS_META,
                           agreement_text=agreement_text(),
                           agreement_version=agreement_version())


@partners_bp.route("/admin/partners/<int:cid>/status", methods=["POST"])
@require_admin_page("partners")
def admin_status(cid):
    c = PartnerCompany.query.get_or_404(cid)
    new_status = request.form.get("status")
    if new_status in PARTNER_STATUS_META:
        c.status = new_status
    c.review_notes = (request.form.get("review_notes") or "").strip() or None
    c.rejection_reason = (request.form.get("rejection_reason") or "").strip() or None
    AuditLog.log("partner.status", actor=current_user, target_type="partner_company",
                 target_id=c.id, meta={"status": c.status}, ip=request.remote_addr)
    db.session.commit()
    flash(f"“{c.name}” set to {c.status_label}.", "success")
    return redirect(url_for("partners.admin_list", status=request.args.get("status", "all")))


@partners_bp.route("/admin/partners/<int:cid>/delete", methods=["POST"])
@require_admin_page("partners")
def admin_delete(cid):
    c = PartnerCompany.query.get_or_404(cid)
    db.session.delete(c)
    AuditLog.log("partner.delete", actor=current_user, target_type="partner_company",
                 target_id=cid, ip=request.remote_addr)
    db.session.commit()
    flash("Company deleted.", "success")
    return redirect(url_for("partners.admin_list", status=request.args.get("status", "all")))


@partners_bp.route("/admin/partners/agreement", methods=["POST"])
@require_admin_page("partners")
def admin_agreement():
    Setting.set("partner_agreement_text", request.form.get("agreement_text") or "",
                kind="text", category="partners")
    v = (request.form.get("agreement_version") or "").strip()
    if v:
        Setting.set("partner_agreement_version", v, kind="string", category="partners")
    AuditLog.log("partner.agreement_edit", actor=current_user, ip=request.remote_addr)
    flash("Agreement updated.", "success")
    return redirect(url_for("partners.admin_list", status=request.args.get("status", "all")))
