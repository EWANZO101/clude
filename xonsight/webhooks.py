import hmac
from datetime import datetime
from functools import wraps

from flask import Blueprint, current_app, g, jsonify, request

from . import discord, realtime, tenancy
from .extensions import db
from .models import ActiveRecorder, Alert, Community, Evidence, ExternalFeed, User

webhooks_bp = Blueprint("webhooks", __name__, url_prefix="/api/xonsight")


def require_webhook_key(fn):
    """Two auth paths, checked in this order:

    1. X-XonSight-Token: a per-community API token (xonsight/tenancy.py).
       Valid -> g.community and g.session are set to that community's own
       MySQL-backed tenant session; every write in this request lands
       there, not in the control-plane database. A token that doesn't
       match any active community is a hard 401 - it never silently
       falls back to path 2.
    2. X-XonSight-Key: the original shared secret (XONSIGHT_WEBHOOK_KEY),
       unchanged from before multi-tenancy existed. Writes land in the
       control-plane database via db.session, exactly as they always
       have - this is what the currently-deployed opslabs-bodycam still
       uses.

    Every handler below must query/write through g.session, never the
    bare Model.query / db.session - that property is always bound to the
    control-plane database regardless of which path authenticated the
    request, so using it directly here would silently ignore a resolved
    tenant and read/write the wrong community's data.
    """

    @wraps(fn)
    def wrapper(*args, **kwargs):
        token = request.headers.get("X-XonSight-Token", "")
        if token:
            community = Community.query.filter_by(api_token=token, status="active").first()
            if community is None:
                return jsonify({"error": "unauthorized"}), 401
            g.community = community
            g.session = tenancy.get_tenant_session(community)
            return fn(*args, **kwargs)

        expected = current_app.config.get("XONSIGHT_WEBHOOK_KEY", "")
        if expected:
            provided = request.headers.get("X-XonSight-Key", "")
            if not hmac.compare_digest(provided, expected):
                return jsonify({"error": "unauthorized"}), 401

        g.community = None
        g.session = db.session
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
        discord.notify_evidence(record)
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
        discord.notify_alert(alert)
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
