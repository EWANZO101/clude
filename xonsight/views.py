import math
from types import SimpleNamespace

from flask import Blueprint, abort, current_app, g, redirect, render_template, request, url_for
from flask_login import current_user

from .models import ActiveRecorder, Case, CommunityRequest, Evidence, User

views_bp = Blueprint("views", __name__)

# Routes that stay control-plane-only (see tenant_resolve.py) - hit directly
# by URL while a tenant is resolved, they redirect to the dashboard instead
# of silently showing the main portal's control-plane data under someone
# else's community subdomain.
_CONTROL_PLANE_ONLY = {
    "views.cases_list",
    "views.case_detail",
    "views.assistant",
    "views.community_list",
    "views.community_detail",
    "views.analytics",
}


@views_bp.before_request
def require_login():
    if not current_user.is_authenticated:
        return redirect(url_for("auth.login", next=request.path))
    if g.tenant is not None and request.endpoint in _CONTROL_PLANE_ONLY:
        return redirect(url_for("views.dashboard"))


def _tenant_paginate(query, page, per_page):
    """Stand-in for Flask-SQLAlchemy's .paginate() - g.tenant_session is a
    plain SQLAlchemy scoped_session (tenancy.py), which doesn't have it."""
    total = query.count()
    items = query.offset((page - 1) * per_page).limit(per_page).all()
    pages = max(1, math.ceil(total / per_page))
    return SimpleNamespace(
        items=items,
        total=total,
        page=page,
        pages=pages,
        has_prev=page > 1,
        has_next=page < pages,
        prev_num=page - 1,
        next_num=page + 1,
    )


@views_bp.route("/dashboard")
def dashboard():
    if g.tenant is not None:
        recent = g.tenant_session.query(Evidence).order_by(Evidence.id.desc()).limit(6).all()
        total_evidence = g.tenant_session.query(Evidence).count()
        active_recorders = g.tenant_session.query(ActiveRecorder).count()
    else:
        recent = Evidence.query.order_by(Evidence.id.desc()).limit(6).all()
        total_evidence = Evidence.query.count()
        active_recorders = ActiveRecorder.query.count()
    return render_template(
        "dashboard.html",
        recent=recent,
        total_evidence=total_evidence,
        active_recorders=active_recorders,
    )


@views_bp.route("/evidence")
def evidence_list():
    q = request.args.get("q", "").strip()
    page = request.args.get("page", 1, type=int)

    if g.tenant is not None:
        query = g.tenant_session.query(Evidence)
        if q:
            like = f"%{q}%"
            query = query.filter((Evidence.submitter_name.ilike(like)) | (Evidence.caption.ilike(like)))
        pagination = _tenant_paginate(query.order_by(Evidence.id.desc()), page, 12)
    else:
        query = Evidence.query
        if q:
            like = f"%{q}%"
            query = query.filter(
                (Evidence.submitter_name.ilike(like)) | (Evidence.caption.ilike(like))
            )
        pagination = query.order_by(Evidence.id.desc()).paginate(
            page=page, per_page=12, error_out=False
        )
    return render_template("evidence_list.html", pagination=pagination, q=q)


@views_bp.route("/evidence/<int:evidence_id>")
def evidence_detail(evidence_id):
    if g.tenant is not None:
        item = g.tenant_session.query(Evidence).get(evidence_id)
    else:
        item = Evidence.query.get(evidence_id)
    if item is None:
        abort(404)
    return render_template(
        "evidence_detail.html",
        item=item,
        item_json=item.to_dict(),
        agency_name=current_app.config.get("AGENCY_NAME", "Unconfigured Agency"),
        ai_configured=bool(current_app.config.get("ANTHROPIC_API_KEY")),
    )


@views_bp.route("/live")
def live():
    return render_template("live.html")


@views_bp.route("/cases")
def cases_list():
    status = request.args.get("status", "")
    query = Case.query
    if status:
        query = query.filter_by(status=status)
    cases = query.order_by(Case.updated_at.desc()).all()
    return render_template("cases_list.html", cases=cases, status=status)


@views_bp.route("/cases/<int:case_id>")
def case_detail(case_id):
    case = Case.query.get(case_id)
    if case is None:
        abort(404)
    return render_template("case_detail.html", case=case)


@views_bp.route("/assistant")
def assistant():
    return render_template(
        "assistant.html",
        ai_configured=bool(current_app.config.get("ANTHROPIC_API_KEY")),
    )


@views_bp.route("/community")
def community_list():
    return render_template("community_list.html")


@views_bp.route("/community/<int:request_id>")
def community_detail(request_id):
    req = CommunityRequest.query.get(request_id)
    if req is None:
        abort(404)
    creator = User.query.get(req.created_by_id) if req.created_by_id else None
    return render_template("community_detail.html", req=req, created_by_username=creator.username if creator else None)


@views_bp.route("/analytics")
def analytics():
    return render_template("analytics.html")
