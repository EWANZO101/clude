from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app.extensions import db
from app.models.business import Business, Membership, ROLE_OWNER
from app.models.accounting import create_default_chart_of_accounts
from app.models.invitation import Invitation, STATUS_PENDING, STATUS_ACCEPTED

businesses_bp = Blueprint("businesses", __name__, template_folder="../templates/businesses")


@businesses_bp.route("/")
@login_required
def list_businesses():
    return render_template("businesses/list.html", businesses=current_user.businesses())


@businesses_bp.route("/new", methods=["GET", "POST"])
@login_required
def new_business():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        currency = request.form.get("base_currency", "USD").strip().upper() or "USD"
        if not name:
            flash("Business name is required.", "error")
            return render_template("businesses/new.html")

        business = Business(name=name, base_currency=currency)
        db.session.add(business)
        db.session.flush()

        db.session.add(Membership(user_id=current_user.id, business_id=business.id, role=ROLE_OWNER))
        create_default_chart_of_accounts(business)

        current_user.current_business_id = business.id
        db.session.commit()

        flash(f"Business '{business.name}' created.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("businesses/new.html")


@businesses_bp.route("/switch/<business_id>", methods=["POST"])
@login_required
def switch_business(business_id):
    if current_user.role_in_id(business_id) if hasattr(current_user, "role_in_id") else None:
        pass
    membership = next((m for m in current_user.memberships if m.business_id == business_id), None)
    if membership is None:
        flash("You do not have access to that business.", "error")
        return redirect(url_for("businesses.list_businesses"))

    current_user.current_business_id = business_id
    db.session.commit()
    flash(f"Switched to {membership.business.name}.", "success")
    return redirect(url_for("dashboard.index"))


@businesses_bp.route("/<business_id>/archive", methods=["POST"])
@login_required
def archive_business(business_id):
    membership = next((m for m in current_user.memberships if m.business_id == business_id), None)
    if membership is None or membership.role != "owner":
        flash("Only the owner can archive this business.", "error")
        return redirect(url_for("businesses.list_businesses"))

    membership.business.is_archived = True
    db.session.commit()
    flash("Business archived.", "success")
    return redirect(url_for("businesses.list_businesses"))

@businesses_bp.route("/<business_id>/team")
@login_required
def team(business_id):
    membership = next((m for m in current_user.memberships if m.business_id == business_id), None)
    if membership is None:
        flash("You do not have access to that business.", "error")
        return redirect(url_for("businesses.list_businesses"))

    business = membership.business
    invitations = Invitation.query.filter_by(business_id=business_id, status=STATUS_PENDING).all()
    return render_template("businesses/team.html", business=business, invitations=invitations)


@businesses_bp.route("/<business_id>/team/invite", methods=["POST"])
@login_required
def invite_team_member(business_id):
    membership = next((m for m in current_user.memberships if m.business_id == business_id), None)
    if membership is None or membership.role not in ("owner", "admin"):
        flash("Only an owner or admin can invite team members.", "error")
        return redirect(url_for("businesses.team", business_id=business_id))

    from app.models.business import ALL_ROLES
    email = request.form.get("email", "").strip().lower()
    role = request.form.get("role", "employee")
    if not email or role not in ALL_ROLES:
        flash("A valid email and role are required.", "error")
        return redirect(url_for("businesses.team", business_id=business_id))

    invite = Invitation(business_id=business_id, invited_by_id=current_user.id, email=email, role=role)
    db.session.add(invite)
    db.session.commit()

    # In production this would send an email with the accept link
    # (/businesses/invitations/<token>/accept). Kept as a visible link here
    # since Phase 6 doesn't wire up an email provider.
    flash(f"Invitation created for {email}. Accept link: /businesses/invitations/{invite.token}/accept", "success")
    return redirect(url_for("businesses.team", business_id=business_id))


@businesses_bp.route("/invitations/<token>/accept")
@login_required
def accept_invitation(token):
    invite = Invitation.query.filter_by(token=token).first_or_404()
    if not invite.is_valid():
        flash("This invitation is no longer valid.", "error")
        return redirect(url_for("businesses.list_businesses"))

    existing = next((m for m in current_user.memberships if m.business_id == invite.business_id), None)
    if existing is None:
        db.session.add(Membership(user_id=current_user.id, business_id=invite.business_id, role=invite.role))
    invite.status = STATUS_ACCEPTED
    current_user.current_business_id = invite.business_id
    db.session.commit()

    flash(f"You've joined {invite.business.name} as {invite.role}.", "success")
    return redirect(url_for("dashboard.index"))


@businesses_bp.route("/<business_id>/team/<invitation_id>/revoke", methods=["POST"])
@login_required
def revoke_invitation(business_id, invitation_id):
    membership = next((m for m in current_user.memberships if m.business_id == business_id), None)
    if membership is None or membership.role not in ("owner", "admin"):
        flash("Only an owner or admin can revoke invitations.", "error")
        return redirect(url_for("businesses.team", business_id=business_id))

    from app.models.invitation import STATUS_REVOKED
    invite = Invitation.query.filter_by(id=invitation_id, business_id=business_id).first_or_404()
    invite.status = STATUS_REVOKED
    db.session.commit()
    flash("Invitation revoked.", "success")
    return redirect(url_for("businesses.team", business_id=business_id))

