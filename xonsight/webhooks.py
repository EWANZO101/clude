import hmac
import os
import re
import secrets
import threading
from datetime import datetime
from functools import wraps
from urllib.parse import parse_qs

from flask import Blueprint, current_app, g, jsonify, request

from . import discord, realtime, tenancy
from .extensions import db
from .live_tokens import verify_viewer_token
from .media_storage import FILENAME_RE, MAX_UPLOAD_BYTES, WEBM_MAGIC, is_plausible_video_url, media_dir_for_slug
from .models import ActiveRecorder, Alert, Community, Evidence, ExternalFeed, LiveStream, User

webhooks_bp = Blueprint("webhooks", __name__, url_prefix="/api/xonsight")

# sync_recorders() below does a per-row check-then-insert-or-update, then one commit for the
# whole batch - with the dev server's threaded=True, two near-simultaneous syncs (the periodic
# timer and the immediate push-on-start/stop the README describes both firing close together)
# can each see "no row yet" for the same recorder_id and both try to insert it, so the second
# commit dies on the recorder_id UNIQUE constraint and that whole sync is lost (dropped/stale
# officers on the Live page). This serializes the handler so that race can't happen.
_recorder_sync_lock = threading.Lock()
# Same check-then-insert race as above, on Evidence.remote_id this time: a genuine duplicate
# delivery or a retry landing while the original request is still mid-flight can hit the unique
# constraint and drop that evidence item's update instead of just updating it.
_evidence_lock = threading.Lock()
# Same pattern again, for LiveStream.recorder_id (live/start).
_live_stream_lock = threading.Lock()


def require_webhook_key(fn):
    """X-XonSight-Token: a per-community API token (xonsight/tenancy.py), issued at /integration.
    Valid -> g.community and g.session are set to that community's own MySQL-backed tenant
    session; every write in this request lands there, not in the control-plane database. A
    missing or unrecognized token is a hard 401.

    Every handler below must query/write through g.session, never the bare Model.query /
    db.session - that property is always bound to the control-plane database, so using it
    directly here would ignore the resolved tenant and read/write the wrong community's data.
    """

    @wraps(fn)
    def wrapper(*args, **kwargs):
        token = request.headers.get("X-XonSight-Token", "")
        community = Community.query.filter_by(api_token=token, status="active").first() if token else None
        if community is None:
            return jsonify({"error": "unauthorized"}), 401
        g.community = community
        g.session = tenancy.get_tenant_session(community)
        return fn(*args, **kwargs)

    return wrapper


def _parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return None


def _parse_started_at(value):
    """startedAt is unix seconds per website-integration-readme.md, but
    accepts an ISO string too for backwards compatibility with older
    xonsight-livesync builds."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.utcfromtimestamp(value)
        except (OverflowError, OSError, ValueError):
            return None
    return _parse_iso(value)


def _parse_last_frame(value):
    if not isinstance(value, dict):
        return None
    try:
        x = float(value["x"])
        y = float(value["y"])
        z = float(value["z"])
    except (KeyError, TypeError, ValueError):
        return None

    def _num(key, default=0.0):
        try:
            return float(value.get(key, default))
        except (TypeError, ValueError):
            return default

    return {
        "x": x,
        "y": y,
        "z": z,
        "heading": _num("heading"),
        "pitch": _num("pitch"),
        "fov": _num("fov", 50.0),
    }


@webhooks_bp.route("/evidence", methods=["POST"])
@require_webhook_key
def receive_evidence():
    """Matches evidence-api.md's required fields (id, submitterIdentifier,
    submitterName, caption, videoUrl, createdAt) plus one optional
    extension field: deviceSerial, when the sending resource already
    computes one (e.g. opslabs-bodycam's per-officer serial)."""
    data = request.get_json(silent=True) or {}

    remote_id = data.get("id")
    video_url = data.get("videoUrl")
    if remote_id is None or not video_url:
        return jsonify({"error": "id and videoUrl are required"}), 400
    if not is_plausible_video_url(video_url):
        # Catches a misconfigured Storage.PublicUrl before it gets stored and shown as "video
        # unavailable" forever - e.g. a stray '**.webm' left in from a copy-paste, once seen live.
        return jsonify({"error": "videoUrl doesn't look like a real http(s) address"}), 400

    with _evidence_lock:
        record = g.session.query(Evidence).filter_by(remote_id=remote_id).first()
        if record is None:
            record = Evidence(remote_id=remote_id)
            if g.community is None:
                # Control-plane path only: there's no portal login on the webhook, and no tenant-local
                # User table yet for a community's own database, so this only applies to the legacy path.
                admin = g.session.query(User).filter_by(role="admin").order_by(User.id.asc()).first()
                if admin is not None:
                    record.owner_id = admin.id
            g.session.add(record)

        record.submitter_identifier = data.get("submitterIdentifier") or ""
        record.submitter_name = data.get("submitterName") or ""
        record.caption = (data.get("caption") or "")[:255]
        record.video_url = video_url
        record.created_at = _parse_iso(data.get("createdAt")) or datetime.utcnow()
        # Never blanks an existing value - an investigator may have corrected it by hand in the Metadata tab, and an
        # omitted/blank field here (older bridge scripts, resources that don't compute one) shouldn't clobber that.
        device_serial = data.get("deviceSerial")
        if device_serial:
            record.device_serial = str(device_serial)[:128]

        g.session.commit()

    if g.community is None:
        realtime.publish("evidence.created", evidence=record.to_dict())

    try:
        discord.notify_evidence(record, community_id=g.community.id if g.community else None)
    except Exception:
        current_app.logger.exception("Discord notify failed for evidence #%s", record.id)

    return jsonify({"ok": True, "id": record.id}), 200


@webhooks_bp.route("/recorders/sync", methods=["POST"])
@require_webhook_key
def sync_recorders():
    """Extension endpoint (not part of Xon Sight's documented contract) -
    accepts a full snapshot of currently-active recorders:
    {"recorders": [{"id": "...", "name": "...", "job": "...", "startedAt": 169...,
    "lastFrame": {"x": ..., "y": ..., "z": ..., "heading": ..., "pitch": ..., "fov": ...} | null}],
    "syncedAt": 169...}
    `lastFrame` is a position/heading sample, never a video frame - see
    live-view.md. Anything missing from the snapshot is considered stopped
    and removed.
    """
    data = request.get_json(silent=True) or {}
    recorders = data.get("recorders", [])

    now = datetime.utcnow()
    seen_ids = set()

    with _recorder_sync_lock:
        for entry in recorders:
            recorder_id = str(entry.get("id", "")).strip()
            if not recorder_id:
                continue
            seen_ids.add(recorder_id)

            row = g.session.query(ActiveRecorder).filter_by(recorder_id=recorder_id).first()
            if row is None:
                row = ActiveRecorder(recorder_id=recorder_id)
                g.session.add(row)

            row.name = entry.get("name") or ""
            row.job = entry.get("job") or ""
            status = str(entry.get("status") or "recording").strip().lower()
            row.status = status if status in ("recording", "buffering") else "recording"
            started_at = _parse_started_at(entry.get("startedAt"))
            if started_at:
                row.started_at = started_at
            row.last_seen_at = now

            # lastFrame is absent right at recording start, or if
            # xonsight-livesync hasn't received a sample yet - keep whatever
            # position we last had rather than clearing it out.
            last_frame = _parse_last_frame(entry.get("lastFrame"))
            if last_frame is not None:
                row.last_frame_x = last_frame["x"]
                row.last_frame_y = last_frame["y"]
                row.last_frame_z = last_frame["z"]
                row.last_frame_heading = last_frame["heading"]
                row.last_frame_pitch = last_frame["pitch"]
                row.last_frame_fov = last_frame["fov"]

        g.session.query(ActiveRecorder).filter(ActiveRecorder.recorder_id.notin_(seen_ids)).delete(
            synchronize_session=False
        )

        g.session.commit()
    return jsonify({"ok": True, "count": len(seen_ids)}), 200


@webhooks_bp.route("/live/start", methods=["POST"])
@require_webhook_key
def live_start():
    """Extension endpoint - FiveM registers a new live (MediaMTX WHIP)
    broadcast: {"recorderId": "...", "kind": "dashcam"|"bodycam", "name":
    "...", "job": "...", "path": "..." (optional)}. Returns the MediaMTX
    path and a fresh publish_token; FiveM hands the token down to the NUI
    as the WHIP publish credential - see opslabs-bodycam's
    html/recorder.js Live module and the mediamtx_auth webhook below.
    Re-registering an already-live recorder_id rotates both the path and
    the token, so a stale client holding the old one can no longer
    publish."""
    data = request.get_json(silent=True) or {}
    recorder_id = str(data.get("recorderId", "")).strip()
    if not recorder_id:
        return jsonify({"error": "recorderId is required"}), 400

    kind = str(data.get("kind") or "dashcam").strip().lower()
    kind = kind if kind in ("dashcam", "bodycam") else "dashcam"
    safe_id = re.sub(r"[^a-z0-9]+", "-", recorder_id.lower()).strip("-") or "unit"
    path = str(data.get("path") or "").strip().lower() or f"{kind}-{safe_id}-{secrets.token_hex(3)}"
    path = re.sub(r"[^a-z0-9_-]", "", path)[:64] or f"{kind}-{secrets.token_hex(4)}"
    token = secrets.token_hex(24)

    with _live_stream_lock:
        row = g.session.query(LiveStream).filter_by(recorder_id=recorder_id).first()
        if row is None:
            row = LiveStream(recorder_id=recorder_id)
            g.session.add(row)
        row.path = path
        row.kind = kind
        row.name = (data.get("name") or "")[:128]
        row.job = (data.get("job") or "")[:64]
        row.publish_token = token
        row.started_at = datetime.utcnow()
        row.last_seen_at = datetime.utcnow()
        g.session.commit()

    if g.community is None:
        realtime.publish("live.started", stream=row.to_dict())

    return jsonify({"ok": True, "path": path, "token": token}), 200


@webhooks_bp.route("/live/heartbeat", methods=["POST"])
@require_webhook_key
def live_heartbeat():
    """Keeps a /live/start registration from going stale (LIVE_STREAM_STALE_SECONDS) -
    call every few seconds while a broadcast is up, same idea as
    recorders/sync's periodic push but for this separate table.
    {"recorderId": "..."}"""
    data = request.get_json(silent=True) or {}
    recorder_id = str(data.get("recorderId", "")).strip()
    if not recorder_id:
        return jsonify({"error": "recorderId is required"}), 400
    row = g.session.query(LiveStream).filter_by(recorder_id=recorder_id).first()
    if row is None:
        return jsonify({"ok": False, "reason": "not_live"}), 404
    row.last_seen_at = datetime.utcnow()
    g.session.commit()
    return jsonify({"ok": True}), 200


@webhooks_bp.route("/live/stop", methods=["POST"])
@require_webhook_key
def live_stop():
    """Ends a broadcast: {"recorderId": "..."}. Not finding one is not an
    error - a session that was never actually live (start() refused, e.g.
    no WebRTC in the NUI) stopping anyway is the normal path, not a bug."""
    data = request.get_json(silent=True) or {}
    recorder_id = str(data.get("recorderId", "")).strip()
    if not recorder_id:
        return jsonify({"error": "recorderId is required"}), 400
    row = g.session.query(LiveStream).filter_by(recorder_id=recorder_id).first()
    if row is not None:
        g.session.delete(row)
        g.session.commit()
        if g.community is None:
            realtime.publish("live.stopped", recorderId=recorder_id)
    return jsonify({"ok": True}), 200


@webhooks_bp.route("/mediamtx/auth", methods=["POST"])
def mediamtx_auth():
    """External authentication webhook for MediaMTX's authHTTPAddress -
    deliberately *not* behind @require_webhook_key: MediaMTX sends its own
    fixed JSON shape, not Xon Sight's usual headers. Payload confirmed live
    against MediaMTX v1.21.2 (2026-10-25): {"ip", "user", "password",
    "path", "protocol", "id", "action", "query", ...} - query is the raw
    querystring a publisher/viewer connected with. 20x = allow, anything
    else = deny.

      - action "publish": `path` must have an active LiveStream row and
        `query` must carry a token= matching its publish_token - this is
        what lets the FiveM/NUI WHIP publisher in and nobody else.
      - action "read"/"playback": `query`'s token= must verify against
        live_tokens.verify_viewer_token(path, token) - signed server-side
        when a logged-in, authorized viewer loaded /live (api.py's
        list_live_streams). MediaMTX never has to understand an Xon Sight
        session for this, only check a signature.

    Control-plane only - LiveStream carries no tenancy column, and
    MediaMTX never sends X-XonSight-Token/-Key, so this queries db.session
    directly rather than resolving g.session/g.community like the rest of
    this file.
    """
    data = request.get_json(silent=True) or {}
    action = data.get("action")
    path = data.get("path") or ""
    query = parse_qs(data.get("query") or "")
    token = (query.get("token") or [""])[0] or data.get("token") or ""

    if action == "publish":
        row = db.session.query(LiveStream).filter_by(path=path).first()
        if row is not None and token and hmac.compare_digest(token, row.publish_token):
            return "", 200
        return jsonify({"error": "unauthorized"}), 401

    if action in ("read", "playback"):
        if token and verify_viewer_token(path, token):
            return "", 200
        return jsonify({"error": "unauthorized"}), 401

    # api/metrics/pprof probes or anything unexpected - deny by default
    return jsonify({"error": "unauthorized"}), 401


@webhooks_bp.route("/alerts", methods=["POST"])
@require_webhook_key
def receive_alert():
    """Extension endpoint (not part of Xon Sight's documented contract) -
    lets a bridge script push an emergency trigger (weapon drawn, TASER
    fired, ...) for the Live page's alert banner:
    {"recorderId": "...", "recorderName": "...", "type": "weapon_drawn",
    "message": "..."}. Nothing in Xon Sight ships this today - wire it up
    yourself from whatever detects the trigger in-game.
    """
    data = request.get_json(silent=True) or {}
    recorder_id = str(data.get("recorderId", "")).strip()
    alert_type = str(data.get("type", "")).strip()
    if not recorder_id or not alert_type:
        return jsonify({"error": "recorderId and type are required"}), 400

    alert = Alert(
        recorder_id=recorder_id,
        recorder_name=(data.get("recorderName") or "")[:128],
        alert_type=alert_type[:32],
        message=(data.get("message") or "")[:255],
    )
    g.session.add(alert)
    g.session.commit()

    if g.community is None:
        realtime.publish("alert.created", alert=alert.to_dict())

    try:
        discord.notify_alert(alert, community_id=g.community.id if g.community else None)
    except Exception:
        current_app.logger.exception("Discord notify failed for alert #%s", alert.id)

    return jsonify({"ok": True, "id": alert.id}), 200


@webhooks_bp.route("/external-feeds/sync", methods=["POST"])
@require_webhook_key
def sync_external_feeds():
    """Extension endpoint (Axon Fusus analog) - accepts a full snapshot of
    non-bodycam assets to pin on the Live map (fixed cameras, sensors,
    drones, ...): {"feeds": [{"id": "...", "label": "...", "kind":
    "camera", "status": "online", "position": {"x": ..., "y": ...}}]}.
    Xon Sight has no such integrations today - this is an empty slot until
    you wire a real source. Anything missing from the snapshot is removed,
    same as recorders/sync.
    """
    data = request.get_json(silent=True) or {}
    feeds = data.get("feeds", [])

    now = datetime.utcnow()
    seen_ids = set()

    for entry in feeds:
        feed_id = str(entry.get("id", "")).strip()
        if not feed_id:
            continue
        seen_ids.add(feed_id)

        row = g.session.query(ExternalFeed).filter_by(feed_id=feed_id).first()
        if row is None:
            row = ExternalFeed(feed_id=feed_id)
            g.session.add(row)

        row.label = entry.get("label") or ""
        kind = str(entry.get("kind") or "camera").strip().lower()
        row.kind = kind if kind in ("camera", "sensor", "drone", "other") else "other"
        status = str(entry.get("status") or "online").strip().lower()
        row.status = status if status in ("online", "offline") else "online"

        position = entry.get("position")
        if isinstance(position, dict):
            try:
                row.last_x = float(position["x"])
                row.last_y = float(position["y"])
            except (KeyError, TypeError, ValueError):
                pass

        row.last_seen_at = now

    g.session.query(ExternalFeed).filter(ExternalFeed.feed_id.notin_(seen_ids)).delete(synchronize_session=False)

    g.session.commit()
    return jsonify({"ok": True, "count": len(seen_ids)}), 200


@webhooks_bp.route("/media/upload", methods=["POST"])
@require_webhook_key
def upload_media():
    """Experimental portal-hosting alternative to self-hosting opslabs-bodycam's media/ folder:
    an independent companion script running on the FXServer's own machine (NOT the FXServer
    process itself - see the crash warning in media_storage.py / opslabs-bodycam/README.md)
    pushes each saved recording here after the fact, under the exact filename storage.js already
    gave it locally, so the videoUrl the resource already sent with the evidence item (Storage.
    PublicUrl + '/' + filename) resolves once this call lands. Not the FiveM webhook contract -
    an extension endpoint, like /live/* and /alerts."""
    f = request.files.get("file")
    if f is None:
        return jsonify({"error": "file is required (multipart/form-data, field name 'file')"}), 400

    filename = (request.form.get("filename") or f.filename or "").strip()
    if not FILENAME_RE.match(filename):
        return jsonify({"error": "filename must be the exact name storage.js saved it as (22 chars + .webm)"}), 400

    data = f.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        return jsonify({"error": "file too large"}), 413
    if len(data) < 1024 or data[:4] != WEBM_MAGIC:
        return jsonify({"error": "not a valid webm file"}), 400

    slug = g.community.slug if g.community else None
    directory = media_dir_for_slug(slug)
    path = os.path.join(directory, filename)
    try:
        with open(path, "wb") as out:
            out.write(data)
    except OSError:
        current_app.logger.exception("Could not write uploaded media %s", filename)
        return jsonify({"error": "write_failed"}), 500

    return jsonify({"ok": True, "bytes": len(data)}), 200


@webhooks_bp.route("/features", methods=["GET"])
@require_webhook_key
def features():
    """Remote feature flags a FiveM resource can poll (opslabs-bodycam, for the in-game phone's Bodycam app).
    The legacy shared-key path (g.community is None - the original single-tenant server) was never gated on
    any of these and keeps getting everything on, same as before multi-tenancy existed. A community reached
    via its own token only gets what's been explicitly turned on for it in its admin settings - premium
    add-ons default off until granted, same as any other paid tier."""
    phone_app_enabled = True if g.community is None else bool(g.community.phone_app_enabled)
    return jsonify({"phoneAppEnabled": phone_app_enabled})
