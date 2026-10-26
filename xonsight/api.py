import os
from datetime import datetime, timedelta

import queue

from flask import Blueprint, Response, abort, current_app, g, jsonify, request, send_from_directory, stream_with_context
from flask_login import current_user

from . import ai, discord, realtime
from .extensions import db
from .live_tokens import sign_viewer_token
from .models import (
    ActiveRecorder,
    Alert,
    Bolo,
    Case,
    CaseAuditEntry,
    CaseEvidence,
    CaseNote,
    Clip,
    CommunityRequest,
    CommunitySubmission,
    Evidence,
    ExternalFeed,
    LiveStream,
    Marker,
)

api_bp = Blueprint("api", __name__, url_prefix="/api")


@api_bp.before_request
def require_login():
    if not current_user.is_authenticated:
        return jsonify({"error": "authentication required"}), 401


# --- Evidence -------------------------------------------------------------


@api_bp.route("/evidence")
def list_evidence():
    """Read-only, same-origin JSON used by the dashboard's polling JS."""
    after_id = request.args.get("after_id", type=int)
    limit = min(request.args.get("limit", 20, type=int), 100)

    query = Evidence.query.order_by(Evidence.id.desc())
    if after_id:
        query = query.filter(Evidence.id > after_id)

    items = query.limit(limit).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.route("/evidence/<int:evidence_id>/related")
def related_evidence(evidence_id):
    """Other evidence recorded within `window` seconds of this item, for the
    multicam picker - "same scene" is approximated by capture time since
    Xon Sight doesn't carry a location/incident id on the webhook payload."""
    item = Evidence.query.get_or_404(evidence_id)
    window = min(request.args.get("window", 600, type=int), 3600)
    lo = item.created_at - timedelta(seconds=window)
    hi = item.created_at + timedelta(seconds=window)

    others = (
        Evidence.query.filter(Evidence.id != item.id)
        .filter(Evidence.created_at.between(lo, hi))
        .order_by(Evidence.created_at.asc())
        .limit(12)
        .all()
    )
    return jsonify([o.to_dict() for o in others])


@api_bp.route("/evidence/<int:evidence_id>/notes", methods=["GET", "POST"])
def evidence_notes(evidence_id):
    item = Evidence.query.get_or_404(evidence_id)

    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        body = (data.get("body") or "").strip()
        if not body:
            return jsonify({"error": "body is required"}), 400
        note = CaseNote(
            evidence_id=item.id,
            author=(data.get("author") or "Unknown").strip()[:128],
            body=body[:4000],
        )
        db.session.add(note)
        db.session.commit()
        return jsonify(note.to_dict()), 201

    notes = CaseNote.query.filter_by(evidence_id=item.id).order_by(CaseNote.created_at.asc()).all()
    return jsonify([n.to_dict() for n in notes])


@api_bp.route("/evidence/<int:evidence_id>/transcript", methods=["PATCH"])
def update_transcript(evidence_id):
    item = Evidence.query.get_or_404(evidence_id)
    data = request.get_json(silent=True) or {}
    item.transcript = (data.get("transcript") or "")[:20000]
    db.session.commit()
    return jsonify({"ok": True, "transcript": item.transcript})


@api_bp.route("/evidence/<int:evidence_id>/device-serial", methods=["PATCH"])
def update_device_serial(evidence_id):
    item = Evidence.query.get_or_404(evidence_id)
    data = request.get_json(silent=True) or {}
    item.device_serial = (data.get("deviceSerial") or "")[:128]
    db.session.commit()
    return jsonify({"ok": True, "deviceSerial": item.device_serial})


@api_bp.route("/evidence/<int:evidence_id>/markers", methods=["GET", "POST"])
def evidence_markers(evidence_id):
    item = Evidence.query.get_or_404(evidence_id)

    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        try:
            ts = max(0.0, float(data.get("timestampSeconds")))
        except (TypeError, ValueError):
            return jsonify({"error": "timestampSeconds must be a number"}), 400
        marker = Marker(evidence_id=item.id, label=(data.get("label") or "Marker")[:255], timestamp_seconds=ts)
        db.session.add(marker)
        db.session.commit()
        return jsonify(marker.to_dict()), 201

    markers = (
        Marker.query.filter_by(evidence_id=item.id).order_by(Marker.timestamp_seconds.asc()).all()
    )
    return jsonify([m.to_dict() for m in markers])


@api_bp.route("/markers/<int:marker_id>", methods=["DELETE"])
def delete_marker(marker_id):
    marker = Marker.query.get_or_404(marker_id)
    db.session.delete(marker)
    db.session.commit()
    return jsonify({"ok": True})


@api_bp.route("/evidence/<int:evidence_id>/clips", methods=["GET", "POST"])
def evidence_clips(evidence_id):
    item = Evidence.query.get_or_404(evidence_id)

    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        try:
            start = max(0.0, float(data.get("startSeconds")))
            end = max(start + 0.1, float(data.get("endSeconds")))
        except (TypeError, ValueError):
            return jsonify({"error": "startSeconds/endSeconds must be numbers"}), 400
        clip = Clip(
            evidence_id=item.id,
            label=(data.get("label") or "Clip")[:255],
            start_seconds=start,
            end_seconds=end,
        )
        db.session.add(clip)
        db.session.commit()
        return jsonify(clip.to_dict()), 201

    clips = Clip.query.filter_by(evidence_id=item.id).order_by(Clip.start_seconds.asc()).all()
    return jsonify([c.to_dict() for c in clips])


@api_bp.route("/clips/<int:clip_id>", methods=["DELETE"])
def delete_clip(clip_id):
    clip = Clip.query.get_or_404(clip_id)
    db.session.delete(clip)
    db.session.commit()
    return jsonify({"ok": True})


# --- Live / Respond --------------------------------------------------------


@api_bp.route("/recorders")
def list_recorders():
    if g.tenant is not None:
        items = g.tenant_session.query(ActiveRecorder).order_by(ActiveRecorder.name.asc()).all()
    else:
        items = ActiveRecorder.query.order_by(ActiveRecorder.name.asc()).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.route("/live-streams")
def list_live_streams():
    """Active MediaMTX broadcasts for the /live page's video panel. Each
    entry carries ready-to-use, time-limited WHEP/HLS URLs - a viewer
    token signed fresh per request (live_tokens.sign_viewer_token) - so
    the browser never needs to know MediaMTX's layout or sign anything
    itself. Stale rows (no heartbeat in LIVE_STREAM_STALE_SECONDS) are
    left out entirely rather than shown greyed-out: a stream that stopped
    uncleanly (crash, disconnect) should just disappear, same as
    ActiveRecorder does for the position map."""
    if g.tenant is not None:
        items = g.tenant_session.query(LiveStream).order_by(LiveStream.started_at.asc()).all()
    else:
        items = LiveStream.query.order_by(LiveStream.started_at.asc()).all()

    whep_base = (current_app.config.get("MEDIAMTX_WHEP_URL") or "").rstrip("/")
    hls_base = (current_app.config.get("MEDIAMTX_HLS_URL") or "").rstrip("/")

    out = []
    for item in items:
        d = item.to_dict()
        if d.pop("isStale"):
            continue
        token = sign_viewer_token(item.path)
        d["whepUrl"] = f"{whep_base}/{item.path}/whep?token={token}" if whep_base else None
        d["hlsUrl"] = f"{hls_base}/{item.path}/index.m3u8?token={token}" if hls_base else None
        out.append(d)
    return jsonify(out)


@api_bp.route("/external-feeds")
def list_external_feeds():
    if g.tenant is not None:
        items = g.tenant_session.query(ExternalFeed).order_by(ExternalFeed.label.asc()).all()
    else:
        items = ExternalFeed.query.order_by(ExternalFeed.label.asc()).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.route("/alerts")
def list_alerts():
    if g.tenant is not None:
        query = g.tenant_session.query(Alert)
    else:
        query = Alert.query
    if request.args.get("unacknowledged") == "1":
        query = query.filter_by(acknowledged=False)
    items = query.order_by(Alert.created_at.desc()).limit(50).all()
    return jsonify([a.to_dict() for a in items])


@api_bp.route("/alerts/<int:alert_id>/ack", methods=["POST"])
def ack_alert(alert_id):
    if g.tenant is not None:
        alert = g.tenant_session.query(Alert).get(alert_id)
        if alert is None:
            abort(404)
        alert.acknowledged = True
        alert.acknowledged_at = datetime.utcnow()
        g.tenant_session.commit()
        return jsonify(alert.to_dict())
    alert = Alert.query.get_or_404(alert_id)
    alert.acknowledged = True
    alert.acknowledged_at = datetime.utcnow()
    db.session.commit()
    return jsonify(alert.to_dict())


# --- Cases (lightweight records wrapper) -----------------------------------


@api_bp.route("/cases", methods=["GET", "POST"])
def cases_collection():
    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        title = (data.get("title") or "").strip()
        if not title:
            return jsonify({"error": "title is required"}), 400
        case = Case(title=title[:255])
        db.session.add(case)
        db.session.commit()
        realtime.publish("case.created", case=case.to_dict())
        return jsonify(case.to_dict()), 201

    status = request.args.get("status")
    query = Case.query
    if status:
        query = query.filter_by(status=status)
    cases = query.order_by(Case.updated_at.desc()).all()
    return jsonify([c.to_dict() for c in cases])


@api_bp.route("/cases/<int:case_id>")
def case_detail(case_id):
    case = Case.query.get_or_404(case_id)
    links = CaseEvidence.query.filter_by(case_id=case.id).order_by(CaseEvidence.added_at.asc()).all()
    evidence_items = [Evidence.query.get(link.evidence_id) for link in links]
    audit = CaseAuditEntry.query.filter_by(case_id=case.id).order_by(CaseAuditEntry.created_at.asc()).all()

    payload = case.to_dict()
    payload["evidence"] = [e.to_dict() for e in evidence_items if e is not None]
    payload["audit"] = [a.to_dict() for a in audit]
    return jsonify(payload)


@api_bp.route("/cases/<int:case_id>/status", methods=["PATCH"])
def update_case_status(case_id):
    case = Case.query.get_or_404(case_id)
    data = request.get_json(silent=True) or {}
    new_status = (data.get("status") or "").strip()
    if new_status not in ("open", "under_review", "closed"):
        return jsonify({"error": "status must be open, under_review, or closed"}), 400

    entry = CaseAuditEntry(
        case_id=case.id,
        from_status=case.status,
        to_status=new_status,
        note=(data.get("note") or "")[:255],
        author=(data.get("author") or "Unknown").strip()[:128],
    )
    case.status = new_status
    case.updated_at = datetime.utcnow()
    db.session.add(entry)
    db.session.commit()
    return jsonify(case.to_dict())


@api_bp.route("/cases/<int:case_id>/evidence", methods=["POST"])
def add_case_evidence(case_id):
    case = Case.query.get_or_404(case_id)
    data = request.get_json(silent=True) or {}
    evidence_id = data.get("evidenceId")
    evidence = Evidence.query.get_or_404(evidence_id) if evidence_id is not None else None
    if evidence is None:
        return jsonify({"error": "evidenceId is required"}), 400

    exists = CaseEvidence.query.filter_by(case_id=case.id, evidence_id=evidence.id).first()
    if exists is None:
        db.session.add(CaseEvidence(case_id=case.id, evidence_id=evidence.id))
        case.updated_at = datetime.utcnow()
        db.session.commit()
    return jsonify({"ok": True})


@api_bp.route("/cases/<int:case_id>/evidence/<int:evidence_id>", methods=["DELETE"])
def remove_case_evidence(case_id, evidence_id):
    link = CaseEvidence.query.filter_by(case_id=case_id, evidence_id=evidence_id).first()
    if link is not None:
        db.session.delete(link)
        db.session.commit()
    return jsonify({"ok": True})


# --- AI features (Draft One / Brief One / Axon Assistant analogs) --------


@api_bp.route("/ai/status")
def ai_status():
    return jsonify({"configured": bool(current_app.config.get("ANTHROPIC_API_KEY"))})


@api_bp.route("/evidence/<int:evidence_id>/draft", methods=["POST"])
def generate_draft(evidence_id):
    item = Evidence.query.get_or_404(evidence_id)
    notes = [
        n.to_dict()
        for n in CaseNote.query.filter_by(evidence_id=item.id).order_by(CaseNote.created_at.asc()).all()
    ]
    ok, text = ai.draft_report(item.to_dict(), notes)
    if not ok:
        return jsonify({"ok": False, "error": text}), 503
    return jsonify({"ok": True, "content": text, "modelUsed": current_app.config.get("AI_MODEL")})


@api_bp.route("/evidence/<int:evidence_id>/brief", methods=["POST"])
def generate_brief(evidence_id):
    item = Evidence.query.get_or_404(evidence_id)
    notes = [
        n.to_dict()
        for n in CaseNote.query.filter_by(evidence_id=item.id).order_by(CaseNote.created_at.asc()).all()
    ]
    markers = [
        m.to_dict()
        for m in Marker.query.filter_by(evidence_id=item.id).order_by(Marker.timestamp_seconds.asc()).all()
    ]
    ok, summary, milestones = ai.brief_video(item.to_dict(), notes, markers)
    if not ok:
        return jsonify({"ok": False, "error": summary}), 503
    return jsonify(
        {
            "ok": True,
            "summary": summary,
            "milestones": milestones,
            "modelUsed": current_app.config.get("AI_MODEL"),
        }
    )


@api_bp.route("/assistant/ask", methods=["POST"])
def assistant_ask():
    data = request.get_json(silent=True) or {}
    message = (data.get("message") or "").strip()
    if not message:
        return jsonify({"error": "message is required"}), 400

    history = data.get("history") or []
    safe_history = [
        {"role": h.get("role"), "content": h.get("content")}
        for h in history
        if h.get("role") in ("user", "assistant") and h.get("content")
    ][-10:]

    context = {
        "recentEvidence": [
            {"id": e.id, "officer": e.submitter_name, "caption": e.caption, "recordedAt": e.created_at.isoformat()}
            for e in Evidence.query.order_by(Evidence.id.desc()).limit(10).all()
        ],
        "openCases": [c.to_dict() for c in Case.query.filter(Case.status != "closed").order_by(Case.updated_at.desc()).limit(10).all()],
        "activeBolos": [b.to_dict() for b in Bolo.query.filter_by(active=True).order_by(Bolo.created_at.desc()).limit(10).all()],
    }

    ok, text = ai.assistant_reply(message, safe_history, context)
    if not ok:
        return jsonify({"ok": False, "error": text}), 503
    return jsonify({"ok": True, "reply": text})


@api_bp.route("/bolos", methods=["GET", "POST"])
def bolos_collection():
    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        subject = (data.get("subject") or "").strip()
        if not subject:
            return jsonify({"error": "subject is required"}), 400
        bolo = Bolo(
            subject=subject[:255],
            details=(data.get("details") or "")[:4000],
            author=(data.get("author") or "Unknown").strip()[:128],
        )
        db.session.add(bolo)
        db.session.commit()
        realtime.publish("bolo.created", bolo=bolo.to_dict())
        try:
            discord.notify_bolo(bolo)
        except Exception:
            current_app.logger.exception("Discord notify failed for BOLO #%s", bolo.id)
        return jsonify(bolo.to_dict()), 201

    bolos = Bolo.query.filter_by(active=True).order_by(Bolo.created_at.desc()).limit(50).all()
    return jsonify([b.to_dict() for b in bolos])


@api_bp.route("/bolos/<int:bolo_id>/resolve", methods=["POST"])
def resolve_bolo(bolo_id):
    bolo = Bolo.query.get_or_404(bolo_id)
    bolo.active = False
    db.session.commit()
    return jsonify(bolo.to_dict())


@api_bp.route("/assistant/draft-bolo", methods=["POST"])
def assistant_draft_bolo():
    data = request.get_json(silent=True) or {}
    notes = (data.get("notes") or "").strip()
    if not notes:
        return jsonify({"error": "notes is required"}), 400
    ok, result = ai.draft_bolo(notes)
    if not ok:
        return jsonify({"ok": False, "error": result.get("details", "AI request failed")}), 503
    return jsonify({"ok": True, **result})


# --- Community requests (Axon Community Request analog) -------------------


@api_bp.route("/community/requests", methods=["GET", "POST"])
def community_requests_collection():
    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        title = (data.get("title") or "").strip()
        if not title:
            return jsonify({"error": "title is required"}), 400

        case_id = data.get("caseId") or None
        if case_id is not None:
            Case.query.get_or_404(case_id)

        req = CommunityRequest(
            reference_code=CommunityRequest.generate_reference_code(),
            title=title[:255],
            description=(data.get("description") or "")[:4000],
            category=(data.get("category") or "General")[:64],
            instructions=(data.get("instructions") or "")[:500],
            case_id=case_id,
            requires_consent=bool(data.get("requiresConsent", True)),
            created_by_id=current_user.id,
        )
        db.session.add(req)
        db.session.commit()
        return jsonify(req.to_dict()), 201

    items = CommunityRequest.query.order_by(CommunityRequest.created_at.desc()).all()
    return jsonify([r.to_dict() for r in items])


@api_bp.route("/community/requests/<int:request_id>")
def community_request_detail(request_id):
    req = CommunityRequest.query.get_or_404(request_id)
    submissions = (
        CommunitySubmission.query.filter_by(request_id=req.id)
        .order_by(CommunitySubmission.submitted_at.desc())
        .all()
    )
    payload = req.to_dict()
    payload["submissions"] = [s.to_dict() for s in submissions]
    return jsonify(payload)


@api_bp.route("/community/requests/<int:request_id>/toggle", methods=["POST"])
def toggle_community_request(request_id):
    req = CommunityRequest.query.get_or_404(request_id)
    req.status = "closed" if req.status == "open" else "open"
    db.session.commit()
    return jsonify(req.to_dict())


@api_bp.route("/community/requests/<int:request_id>", methods=["DELETE"])
def delete_community_request(request_id):
    req = CommunityRequest.query.get_or_404(request_id)
    if req.is_general:
        return jsonify({"error": "the general tip line can't be deleted - close it instead"}), 400
    CommunitySubmission.query.filter_by(request_id=req.id).delete()
    db.session.delete(req)
    db.session.commit()
    return jsonify({"ok": True})


@api_bp.route("/community/submissions/<int:submission_id>/review", methods=["POST"])
def toggle_submission_reviewed(submission_id):
    sub = CommunitySubmission.query.get_or_404(submission_id)
    sub.reviewed = not sub.reviewed
    db.session.commit()
    return jsonify(sub.to_dict())


@api_bp.route("/community/submissions/<int:submission_id>/file")
def community_submission_file(submission_id):
    sub = CommunitySubmission.query.get_or_404(submission_id)
    if not sub.file_path:
        abort(404)
    folder = os.path.join(current_app.instance_path, "community_uploads")
    return send_from_directory(folder, sub.file_path)


# --- Analytics ---------------------------------------------------------------
# Control-plane only for now - same scope boundary as the rest of this file
# before multi-tenancy reaches the browser-facing app. SQLite-specific
# (strftime for day-grouping); revisit if/when this needs to run against a
# tenant's MySQL database too.


@api_bp.route("/analytics/summary")
def analytics_summary():
    since_30d = datetime.utcnow() - timedelta(days=30)
    return jsonify(
        {
            "totalEvidence": Evidence.query.count(),
            "activeRecorders": ActiveRecorder.query.count(),
            "openCases": Case.query.filter(Case.status != "closed").count(),
            "activeBolos": Bolo.query.filter_by(active=True).count(),
            "pendingSubmissions": CommunitySubmission.query.filter_by(reviewed=False).count(),
            "alerts30d": Alert.query.filter(Alert.created_at >= since_30d).count(),
        }
    )


@api_bp.route("/analytics/evidence-per-day")
def analytics_evidence_per_day():
    days = min(request.args.get("days", 30, type=int), 90)
    since = datetime.utcnow() - timedelta(days=days - 1)
    since_midnight = since.replace(hour=0, minute=0, second=0, microsecond=0)

    rows = (
        db.session.query(
            db.func.strftime("%Y-%m-%d", Evidence.created_at).label("day"),
            db.func.count(Evidence.id),
        )
        .filter(Evidence.created_at >= since_midnight)
        .group_by("day")
        .all()
    )
    counts = {day: count for day, count in rows}

    series = []
    for i in range(days):
        d = (since_midnight + timedelta(days=i)).date()
        key = d.isoformat()
        series.append({"date": key, "count": counts.get(key, 0)})
    return jsonify(series)


@api_bp.route("/analytics/alerts-by-type")
def analytics_alerts_by_type():
    days = min(request.args.get("days", 30, type=int), 90)
    since = datetime.utcnow() - timedelta(days=days)
    rows = (
        db.session.query(Alert.alert_type, db.func.count(Alert.id))
        .filter(Alert.created_at >= since)
        .group_by(Alert.alert_type)
        .order_by(db.func.count(Alert.id).desc())
        .all()
    )
    return jsonify([{"type": t or "unknown", "count": c} for t, c in rows])


@api_bp.route("/analytics/top-officers")
def analytics_top_officers():
    days = min(request.args.get("days", 30, type=int), 90)
    limit = min(request.args.get("limit", 8, type=int), 20)
    since = datetime.utcnow() - timedelta(days=days)
    rows = (
        db.session.query(Evidence.submitter_name, db.func.count(Evidence.id))
        .filter(Evidence.created_at >= since)
        .filter(Evidence.submitter_name != "")
        .group_by(Evidence.submitter_name)
        .order_by(db.func.count(Evidence.id).desc())
        .limit(limit)
        .all()
    )
    return jsonify([{"name": n, "count": c} for n, c in rows])


@api_bp.route("/analytics/case-status")
def analytics_case_status():
    rows = db.session.query(Case.status, db.func.count(Case.id)).group_by(Case.status).all()
    counts = {status: count for status, count in rows}
    return jsonify(
        {
            "open": counts.get("open", 0),
            "underReview": counts.get("under_review", 0),
            "closed": counts.get("closed", 0),
        }
    )


# --- Real-time stream (SSE) -------------------------------------------------
#
# See realtime.py for why this is SSE, not WebSockets, and the control-plane
# scope boundary. One GET per open browser tab, held open indefinitely -
# requires app.py's threaded=True so one subscriber can't block every other
# request in this process.


@api_bp.route("/stream")
def stream():
    def gen():
        q = realtime.subscribe()
        try:
            yield ": connected\n\n"
            while True:
                try:
                    payload = q.get(timeout=20)
                    yield f"data: {payload}\n\n"
                except queue.Empty:
                    yield ": ping\n\n"
        finally:
            realtime.unsubscribe(q)

    return Response(
        stream_with_context(gen()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
