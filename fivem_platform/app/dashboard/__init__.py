from flask import Blueprint, render_template
from flask_login import login_required, current_user

dashboard_bp = Blueprint(
    "dashboard", __name__, template_folder="templates"
)


@dashboard_bp.route("/")
@login_required
def index():
    from app.models.developer import TeamMember

    pending_invites = TeamMember.query.filter_by(
        member_user_id=current_user.id, accepted_at=None
    ).all()

    return render_template("dashboard/index.html", user=current_user, pending_invites=pending_invites)
