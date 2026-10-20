from datetime import datetime

from flask import current_app
from flask_login import UserMixin
from werkzeug.security import check_password_hash, generate_password_hash

from .extensions import db


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), nullable=False, unique=True)
    password_hash = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(16), nullable=False, default="officer")  # admin | officer
    is_active_account = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime, nullable=True)

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    @property
    def is_admin(self):
        return self.role == "admin"

    # UserMixin's is_active - Flask-Login checks this to refuse login/
    # session validation for accounts pending approval.
    @property
    def is_active(self):
        return self.is_active_account

    def to_dict(self):
        return {
            "id": self.id,
            "username": self.username,
            "role": self.role,
            "isActive": self.is_active_account,
            "createdAt": self.created_at.isoformat() + "Z",
            "lastLoginAt": (self.last_login_at.isoformat() + "Z") if self.last_login_at else None,
        }


class Settings(db.Model):
    """Singleton row (id=1) of server-wide settings an admin can change at
    runtime from /admin/settings - e.g. signup_mode is deliberately NOT an
    env var, since different communities deploying Xon Sight want
    different signup policies without a redeploy."""

    __tablename__ = "settings"

    id = db.Column(db.Integer, primary_key=True)
    # "open" | "invite" | "approval"
    signup_mode = db.Column(db.String(16), nullable=False, default="invite")
    invite_code = db.Column(db.String(128), nullable=False, default="")

    # One Discord webhook URL for the whole deployment, for now - see xonsight/discord.py. Becomes per-community
    # once multi-tenancy ships; deliberately not an env var for the same reason signup_mode isn't.
    discord_webhook_url = db.Column(db.String(512), nullable=False, default="")
    discord_notify_evidence = db.Column(db.Boolean, nullable=False, default=True)
    discord_notify_alerts = db.Column(db.Boolean, nullable=False, default=True)
    discord_notify_bolos = db.Column(db.Boolean, nullable=False, default=True)

    @classmethod
    def get(cls):
        row = cls.query.get(1)
        if row is None:
            row = cls(id=1, signup_mode="invite", invite_code="")
            db.session.add(row)
            db.session.commit()
        return row

    def to_dict(self):
        return {
            "signupMode": self.signup_mode,
            "inviteCode": self.invite_code,
            "discordWebhookUrl": self.discord_webhook_url,
            "discordNotifyEvidence": self.discord_notify_evidence,
            "discordNotifyAlerts": self.discord_notify_alerts,
            "discordNotifyBolos": self.discord_notify_bolos,
        }


class Evidence(db.Model):
    __tablename__ = "evidence"

    id = db.Column(db.Integer, primary_key=True)
    remote_id = db.Column(db.Integer, nullable=False, unique=True)
    submitter_identifier = db.Column(db.String(128), nullable=False, default="")
    submitter_name = db.Column(db.String(128), nullable=False, default="")
    caption = db.Column(db.String(255), nullable=False, default="")
    video_url = db.Column(db.String(1024), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    received_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Added for the evidence viewer - not part of Xon Sight's webhook
    # contract, filled in manually from the Metadata/Transcript tabs since
    # there's no device-serial field in the webhook payload and no speech-
    # to-text service wired up.
    device_serial = db.Column(db.String(128), nullable=False, default="")
    transcript = db.Column(db.Text, nullable=False, default="")

    # Portal account this evidence is attributed to - Xon Sight's webhook
    # carries no portal login, just an in-game identifier, so every item
    # defaults to the admin account at ingest time. Existing items were
    # backfilled to the first admin account when accounts were introduced.
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    def to_dict(self):
        owner = User.query.get(self.owner_id) if self.owner_id else None
        return {
            "id": self.id,
            "remoteId": self.remote_id,
            "submitterIdentifier": self.submitter_identifier,
            "submitterName": self.submitter_name,
            "caption": self.caption,
            "videoUrl": self.video_url,
            "deviceSerial": self.device_serial,
            "transcript": self.transcript,
            "createdAt": self.created_at.isoformat() + "Z",
            "receivedAt": self.received_at.isoformat() + "Z",
            "ownerUsername": owner.username if owner else None,
        }


class ActiveRecorder(db.Model):
    """Not part of Xon Sight's documented webhook contract.

    Xon Sight only ships the evidence webhook. This table/endpoint is a small
    extension so a bridge script on the FiveM side (polling
    exports.XonSight:GetActiveRecorders() on an interval) can push the
    current live-recording roster here for the site's Live page - since
    Xon Sight itself never emits video frames or a video stream to
    third parties.
    """

    __tablename__ = "active_recorders"

    id = db.Column(db.Integer, primary_key=True)
    recorder_id = db.Column(db.String(64), nullable=False, unique=True)
    name = db.Column(db.String(128), nullable=False, default="")
    job = db.Column(db.String(64), nullable=False, default="")
    started_at = db.Column(db.DateTime, nullable=True)
    last_seen_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Most recent camera sample relayed by xonsight-livesync, not a live video
    # feed - see live-view.md. Null until the first sample arrives.
    last_frame_x = db.Column(db.Float, nullable=True)
    last_frame_y = db.Column(db.Float, nullable=True)
    last_frame_z = db.Column(db.Float, nullable=True)
    last_frame_heading = db.Column(db.Float, nullable=True)
    last_frame_pitch = db.Column(db.Float, nullable=True)
    last_frame_fov = db.Column(db.Float, nullable=True)

    # "recording" | "buffering" - camera on but not yet recording. Not part
    # of the documented contract either; defaults to "recording" so older
    # bridge scripts that don't send it keep working unchanged.
    status = db.Column(db.String(16), nullable=False, default="recording")

    def to_dict(self):
        last_frame = None
        if self.last_frame_x is not None and self.last_frame_y is not None and self.last_frame_z is not None:
            last_frame = {
                "x": self.last_frame_x,
                "y": self.last_frame_y,
                "z": self.last_frame_z,
                "heading": self.last_frame_heading,
                "pitch": self.last_frame_pitch,
                "fov": self.last_frame_fov,
            }

        stale_after = current_app.config.get("RECORDER_STALE_SECONDS", 30)
        age_seconds = (datetime.utcnow() - self.last_seen_at).total_seconds()

        return {
            "id": self.recorder_id,
            "name": self.name,
            "job": self.job,
            "status": self.status or "recording",
            "startedAt": (self.started_at.isoformat() + "Z") if self.started_at else None,
            "lastSeenAt": self.last_seen_at.isoformat() + "Z",
            "lastFrame": last_frame,
            "isStale": age_seconds > stale_after,
        }


class CaseNote(db.Model):
    """Manually-entered case notes on an evidence item - Xon Sight's webhook
    carries no notes field, this is purely a portal-side annotation."""

    __tablename__ = "case_notes"

    id = db.Column(db.Integer, primary_key=True)
    evidence_id = db.Column(db.Integer, db.ForeignKey("evidence.id"), nullable=False)
    author = db.Column(db.String(128), nullable=False, default="")
    body = db.Column(db.Text, nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "evidenceId": self.evidence_id,
            "author": self.author,
            "body": self.body,
            "createdAt": self.created_at.isoformat() + "Z",
        }


class Marker(db.Model):
    """A bookmarked moment in an evidence video's timeline."""

    __tablename__ = "evidence_markers"

    id = db.Column(db.Integer, primary_key=True)
    evidence_id = db.Column(db.Integer, db.ForeignKey("evidence.id"), nullable=False)
    label = db.Column(db.String(255), nullable=False, default="")
    timestamp_seconds = db.Column(db.Float, nullable=False, default=0.0)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "evidenceId": self.evidence_id,
            "label": self.label,
            "timestampSeconds": self.timestamp_seconds,
            "createdAt": self.created_at.isoformat() + "Z",
        }


class Clip(db.Model):
    """A marked in/out range within an evidence video - a playable bookmark,
    not a separately exported file: Xon Sight never hands this portal the
    raw video bytes, only a hosted URL, so there's nothing here to cut."""

    __tablename__ = "evidence_clips"

    id = db.Column(db.Integer, primary_key=True)
    evidence_id = db.Column(db.Integer, db.ForeignKey("evidence.id"), nullable=False)
    label = db.Column(db.String(255), nullable=False, default="")
    start_seconds = db.Column(db.Float, nullable=False, default=0.0)
    end_seconds = db.Column(db.Float, nullable=False, default=0.0)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "evidenceId": self.evidence_id,
            "label": self.label,
            "startSeconds": self.start_seconds,
            "endSeconds": self.end_seconds,
            "createdAt": self.created_at.isoformat() + "Z",
        }


class Alert(db.Model):
    """Emergency trigger banners for the Live page (weapon drawn, TASER
    fired, etc). Extension endpoint, like recorders/sync - nothing in Xon
    Sight ships this today; wire it up from whatever detects the trigger."""

    __tablename__ = "alerts"

    id = db.Column(db.Integer, primary_key=True)
    recorder_id = db.Column(db.String(64), nullable=False, default="")
    recorder_name = db.Column(db.String(128), nullable=False, default="")
    alert_type = db.Column(db.String(32), nullable=False, default="")
    message = db.Column(db.String(255), nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    acknowledged = db.Column(db.Boolean, nullable=False, default=False)
    acknowledged_at = db.Column(db.DateTime, nullable=True)

    def to_dict(self):
        return {
            "id": self.id,
            "recorderId": self.recorder_id,
            "recorderName": self.recorder_name,
            "alertType": self.alert_type,
            "message": self.message,
            "createdAt": self.created_at.isoformat() + "Z",
            "acknowledged": self.acknowledged,
            "acknowledgedAt": (self.acknowledged_at.isoformat() + "Z") if self.acknowledged_at else None,
        }


class ExternalFeed(db.Model):
    """A non-bodycam asset pin for the Live map (fixed camera, sensor,
    drone, ...) - an Axon Fusus-style "single pane of glass" layer. Xon
    Sight has no such integrations today; this is an empty extensible slot
    until you wire a real source to POST /api/xonsight/external-feeds/sync.
    """

    __tablename__ = "external_feeds"

    id = db.Column(db.Integer, primary_key=True)
    feed_id = db.Column(db.String(64), nullable=False, unique=True)
    label = db.Column(db.String(128), nullable=False, default="")
    kind = db.Column(db.String(32), nullable=False, default="camera")  # camera | sensor | drone | other
    status = db.Column(db.String(16), nullable=False, default="online")  # online | offline
    last_x = db.Column(db.Float, nullable=True)
    last_y = db.Column(db.Float, nullable=True)
    last_seen_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.feed_id,
            "label": self.label,
            "kind": self.kind,
            "status": self.status,
            "position": {"x": self.last_x, "y": self.last_y} if self.last_x is not None else None,
            "lastSeenAt": self.last_seen_at.isoformat() + "Z",
        }


class Case(db.Model):
    """Lightweight case wrapper - groups evidence + notes under a status and
    an audit trail. Not a full records-management suite: no use-of-force
    review workflow, no compliance auditing beyond the status log below."""

    __tablename__ = "cases"

    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(255), nullable=False, default="")
    status = db.Column(db.String(32), nullable=False, default="open")  # open | under_review | closed
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "title": self.title,
            "status": self.status,
            "createdAt": self.created_at.isoformat() + "Z",
            "updatedAt": self.updated_at.isoformat() + "Z",
        }


class CaseEvidence(db.Model):
    """Association between a Case and an Evidence item."""

    __tablename__ = "case_evidence"

    id = db.Column(db.Integer, primary_key=True)
    case_id = db.Column(db.Integer, db.ForeignKey("cases.id"), nullable=False)
    evidence_id = db.Column(db.Integer, db.ForeignKey("evidence.id"), nullable=False)
    added_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class CaseAuditEntry(db.Model):
    """Status-change audit trail for a Case."""

    __tablename__ = "case_audit_entries"

    id = db.Column(db.Integer, primary_key=True)
    case_id = db.Column(db.Integer, db.ForeignKey("cases.id"), nullable=False)
    from_status = db.Column(db.String(32), nullable=False, default="")
    to_status = db.Column(db.String(32), nullable=False, default="")
    note = db.Column(db.String(255), nullable=False, default="")
    author = db.Column(db.String(128), nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "caseId": self.case_id,
            "fromStatus": self.from_status,
            "toStatus": self.to_status,
            "note": self.note,
            "author": self.author,
            "createdAt": self.created_at.isoformat() + "Z",
        }


class Draft(db.Model):
    """A Draft One-style AI-generated report narrative for one evidence
    item. Generated from its manual transcript/notes via the Claude API -
    see ai.py. Always reviewed/edited by a human before use; this portal
    never submits it anywhere on its own."""

    __tablename__ = "drafts"

    id = db.Column(db.Integer, primary_key=True)
    evidence_id = db.Column(db.Integer, db.ForeignKey("evidence.id"), nullable=False)
    content = db.Column(db.Text, nullable=False, default="")
    model_used = db.Column(db.String(64), nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "evidenceId": self.evidence_id,
            "content": self.content,
            "modelUsed": self.model_used,
            "createdAt": self.created_at.isoformat() + "Z",
        }


class Brief(db.Model):
    """A Brief One-style AI-generated summary + evidentiary-milestone list
    for one evidence item, built from its transcript/notes/markers."""

    __tablename__ = "briefs"

    id = db.Column(db.Integer, primary_key=True)
    evidence_id = db.Column(db.Integer, db.ForeignKey("evidence.id"), nullable=False)
    summary = db.Column(db.Text, nullable=False, default="")
    milestones_json = db.Column(db.Text, nullable=False, default="[]")
    model_used = db.Column(db.String(64), nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        import json

        try:
            milestones = json.loads(self.milestones_json or "[]")
        except ValueError:
            milestones = []
        return {
            "id": self.id,
            "evidenceId": self.evidence_id,
            "summary": self.summary,
            "milestones": milestones,
            "modelUsed": self.model_used,
            "createdAt": self.created_at.isoformat() + "Z",
        }


class Bolo(db.Model):
    """A "Be On The Lookout" alert - the Axon Assistant analog can draft the
    body text with Claude, but publishing is always an explicit human click
    (see views/api for the assistant endpoints)."""

    __tablename__ = "bolos"

    id = db.Column(db.Integer, primary_key=True)
    subject = db.Column(db.String(255), nullable=False, default="")
    details = db.Column(db.Text, nullable=False, default="")
    author = db.Column(db.String(128), nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    active = db.Column(db.Boolean, nullable=False, default=True)

    def to_dict(self):
        return {
            "id": self.id,
            "subject": self.subject,
            "details": self.details,
            "author": self.author,
            "createdAt": self.created_at.isoformat() + "Z",
            "active": self.active,
        }


class CommunityRequest(db.Model):
    """Axon 'Community Request' analog - an investigator asks the public
    (or an in-game civilian with dashcam/doorbell footage) for evidence or
    tips via a shareable link. Xon Sight has no real email/SMS delivery
    system like Axon App's invite flow, so there's no "send invite" step -
    you share the /r/<code> link yourself (Discord, the in-game phone,
    wherever reaches that person)."""

    __tablename__ = "community_requests"

    id = db.Column(db.Integer, primary_key=True)
    reference_code = db.Column(db.String(16), nullable=False, unique=True)
    title = db.Column(db.String(255), nullable=False, default="")
    description = db.Column(db.Text, nullable=False, default="")
    category = db.Column(db.String(64), nullable=False, default="General")
    instructions = db.Column(db.String(500), nullable=False, default="")
    case_id = db.Column(db.Integer, db.ForeignKey("cases.id"), nullable=True)
    requires_consent = db.Column(db.Boolean, nullable=False, default=True)
    status = db.Column(db.String(16), nullable=False, default="open")  # open | closed
    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # The one always-on, no-account tip line linked from the homepage
    # (/report) - seeded once at setup (see seed.py). Distinct from the
    # per-case links officers generate, which stay at /r/<code>.
    is_general = db.Column(db.Boolean, nullable=False, default=False)

    @staticmethod
    def generate_reference_code():
        import secrets
        import string

        alphabet = string.ascii_uppercase + string.digits
        for _ in range(5):
            code = "".join(secrets.choice(alphabet) for _ in range(8))
            if CommunityRequest.query.filter_by(reference_code=code).first() is None:
                return code
        return "".join(secrets.choice(alphabet) for _ in range(12))

    def to_dict(self):
        creator = User.query.get(self.created_by_id) if self.created_by_id else None
        submission_count = CommunitySubmission.query.filter_by(request_id=self.id).count()
        return {
            "id": self.id,
            "referenceCode": self.reference_code,
            "title": self.title,
            "description": self.description,
            "category": self.category,
            "instructions": self.instructions,
            "caseId": self.case_id,
            "requiresConsent": self.requires_consent,
            "status": self.status,
            "isGeneral": self.is_general,
            "createdBy": creator.username if creator else None,
            "createdAt": self.created_at.isoformat() + "Z",
            "submissionCount": submission_count,
        }


class CommunitySubmission(db.Model):
    """One piece of evidence/a tip submitted by the public against a
    CommunityRequest - no portal account needed, matching Axon's
    unauthenticated community-member submission flow."""

    __tablename__ = "community_submissions"

    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer, db.ForeignKey("community_requests.id"), nullable=False)
    submitter_name = db.Column(db.String(128), nullable=False, default="")
    submitter_contact = db.Column(db.String(128), nullable=False, default="")
    store_contact_consent = db.Column(db.Boolean, nullable=False, default=False)
    consent_given = db.Column(db.Boolean, nullable=False, default=False)
    message = db.Column(db.Text, nullable=False, default="")
    external_link = db.Column(db.String(1024), nullable=False, default="")
    file_path = db.Column(db.String(512), nullable=False, default="")
    file_original_name = db.Column(db.String(255), nullable=False, default="")
    reviewed = db.Column(db.Boolean, nullable=False, default=False)
    submitted_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "requestId": self.request_id,
            "submitterName": self.submitter_name,
            "submitterContact": self.submitter_contact if self.store_contact_consent else None,
            "storeContactConsent": self.store_contact_consent,
            "consentGiven": self.consent_given,
            "message": self.message,
            "externalLink": self.external_link,
            "hasFile": bool(self.file_path),
            "fileOriginalName": self.file_original_name,
            "reviewed": self.reviewed,
            "submittedAt": self.submitted_at.isoformat() + "Z",
        }


class Community(db.Model):
    """Multi-tenancy control-plane registry (one row per community/server),
    deliberately kept in this app's own control-plane database (SQLite,
    same as everything above) rather than inside any tenant's own MySQL
    database - see xonsight/tenancy.py.

    Each community gets its own dedicated MySQL database (provisioned by
    tenancy.py, never the control-plane DB itself) and its own API token
    for webhook auth (X-XonSight-Token), replacing the single shared
    XONSIGHT_WEBHOOK_KEY. Subdomain/custom-domain browser routing isn't
    wired up yet - slug/custom_domain are stored ready for that, but
    resolution today is token-only (webhooks). The existing production
    site/data is not yet migrated into a Community row - see README."""

    __tablename__ = "communities"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(128), nullable=False)
    slug = db.Column(db.String(64), nullable=False, unique=True)
    custom_domain = db.Column(db.String(255), nullable=True, unique=True)
    status = db.Column(db.String(16), nullable=False, default="active")  # active | suspended

    db_host = db.Column(db.String(255), nullable=False, default="127.0.0.1")
    db_port = db.Column(db.Integer, nullable=False, default=3306)
    db_name = db.Column(db.String(64), nullable=False, unique=True)
    db_user = db.Column(db.String(64), nullable=False)
    db_password = db.Column(db.String(128), nullable=False)

    api_token = db.Column(db.String(64), nullable=False, unique=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Premium add-on, off by default: the in-game phone's Bodycam app ("My footage" / "Live" tabs). Checked by
    # opslabs-bodycam over the webhook token (GET /api/xonsight/features), never by the browser app.
    phone_app_enabled = db.Column(db.Boolean, nullable=False, default=False)

    def to_dict(self, reveal_secrets=False):
        data = {
            "id": self.id,
            "name": self.name,
            "slug": self.slug,
            "customDomain": self.custom_domain,
            "status": self.status,
            "dbName": self.db_name,
            "createdAt": self.created_at.isoformat() + "Z",
            "phoneAppEnabled": self.phone_app_enabled,
        }
        if reveal_secrets:
            data["apiToken"] = self.api_token
        return data


class AuditLog(db.Model):
    """Append-only record of admin actions - who changed what, and when.
    Control-plane only; no delete/edit endpoint exists for this on
    purpose, so it stays a trustworthy record of what actually happened."""

    __tablename__ = "audit_log"

    id = db.Column(db.Integer, primary_key=True)
    actor_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    actor_username = db.Column(db.String(64), nullable=False, default="")
    action = db.Column(db.String(64), nullable=False)
    detail = db.Column(db.String(500), nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "actorUsername": self.actor_username,
            "action": self.action,
            "detail": self.detail,
            "createdAt": self.created_at.isoformat() + "Z",
        }
