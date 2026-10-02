"""
Local Admin AI — API (Part 1).

Mounted on its own Flask app/port (see app/ai_app.py) rather than
folded into the main kiosk API app -- keeps a slow/CPU-heavy model
call from ever competing with the main app's request threads, and
matches "different port, same MSI/service" from spec discussion.
Shares the same DB and the same in-memory session store (app/auth.py)
as the main app, since it's the same process -- a token issued by the
main API's /api/auth/login works here too, no second login.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone

from flask import Blueprint, request, jsonify, g, current_app

from app.auth import login_required, permission_required, create_session
from app.models import db, LocalUser, RolePermission
from app.ai_models import AISettings, AIConversation, AIMessage, AIProposal
from app import ai_engine, ai_knowledge, ai_tools, ai_explain

ai_bp = Blueprint("ai", __name__, url_prefix="/api/ai")


@ai_bp.post("/login")
def login():
    """Part 10: lets the Admin AI page (app/templates/admin_ai.html) log
    in directly instead of requiring a token copied out of the main
    kiosk API's login response. Identical logic to app/routes_auth.py's
    /api/auth/login -- deliberately duplicated rather than imported,
    since routes_auth.py belongs to the main app's blueprint set and
    this app runs standalone (see this file's module docstring); both
    call the same create_session(), so a token from either endpoint
    works against both ports either way."""
    data = request.get_json(silent=True) or {}
    raw = (data.get("badge_code") or "").strip()
    if not raw:
        return jsonify({"error": "Scan or enter a badge code, or type a username."}), 400

    user = LocalUser.query.filter_by(badge_code=raw.upper()).first()
    if not user:
        user = LocalUser.query.filter_by(username=raw).first()

    if not user or not user.is_active:
        return jsonify({"error": "Not recognised."}), 401
    if not RolePermission.is_login_enabled(user.role):
        return jsonify({"error": "Logins are currently disabled for your role. Ask an admin."}), 403

    token = create_session(user)
    return jsonify({"token": token, "user": user.to_dict()}), 200


@ai_bp.get("/status")
@login_required
def get_status():
    settings = AISettings.get()
    return jsonify(ai_engine.status(settings))


@ai_bp.get("/settings")
@permission_required("admin")
def get_settings():
    return jsonify(AISettings.get().to_dict())


@ai_bp.put("/settings")
@permission_required("admin")
def update_settings():
    """Section 16: admin-configurable. Deliberately whitelist-based --
    unknown keys in the request body are silently ignored rather than
    ever letting a client set an arbitrary column."""
    settings = AISettings.get()
    body = request.get_json(silent=True) or {}
    old_model_path = settings.model_path

    for key in (
        "enabled", "model_path", "model_label", "context_tokens",
        "temperature", "max_response_tokens", "read_only",
        "db_access_level", "internet_access", "history_enabled",
    ):
        if key in body:
            setattr(settings, key, body[key])

    db.session.commit()

    if settings.model_path != old_model_path or not settings.enabled:
        ai_engine.unload()  # force a reload against the new file, or free memory if disabled

    return jsonify(settings.to_dict())


@ai_bp.get("/history")
@login_required
def list_history():
    settings = AISettings.get()
    if not settings.history_enabled:
        return jsonify({"conversations": []})
    q = AIConversation.query
    if g.session["role"] != "admin":
        q = q.filter_by(user_id=g.session["user_id"])  # non-admins only ever see their own
    convos = q.order_by(AIConversation.created_at.desc()).limit(50).all()
    return jsonify({"conversations": [c.to_dict() for c in convos]})


@ai_bp.get("/history/<int:conversation_id>")
@login_required
def get_conversation(conversation_id):
    convo = db.session.get(AIConversation, conversation_id)
    if not convo:
        return jsonify({"error": "Not found."}), 404
    if g.session["role"] != "admin" and convo.user_id != g.session["user_id"]:
        return jsonify({"error": "Not found."}), 404
    return jsonify(convo.to_dict(include_messages=True))


@ai_bp.delete("/history")
@login_required
def clear_history():
    """Section 16's "Clear conversation history". Clears only the
    caller's own conversations unless they're admin, matching the same
    visibility rule as list_history above."""
    q = AIConversation.query
    if g.session["role"] != "admin":
        q = q.filter_by(user_id=g.session["user_id"])
    convos = q.all()
    ids = [c.id for c in convos]
    if ids:
        # Bulk .delete() on the query wouldn't cascade to AIMessage (that
        # relies on ORM object deletion, not a bulk UPDATE/DELETE), so
        # messages are cleared explicitly first.
        AIMessage.query.filter(AIMessage.conversation_id.in_(ids)).delete(synchronize_session=False)
        AIConversation.query.filter(AIConversation.id.in_(ids)).delete(synchronize_session=False)
    db.session.commit()
    return jsonify({"deleted": len(ids)})


@ai_bp.post("/chat")
@login_required
def chat():
    settings = AISettings.get()
    if not settings.enabled:
        return jsonify({"error": "Admin AI is disabled."}), 403

    body = request.get_json(silent=True) or {}
    message = (body.get("message") or "").strip()
    conversation_id = body.get("conversation_id")
    context_page = body.get("context_page")  # spec section 13, "AI Help Everywhere"
    if not message:
        return jsonify({"error": "message is required."}), 400

    role = g.session["role"]
    user_id = g.session["user_id"]

    if conversation_id:
        convo = db.session.get(AIConversation, conversation_id)
        if not convo or (role != "admin" and convo.user_id != user_id):
            return jsonify({"error": "Not found."}), 404
    else:
        convo = AIConversation(user_id=user_id, role_at_time=role, title=message[:80])
        db.session.add(convo)
        db.session.flush()

    user_msg = AIMessage(conversation_id=convo.id, sender="user", content=message)
    db.session.add(user_msg)
    db.session.flush()

    # ── Retrieval (section 11) ──────────────────────────────────────
    context_snippets = ai_knowledge.retrieve(message, context_page=context_page)
    live = ai_knowledge.live_snapshot(role, settings.db_access_level)
    if live:
        context_snippets.append(live)

    history = [{"sender": m.sender, "content": m.content} for m in convo.messages]

    try:
        answer = ai_engine.generate(
            settings, history, context_snippets,
            llama_server_port=current_app.config.get("LLAMA_SERVER_PORT", 8422),
        )
    except ai_engine.AIEngineError as exc:
        db.session.rollback()
        return jsonify({"error": str(exc)}), 503

    assistant_msg = AIMessage(conversation_id=convo.id, sender="assistant", content=answer)
    db.session.add(assistant_msg)

    if not settings.history_enabled:
        # Still needed the row to generate a coherent reply above, but
        # the admin has opted out of retaining it -- discard instead of
        # committing.
        db.session.rollback()
        return jsonify({"conversation_id": None, "answer": answer})

    db.session.commit()
    return jsonify({"conversation_id": convo.id, "answer": answer})


@ai_bp.post("/tool/<tool_name>")
@login_required
def call_tool(tool_name):
    """Direct, non-chat access to a single controlled tool (section 15)
    -- useful for the Admin Panel to show live facts (e.g. a status
    widget) without round-tripping through the language model at all.
    Same permission enforcement as when the chat model calls these
    internally, since it's the exact same functions."""
    fn = ai_tools.TOOLS.get(tool_name)
    if not fn:
        return jsonify({"error": "Unknown tool."}), 404
    kwargs = request.get_json(silent=True) or {}
    settings = AISettings.get()
    try:
        ai_tools.check_db_access_level(tool_name, settings.db_access_level)
        result = fn(g.session["role"], **kwargs)
    except ai_tools.ToolPermissionError as exc:
        return jsonify({"error": str(exc)}), 403
    except TypeError as exc:
        return jsonify({"error": f"Bad arguments: {exc}"}), 400
    return jsonify({"result": result})


@ai_bp.get("/models")
@permission_required("admin")
def list_models():
    """Lists .gguf files under DATA_DIR/ai_models/ so the AI Settings
    page can offer a picker instead of requiring an admin to type a
    full file path. Creates the folder if it doesn't exist yet -- an
    admin drops a downloaded GGUF file there and it shows up here with
    no other setup. Returns nothing about files outside that one
    folder (no arbitrary filesystem browsing)."""
    models_dir = os.path.join(current_app.config["DATA_DIR"], "ai_models")
    os.makedirs(models_dir, exist_ok=True)
    files = []
    for name in sorted(os.listdir(models_dir)):
        if name.lower().endswith(".gguf"):
            full_path = os.path.join(models_dir, name)
            files.append({
                "filename": name,
                "path": full_path,
                "size_mb": round(os.path.getsize(full_path) / (1024 * 1024), 1),
            })
    return jsonify({"models_dir": models_dir, "models": files})
@permission_required("admin")
def reindex():
    """Section 16's "Rebuild knowledge index" -- a manual escape hatch
    on top of the automatic invalidation in ai_knowledge.py, for cases
    that bypass the ORM events (a raw SQL bulk load, a restored backup)."""
    ai_knowledge.invalidate_dynamic_index()
    docs = ai_knowledge.dynamic_docs()  # rebuild immediately so the response reflects the new state
    return jsonify({"rebuilt": True, "dynamic_doc_count": len(docs)})
@login_required
def explain():
    """Section 14. Body: {"source": "import_items"|"import_tools"|
    "sync_logs", "data": <the same JSON that endpoint already returned>}
    -- the caller (Admin Panel) passes through a result it already has;
    this never re-fetches or trusts a client-supplied narrative, only
    client-supplied raw data it re-summarizes itself."""
    body = request.get_json(silent=True) or {}
    source = body.get("source")
    data = body.get("data")
    if not source or data is None:
        return jsonify({"error": "source and data are required."}), 400
    try:
        return jsonify({"explanation": ai_explain.explain(source, data)})
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400


# ── Optional AI Actions (section 8) ────────────────────────────────

@ai_bp.post("/propose")
@permission_required("admin")
def propose():
    """Creates a pending AIProposal. Nothing is written to the DB by
    this call -- see approve() below. 400s immediately for an unknown
    action or a read_only AISettings, rather than creating a proposal
    that could never be approved anyway."""
    settings = AISettings.get()
    if settings.read_only:
        return jsonify({"error": "AI is in read-only mode -- enable actions in AI Settings first."}), 403

    body = request.get_json(silent=True) or {}
    action = body.get("action")
    params = body.get("params") or {}
    summary = body.get("summary")
    if action not in ai_tools.WRITE_TOOLS:
        return jsonify({"error": f"Unknown action '{action}'."}), 400
    if not summary:
        return jsonify({"error": "summary is required (shown to the admin before Approve/Cancel)."}), 400

    proposal = AIProposal(
        conversation_id=body.get("conversation_id"),
        requested_by_user_id=g.session["user_id"],
        action=action,
        params_json=json.dumps(params),
        summary=summary,
    )
    db.session.add(proposal)
    db.session.commit()
    return jsonify(proposal.to_dict()), 201


@ai_bp.get("/proposals")
@permission_required("admin")
def list_proposals():
    status = request.args.get("status", AIProposal.STATUS_PENDING)
    q = AIProposal.query
    if status != "all":
        q = q.filter_by(status=status)
    proposals = q.order_by(AIProposal.created_at.desc()).limit(50).all()
    return jsonify({"proposals": [p.to_dict() for p in proposals]})


@ai_bp.post("/proposals/<int:proposal_id>/approve")
@permission_required("admin")
def approve_proposal(proposal_id):
    proposal = db.session.get(AIProposal, proposal_id)
    if not proposal:
        return jsonify({"error": "Not found."}), 404
    if proposal.status != AIProposal.STATUS_PENDING:
        return jsonify({"error": f"Proposal is already {proposal.status}."}), 409

    settings = AISettings.get()
    if settings.read_only:
        return jsonify({"error": "AI is in read-only mode -- enable actions in AI Settings first."}), 403

    fn = ai_tools.WRITE_TOOLS[proposal.action]
    params = json.loads(proposal.params_json)
    proposal.decided_by_user_id = g.session["user_id"]
    proposal.decided_at = datetime.now(timezone.utc)

    try:
        result = fn(g.session["role"], **params)
        proposal.status = AIProposal.STATUS_APPROVED
        proposal.result_json = json.dumps(result)
    except (ai_tools.ToolWriteError, ai_tools.ToolPermissionError) as exc:
        proposal.status = AIProposal.STATUS_FAILED
        proposal.result_json = json.dumps({"error": str(exc)})
    db.session.commit()
    return jsonify(proposal.to_dict())


@ai_bp.post("/proposals/<int:proposal_id>/reject")
@permission_required("admin")
def reject_proposal(proposal_id):
    proposal = db.session.get(AIProposal, proposal_id)
    if not proposal:
        return jsonify({"error": "Not found."}), 404
    if proposal.status != AIProposal.STATUS_PENDING:
        return jsonify({"error": f"Proposal is already {proposal.status}."}), 409
    proposal.status = AIProposal.STATUS_REJECTED
    proposal.decided_by_user_id = g.session["user_id"]
    proposal.decided_at = datetime.now(timezone.utc)
    db.session.commit()
    return jsonify(proposal.to_dict())
