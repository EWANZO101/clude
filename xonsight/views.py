import math
import os
from datetime import datetime, timedelta
from types import SimpleNamespace

from flask import Blueprint, abort, current_app, g, redirect, render_template, request, send_from_directory, url_for
from flask_login import current_user

from .live_tokens import verify_viewer_token
from .media_storage import FILENAME_RE, media_dir_for_slug, signed_media_url
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
    if request.endpoint == "views.media_file":
        # Checks its own auth (a signed token, or a session) - see media_file() below. A blanket
        # redirect-to-login here would be it anyway, since a bare <video src="..."> can never follow
        # an interactive login redirect.
        return
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


@views_bp.route("/media/<filename>")
def media_file(filename):
    """Serves evidence video uploaded through the portal-hosting path (see webhooks.py's
    /api/xonsight/media/upload and media_storage.py) - the alternative to self-hosting
    opslabs-bodycam's media/ folder yourself.

    Two ways in, checked in this order:
      1. A signed ?slug=...&xs_token=... pair (media_storage.signed_media_url, computed fresh on
         every evidence page render) - works regardless of login state or which host/subdomain the
         request came in on. Required for this to work at all across a community's own subdomain or
         custom domain: a bare <video> tag can't do an interactive login, and even a logged-in
         session's cookie may not carry over to a different host than the one evidence.video_url
         happens to be built from.
      2. Falling back to the ordinary logged-in session + g.tenant (same-host convenience - e.g.
         pasting this URL directly into a browser you're already logged into).
    One community can never reach another's files by guessing a filename either way - the token is
    bound to the exact (slug, filename) pair, and the session fallback only ever resolves to the
    viewer's own tenant.
    """
    if not FILENAME_RE.match(filename):
        abort(404)

    token = request.args.get("xs_token")
    requested_slug = request.args.get("slug") or ""
    if token and verify_viewer_token(f"media:{requested_slug}:{filename}", token):
        slug = requested_slug or None
    elif current_user.is_authenticated:
        slug = g.tenant.slug if g.tenant else None
    else:
        abort(401)

    directory = media_dir_for_slug(slug, create=False)
    if not os.path.isfile(os.path.join(directory, filename)):
        abort(404)
    return send_from_directory(directory, filename, mimetype="video/webm")


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
    today = datetime.utcnow().date()
    return render_template(
        "evidence_list.html", pagination=pagination, q=q, today=today, yesterday=today - timedelta(days=1),
    )


@views_bp.route("/evidence/<int:evidence_id>")
def evidence_detail(evidence_id):
    if g.tenant is not None:
        item = g.tenant_session.query(Evidence).get(evidence_id)
    else:
        item = Evidence.query.get(evidence_id)
    if item is None:
        abort(404)
    item_json = item.to_dict()
    item_json["videoUrl"] = signed_media_url(item_json["videoUrl"])
    return render_template(
        "evidence_detail.html",
        item=item,
        item_json=item_json,
        display_video_url=signed_media_url(item.video_url),
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
