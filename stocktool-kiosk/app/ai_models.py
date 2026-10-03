"""
Local Admin AI — data models (Part 1).

Registered on the same shared SQLAlchemy `db` instance as everything in
app/models.py, so these tables live in the same kiosk_local.db and get
created/auto-migrated by app/__init__.py's normal startup path -- no
separate database, no separate migration story.
"""
from datetime import datetime, timezone
import json

from app.models import db


def _now():
    return datetime.now(timezone.utc)


class AISettings(db.Model):
    """Singleton row (id is always 1). Everything here maps directly to
    spec section 16 ("Admin AI Settings"). Defaults are the safe/
    read-only configuration required by section 16's last line."""
    __tablename__ = "ai_settings"

    id = db.Column(db.Integer, primary_key=True, default=1)

    enabled = db.Column(db.Boolean, nullable=False, default=False)

    # Local inference engine (see ai_engine.py). model_path is a GGUF
    # file under the kiosk data dir -- never a URL, never an API key --
    # so "enabled" with no model_path configured just means "AI page
    # shows a setup prompt", never a network call.
    model_path = db.Column(db.String(500), nullable=True)
    model_label = db.Column(db.String(200), nullable=True)  # display name only, e.g. "Qwen2.5-0.5B-Instruct (Q4)"
    context_tokens = db.Column(db.Integer, nullable=False, default=4096)
    temperature = db.Column(db.Float, nullable=False, default=0.2)
    max_response_tokens = db.Column(db.Integer, nullable=False, default=512)

    # Section 7/15: read-only until explicitly turned off, and even
    # then only specific action tools (Part 2+) are ever exposed.
    read_only = db.Column(db.Boolean, nullable=False, default=True)
    db_access_level = db.Column(db.String(32), nullable=False, default="summary")  # "summary" | "detail" | "none"

    # Section 10: internet access is a separate, explicit, off-by-
    # default switch. Nothing in Part 1 uses it even if turned on --
    # it exists so the setting is honest about being enforced later.
    internet_access = db.Column(db.Boolean, nullable=False, default=False)

    history_enabled = db.Column(db.Boolean, nullable=False, default=True)

    updated_at = db.Column(db.DateTime, default=_now, onupdate=_now, nullable=False)

    DEFAULTS_LOCKED_MSG = "AI is disabled or has no model configured."

    @staticmethod
    def get() -> "AISettings":
        row = db.session.get(AISettings, 1)
        if not row:
            row = AISettings(id=1)
            db.session.add(row)
            db.session.commit()
        return row

    def to_dict(self) -> dict:
        return {
            "enabled": self.enabled,
            "model_path": self.model_path,
            "model_label": self.model_label,
            "context_tokens": self.context_tokens,
            "temperature": self.temperature,
            "max_response_tokens": self.max_response_tokens,
            "read_only": self.read_only,
            "db_access_level": self.db_access_level,
            "internet_access": self.internet_access,
            "history_enabled": self.history_enabled,
        }


class AIConversation(db.Model):
    """One thread per (user, opened session). Kept small on purpose --
    this is a kiosk-side assistant, not a chat product."""
    __tablename__ = "ai_conversations"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("local_users.id"), nullable=True, index=True)
    role_at_time = db.Column(db.String(32), nullable=True)  # LocalUser.role, snapshotted -- see ai_tools.py note
    title = db.Column(db.String(200), nullable=True)  # first user message, truncated, for a history list
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    messages = db.relationship(
        "AIMessage", backref="conversation", cascade="all, delete-orphan",
        order_by="AIMessage.id",
    )

    def to_dict(self, include_messages=False) -> dict:
        out = {
            "id": self.id,
            "title": self.title,
            "created_at": self.created_at.isoformat(),
        }
        if include_messages:
            out["messages"] = [m.to_dict() for m in self.messages]
        return out


class AIMessage(db.Model):
    __tablename__ = "ai_messages"

    id = db.Column(db.Integer, primary_key=True)
    conversation_id = db.Column(db.Integer, db.ForeignKey("ai_conversations.id"), nullable=False, index=True)
    sender = db.Column(db.String(16), nullable=False)  # "user" | "assistant" | "system"
    content = db.Column(db.Text, nullable=False)
    tool_calls_json = db.Column(db.Text, nullable=True)  # raw JSON string of any tool calls used to answer
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "sender": self.sender,
            "content": self.content,
            "created_at": self.created_at.isoformat(),
        }


class AIProposal(db.Model):
    """Spec section 8 ("Optional AI Actions") — the AI never mutates
    the DB directly. It (or an admin, via the chat) creates one of
    these describing exactly what write it wants to make; nothing
    happens until an admin calls the approve endpoint, which runs the
    matching function in ai_tools.WRITE_TOOLS and records the result.
    A rejected or still-pending proposal has caused zero DB changes."""
    __tablename__ = "ai_proposals"

    STATUS_PENDING = "pending"
    STATUS_APPROVED = "approved"
    STATUS_REJECTED = "rejected"
    STATUS_FAILED = "failed"  # approved, but the write tool raised at execution time

    id = db.Column(db.Integer, primary_key=True)
    conversation_id = db.Column(db.Integer, db.ForeignKey("ai_conversations.id"), nullable=True, index=True)
    requested_by_user_id = db.Column(db.Integer, db.ForeignKey("local_users.id"), nullable=True)
    action = db.Column(db.String(64), nullable=False)  # key into ai_tools.WRITE_TOOLS
    params_json = db.Column(db.Text, nullable=False)  # json.dumps(kwargs) for the write tool
    summary = db.Column(db.String(500), nullable=False)  # human-readable, shown before Approve/Cancel

    status = db.Column(db.String(16), nullable=False, default=STATUS_PENDING)
    result_json = db.Column(db.Text, nullable=True)  # set once executed
    decided_by_user_id = db.Column(db.Integer, db.ForeignKey("local_users.id"), nullable=True)
    decided_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "action": self.action,
            "params": json.loads(self.params_json),
            "summary": self.summary,
            "status": self.status,
            "result": json.loads(self.result_json) if self.result_json else None,
            "created_at": self.created_at.isoformat(),
            "decided_at": self.decided_at.isoformat() if self.decided_at else None,
        }
