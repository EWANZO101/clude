import re
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, g, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models import (
    Company, CompanyMembership, CompanyInvite, COMPANY_ROLES, User, log_action,
    PIN_EXPIRY_PRESETS_DAYS,
    Product, CompanyProductAccess,
)
from app.rbac import load_company_context, permission_required
from app.platform_auth import platform_admin_required
from app.emails import send_company_invite_email

bp = Blueprint("companies", __name__, url_prefix="/companies")


def _slugify(name: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "company"
    slug = base
    n = 1
    while Company.query.filter_by(slug=slug).first() is not None:
        n += 1
        slug = f"{base}-{n}"
    return slug


@bp.route("/new", methods=["GET", "POST"])
@login_required
def new():
    active_products = Product.query.filter_by(is_active=True).order_by(Product.name).all()

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        contact_email = request.form.get("contact_email", "").strip()
        contact_phone = request.form.get("contact_phone", "").strip()
        address = request.form.get("address", "").strip()

        if not name:
            flash("Company name is required.", "danger")
            return render_template("companies/new.html", active_products=active_products)

        company = Company(
            name=name,
            slug=_slugify(name),
            contact_email=contact_email or None,
            contact_phone=contact_phone or None,
            address=address or None,
        )
        db.session.add(company)
        db.session.flush()

        membership = CompanyMembership(user_id=current_user.id, company_id=company.id, role="owner")
        db.session.add(membership)

        # Companies get NO product access automatically — ticking one here
        # just submits the same request an owner could make later from
        # Company home, it's not a shortcut around approval.
        requested_ids = {int(pid) for pid in request.form.getlist("request_product_id") if pid.isdigit()}
        requested_names = []
        for product in active_products:
            if product.id in requested_ids:
                db.session.add(CompanyProductAccess(
                    company_id=company.id, product_id=product.id, status="pending",
                    requested_by_id=current_user.id,
                ))
                requested_names.append(product.name)
        db.session.commit()

        msg = f"Company '{company.name}' created."
        if requested_names:
            msg += f" Access requested for: {', '.join(requested_names)} — awaiting approval."
        flash(msg, "success")
        return redirect(url_for("companies.detail", company_id=company.public_id))

    return render_template("companies/new.html", active_products=active_products)


@bp.route("/<company_id>")
@login_required
@load_company_context
def detail(company_id):
    company = g.company
    member_count = CompanyMembership.query.filter_by(company_id=company.id).count()
    pending_invite_count = CompanyInvite.query.filter_by(
        company_id=company.id, accepted_at=None, revoked=False
    ).count()

    products = Product.query.filter_by(is_active=True).order_by(Product.name).all()
    access_by_product_id = {
        a.product_id: a for a in CompanyProductAccess.query.filter_by(company_id=company.id).all()
    }

    return render_template(
        "companies/detail.html", company=company,
        member_count=member_count, pending_invite_count=pending_invite_count,
        role=g.company_role,
        products=products, access_by_product_id=access_by_product_id,
    )


@bp.route("/<company_id>/products/<product_id>/request", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_company")
def request_product(company_id, product_id):
    company = g.company
    product = Product.query.filter_by(public_id=product_id, is_active=True).first()
    if product is None:
        abort(404)

    access = CompanyProductAccess.query.filter_by(company_id=company.id, product_id=product.id).first()
    if access is not None and access.status == "approved":
        flash(f"{company.name} already has access to {product.name}.", "info")
        return redirect(url_for("companies.detail", company_id=company.public_id))

    note = (request.form.get("note") or "").strip() or None
    if access is None:
        access = CompanyProductAccess(company_id=company.id, product_id=product.id)
        db.session.add(access)
    # Re-requesting after a rejection resets to pending rather than
    # creating a second row — the unique (company_id, product_id)
    # constraint means there can only ever be one anyway.
    access.status = "pending"
    access.requested_by_id = current_user.id
    access.requested_at = datetime.utcnow()
    access.note = note
    access.decided_by_id = None
    access.decided_at = None
    access.decision_note = None

    log_action(company, current_user, "product_access_requested", product.name)
    db.session.commit()
    flash(f"Requested access to {product.name} — awaiting approval.", "success")
    return redirect(url_for("companies.detail", company_id=company.public_id))


@bp.route("/<company_id>/products/<product_id>/grant", methods=["POST"])
@login_required
@load_company_context
@platform_admin_required
def grant_product(company_id, product_id):
    company = g.company
    product = Product.query.filter_by(public_id=product_id).first()
    if product is None:
        abort(404)

    access = CompanyProductAccess.query.filter_by(company_id=company.id, product_id=product.id).first()
    if access is None:
        access = CompanyProductAccess(
            company_id=company.id, product_id=product.id, requested_by_id=None,
        )
        db.session.add(access)
    access.status = "approved"
    access.decided_by_id = current_user.id
    access.decided_at = datetime.utcnow()
    access.decision_note = "Granted directly by a platform admin."

    log_action(company, current_user, "product_access_granted", product.name)
    db.session.commit()
    flash(f"Granted {company.name} access to {product.name}.", "success")
    return redirect(url_for("companies.detail", company_id=company.public_id))


@bp.route("/<company_id>/products/<product_id>/revoke", methods=["POST"])
@login_required
@load_company_context
@platform_admin_required
def revoke_product(company_id, product_id):
    company = g.company
    product = Product.query.filter_by(public_id=product_id).first()
    if product is None:
        abort(404)
    access = CompanyProductAccess.query.filter_by(company_id=company.id, product_id=product.id).first()
    if access is None:
        abort(404)

    access.status = "rejected"
    access.decided_by_id = current_user.id
    access.decided_at = datetime.utcnow()
    access.decision_note = "Revoked by a platform admin."

    log_action(company, current_user, "product_access_revoked", product.name)
    db.session.commit()
    flash(f"Revoked {company.name}'s access to {product.name}.", "info")
    return redirect(url_for("companies.detail", company_id=company.public_id))


@bp.route("/<company_id>/edit", methods=["GET", "POST"])
@login_required
@load_company_context
@permission_required("manage_company")
def edit(company_id):
    company = g.company
    if request.method == "POST":
        company.name = request.form.get("name", company.name).strip()
        company.contact_email = request.form.get("contact_email", company.contact_email or "").strip() or None
        company.contact_phone = request.form.get("contact_phone", company.contact_phone or "").strip() or None
        company.address = request.form.get("address", company.address or "").strip() or None

        time_str = request.form.get("default_update_time", "").strip()
        if request.form.get("clear_update_time"):
            company.default_update_time = None
        elif time_str:
            try:
                company.default_update_time = datetime.strptime(time_str, "%H:%M").time()
            except ValueError:
                flash("Update time must be in HH:MM format.", "danger")
                return render_template("companies/edit.html", company=company)

        countdown = request.form.get("update_countdown_minutes", "").strip()
        if countdown.isdigit():
            company.update_countdown_minutes = int(countdown)

        db.session.commit()
        flash("Company details updated.", "success")
        return redirect(url_for("companies.detail", company_id=company.public_id))
    return render_template("companies/edit.html", company=company)


@bp.route("/<company_id>/members/invite", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_members")
def invite_member(company_id):
    company = g.company
    email = request.form.get("email", "").strip().lower()
    role = request.form.get("role", "operator")

    if role not in COMPANY_ROLES:
        flash("Invalid role.", "danger")
        return redirect(url_for("companies.users_page", company_id=company.public_id))
    if role == "owner" and g.company_role != "owner":
        flash("Only an owner can invite another owner.", "danger")
        return redirect(url_for("companies.users_page", company_id=company.public_id))
    if not email:
        flash("Email is required.", "danger")
        return redirect(url_for("companies.users_page", company_id=company.public_id))

    existing_user = User.query.filter_by(email=email).first()
    if existing_user and existing_user.role_in(company.id):
        flash("That person is already a member.", "warning")
        return redirect(url_for("companies.users_page", company_id=company.public_id))

    invite = CompanyInvite(
        company_id=company.id, email=email, role=role, invited_by_id=current_user.id
    )
    db.session.add(invite)
    db.session.commit()
    send_company_invite_email(invite)

    flash(f"Invite sent to {email}.", "success")
    return redirect(url_for("companies.users_page", company_id=company.public_id))


@bp.route("/<company_id>/members/<int:membership_id>/role", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_members")
def update_member_role(company_id, membership_id):
    company = g.company
    membership = CompanyMembership.query.filter_by(id=membership_id, company_id=company.id).first()
    if membership is None:
        abort(404)

    new_role = request.form.get("role")
    if new_role not in COMPANY_ROLES:
        flash("Invalid role.", "danger")
        return redirect(url_for("companies.users_page", company_id=company.public_id))

    if membership.role == "owner" and new_role != "owner":
        remaining_owners = CompanyMembership.query.filter_by(
            company_id=company.id, role="owner"
        ).count()
        if remaining_owners <= 1:
            flash("A company must always have at least one owner.", "danger")
            return redirect(url_for("companies.users_page", company_id=company.public_id))

    if new_role == "owner" and g.company_role != "owner":
        flash("Only an owner can promote another member to owner.", "danger")
        return redirect(url_for("companies.users_page", company_id=company.public_id))

    membership.role = new_role
    log_action(company, current_user, "member_role_changed", f"{membership.user.email} -> {new_role}")
    db.session.commit()
    flash("Role updated.", "success")
    return redirect(url_for("companies.users_page", company_id=company.public_id))


@bp.route("/<company_id>/members/<int:membership_id>/remove", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_members")
def remove_member(company_id, membership_id):
    company = g.company
    membership = CompanyMembership.query.filter_by(id=membership_id, company_id=company.id).first()
    if membership is None:
        abort(404)

    if membership.role == "owner":
        remaining_owners = CompanyMembership.query.filter_by(
            company_id=company.id, role="owner"
        ).count()
        if remaining_owners <= 1:
            flash("A company must always have at least one owner.", "danger")
            return redirect(url_for("companies.users_page", company_id=company.public_id))

    db.session.delete(membership)
    log_action(company, current_user, "member_removed", f"{membership.user.email} ({membership.role})")
    db.session.commit()
    flash("Member removed.", "info")
    return redirect(url_for("companies.users_page", company_id=company.public_id))


@bp.route("/<company_id>/invites/<int:invite_id>/revoke", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_members")
def revoke_invite(company_id, invite_id):
    company = g.company
    invite = CompanyInvite.query.filter_by(id=invite_id, company_id=company.id).first()
    if invite is None:
        abort(404)
    invite.revoked = True
    db.session.commit()
    flash("Invite revoked.", "info")
    return redirect(url_for("companies.users_page", company_id=company.public_id))


@bp.route("/<company_id>/users")
@login_required
@load_company_context
@permission_required("manage_members")
def users_page(company_id):
    """Dedicated User Management page — the member list, pending invites,
    and invite form used to live inline on the company home page; they're
    consolidated and expanded here (role changes, removal, PIN reset, and
    the company's PIN expiry policy all in one place) so company home
    isn't cluttered and this has its own clear nav entry."""
    company = g.company
    members = CompanyMembership.query.filter_by(company_id=company.id).order_by(
        CompanyMembership.role, CompanyMembership.created_at
    ).all()
    pending_invites = CompanyInvite.query.filter_by(
        company_id=company.id, accepted_at=None, revoked=False
    ).order_by(CompanyInvite.created_at.desc()).all()
    return render_template(
        "companies/users.html", company=company, members=members,
        pending_invites=pending_invites, role=g.company_role,
        company_roles=COMPANY_ROLES, pin_expiry_presets=PIN_EXPIRY_PRESETS_DAYS,
    )


@bp.route("/<company_id>/users/<int:membership_id>/reset-pin", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_members")
def reset_member_pin(company_id, membership_id):
    """Doesn't set a specific PIN — an admin choosing the PIN value would
    be a shared-secret the admin also knows, defeating the point.
    Instead this just flags pin_must_change, so the user picks their own
    new PIN (gated by the usual before_request hook) the next time they
    access anything."""
    company = g.company
    membership = CompanyMembership.query.filter_by(id=membership_id, company_id=company.id).first()
    if membership is None:
        abort(404)
    membership.user.pin_must_change = True
    log_action(company, current_user, "member_pin_reset", membership.user.email)
    db.session.commit()
    flash(
        f"PIN reset for {membership.user.email} — they'll be asked to set a new one "
        "next time they access the system.",
        "success",
    )
    return redirect(url_for("companies.users_page", company_id=company.public_id))


@bp.route("/<company_id>/pin-policy", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_members")
def update_pin_policy(company_id):
    company = g.company
    choice = request.form.get("pin_expiry_choice", "")
    custom_days = request.form.get("pin_expiry_custom_days", "").strip()

    if choice in PIN_EXPIRY_PRESETS_DAYS:
        company.pin_expiry_days = PIN_EXPIRY_PRESETS_DAYS[choice]
    elif choice == "custom" and custom_days.isdigit() and int(custom_days) > 0:
        company.pin_expiry_days = int(custom_days)
    else:
        flash("Choose a valid expiry period (or enter a custom number of days).", "danger")
        return redirect(url_for("companies.users_page", company_id=company.public_id))

    log_action(company, current_user, "pin_policy_updated", f"expiry now {company.pin_expiry_days} days")
    db.session.commit()
    flash(f"PIN expiry policy updated — PINs now expire after {company.pin_expiry_days} days.", "success")
    return redirect(url_for("companies.users_page", company_id=company.public_id))


@bp.route("/accept-invite/<token>", methods=["GET", "POST"])
@login_required
def accept_invite(token):
    invite = CompanyInvite.query.filter_by(token=token, revoked=False, accepted_at=None).first()
    if invite is None:
        flash("That invite is invalid, expired, or already used.", "danger")
        return redirect(url_for("dashboard.index"))

    if current_user.email != invite.email:
        flash(
            f"This invite was sent to {invite.email}. Log in with that address to accept it.",
            "warning",
        )
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        if current_user.role_in(invite.company_id) is None:
            membership = CompanyMembership(
                user_id=current_user.id, company_id=invite.company_id, role=invite.role
            )
            db.session.add(membership)
        invite.accepted_at = datetime.utcnow()
        db.session.commit()
        flash(f"You've joined {invite.company.name}.", "success")
        return redirect(url_for("companies.detail", company_id=invite.company.public_id))

    return render_template("companies/accept_invite.html", invite=invite)
