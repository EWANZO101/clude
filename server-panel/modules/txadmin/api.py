"""txAdmin REST API: /tx/api/v1

Two ways in:
  * the panel's own session (the custom control panel page uses this) —
    POSTs then need the usual X-CSRFToken header;
  * `Authorization: Bearer txp_…` tokens created on the /tx page, for
    scripts/bots. Tokens can be limited to specific servers.

Every call is forwarded to the instance's txAdmin as its saved master
account (see services/txadmin_api.py), so actions appear in txAdmin's admin
log, and txAdmin's own validation/permissions still apply.
"""
import os
from datetime import datetime
from functools import wraps

from flask import Blueprint, abort, current_app, g, jsonify, request
from flask_login import current_user

from database import db
from extensions import csrf
from models.tx_api_token import TxApiToken
from models.tx_instance import TxInstance
from services import txadmin_api as txapi
from services import txadmin_service as txsvc

txapi_bp = Blueprint("txapi", __name__, url_prefix="/tx/api/v1")
csrf.exempt(txapi_bp)  # session callers are CSRF-checked in api_auth; token callers have no cookie to forge

RESOURCE_ACTIONS = {"start": "start_res", "stop": "stop_res", "restart": "restart_res", "ensure": "ensure_res"}
PLAYER_ACTIONS = {"kick", "warn", "ban", "message", "save_note", "whitelist"}


def _ok(**data):
    return jsonify({"ok": True, **data})


def _fail(msg, status=400):
    return jsonify({"ok": False, "error": str(msg)}), status


def api_auth(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        header = request.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            tok = TxApiToken.query.filter_by(token_hash=TxApiToken.hash(header[7:].strip())).first()
            if not tok:
                return _fail("Invalid API token.", 401)
            if (datetime.utcnow() - (tok.last_used_at or datetime.min)).total_seconds() > 60:
                tok.last_used_at = datetime.utcnow()
                db.session.commit()
            g.api_token, g.api_actor = tok, f"token:{tok.name}"
        elif current_user.is_authenticated:
            if not current_user.has_permission("txadmin.manage"):
                return _fail("You don't have permission to manage txAdmin servers.", 403)
            if request.method not in ("GET", "HEAD", "OPTIONS") and current_app.config.get("WTF_CSRF_ENABLED", True):
                csrf.protect()
            g.api_token, g.api_actor = None, current_user.username
        else:
            return _fail("Authentication required (panel session or Bearer token).", 401)
        txapi.reap_idle_links()
        return view(*args, **kwargs)
    return wrapped


def _inst(inst_id):
    inst = db.session.get(TxInstance, inst_id)
    if not inst:
        abort(404)
    if g.api_token is not None and not g.api_token.allows(inst_id):
        abort(403)
    return inst


def _audit(inst, action, detail=""):
    current_app.logger.warning("TXAPI %s on %s by %s %s", action, inst.slug, g.api_actor, detail)


def _relay(data, **extra):
    ok, msg, raw = txapi.tx_result(data)
    if not ok:
        return _fail(msg)
    return _ok(message=msg, result=raw, **extra)


@txapi_bp.errorhandler(txapi.TxApiError)
def _tx_err(exc):
    return _fail(exc, 502)


@txapi_bp.errorhandler(400)
def _bad(exc):
    return _fail(getattr(exc, "description", None) or "Bad request.", 400)


@txapi_bp.errorhandler(404)
def _nf(_):
    return _fail("Not found.", 404)


@txapi_bp.errorhandler(403)
def _forbidden(_):
    return _fail("This token can't access that server.", 403)


# ---------------------------------------------------------------- servers

@txapi_bp.route("/servers")
@api_auth
def servers():
    ip = txsvc.public_ip()
    out = []
    for inst in TxInstance.query.order_by(TxInstance.created_at).all():
        if g.api_token is not None and not g.api_token.allows(inst.id):
            continue
        d = inst.to_dict(ip, secrets=False)
        d["has_login"] = bool(inst.tx_username and inst.tx_password)
        out.append(d)
    return _ok(servers=out)


@txapi_bp.route("/servers/<int:inst_id>")
@api_auth
def overview(inst_id):
    inst = _inst(inst_id)
    data = txapi.overview(inst)
    data["server"] = inst.to_dict(txsvc.public_ip(), secrets=False)
    data["service"] = txsvc.status(inst)
    return _ok(**data)


@txapi_bp.route("/servers/<int:inst_id>/control", methods=["POST"])
@api_auth
def control(inst_id):
    """start / stop / restart the FXServer process via txAdmin (txAdmin itself keeps running)."""
    inst = _inst(inst_id)
    action = (request.get_json(silent=True) or {}).get("action")
    if action not in ("start", "stop", "restart"):
        return _fail("action must be start, stop or restart.")
    _audit(inst, f"control {action}")
    return _relay(txapi.client_for(inst).post("/fxserver/controls", {"action": action}))


# ---------------------------------------------------------------- console

@txapi_bp.route("/servers/<int:inst_id>/console")
@api_auth
def console_read(inst_id):
    inst = _inst(inst_id)
    c = txapi.client_for(inst)
    c.ensure_link()
    offset = request.args.get("offset", type=int)
    text, end, reset = c.console_since(offset)
    return _ok(data=text, offset=end, reset=reset)


@txapi_bp.route("/servers/<int:inst_id>/console", methods=["POST"])
@api_auth
def console_write(inst_id):
    inst = _inst(inst_id)
    cmd = ((request.get_json(silent=True) or {}).get("command") or "").strip()
    if not cmd:
        return _fail("command is required.")
    if len(cmd) > 2000:
        return _fail("Command too long.")
    txapi.client_for(inst).send_console(cmd)
    _audit(inst, "console", repr(cmd[:200]))
    return _ok()


# ---------------------------------------------------------------- server-wide actions

@txapi_bp.route("/servers/<int:inst_id>/announce", methods=["POST"])
@api_auth
def announce(inst_id):
    inst = _inst(inst_id)
    msg = ((request.get_json(silent=True) or {}).get("message") or "").strip()
    if not msg:
        return _fail("message is required.")
    _audit(inst, "announce", repr(msg[:200]))
    return _relay(txapi.client_for(inst).post("/fxserver/commands", {"action": "admin_broadcast", "parameter": msg}))


@txapi_bp.route("/servers/<int:inst_id>/kick-all", methods=["POST"])
@api_auth
def kick_all(inst_id):
    inst = _inst(inst_id)
    reason = ((request.get_json(silent=True) or {}).get("reason") or "").strip()
    _audit(inst, "kick all", repr(reason[:200]))
    return _relay(txapi.client_for(inst).post("/fxserver/commands", {"action": "kick_all", "parameter": reason}))


@txapi_bp.route("/servers/<int:inst_id>/schedule", methods=["POST"])
@api_auth
def schedule(inst_id):
    """{"time": "+15"} or {"time": "04:30"} schedules a one-off restart;
    {"skip": true|false} skips / un-skips the next scheduled restart."""
    inst = _inst(inst_id)
    d = request.get_json(silent=True) or {}
    c = txapi.client_for(inst)
    if "skip" in d:
        _audit(inst, "schedule skip", str(d["skip"]))
        return _relay(c.post("/fxserver/schedule", {"action": "setNextSkip", "parameter": bool(d["skip"])}))
    t = str(d.get("time") or "").strip()
    if not t:
        return _fail('time is required ("+15" for 15 minutes from now, or "HH:MM").')
    _audit(inst, "schedule restart", t)
    return _relay(c.post("/fxserver/schedule", {"action": "setNextTempSchedule", "parameter": t}))


# ---------------------------------------------------------------- resources

@txapi_bp.route("/servers/<int:inst_id>/resources")
@api_auth
def resources(inst_id):
    """Every resource on disk (with its [category] folder) plus anything
    running that isn't on disk (system resources like monitor)."""
    inst = _inst(inst_id)
    info = txapi.fxserver_info(inst)
    running = set(info.get("resources") or []) if info else set()
    items, seen = [], set()
    for r in txsvc.scan_resources(inst):
        if r["name"] in seen:
            continue
        seen.add(r["name"])
        items.append({**r, "running": r["name"] in running})
    for name in sorted(running - seen, key=str.lower):
        items.append({"name": name, "folder": "(built-in)", "running": True})
    out = {"resources": items, "running": info is not None,
           "running_count": len(running), "folder_count": len({i["folder"] for i in items})}
    if info:
        out["server"] = info.get("server")
    return _ok(**out)


BULK_PROTECTED = {"monitor", "sessionmanager", "mapmanager", "spawnmanager", "hardcap", "chat", "yarn", "webpack"}


@txapi_bp.route("/servers/<int:inst_id>/resources/bulk", methods=["POST"])
@api_auth
def resource_bulk(inst_id):
    """{"action": "start|stop|restart", "names": [...]} or {"action", "folder"}
    (folder includes its subfolders). Only resources that exist on disk in
    the server data folder are accepted; txAdmin's own `monitor` and the
    cfx system resources are never stopped/restarted in bulk."""
    inst = _inst(inst_id)
    d = request.get_json(silent=True) or {}
    action = d.get("action")
    if action not in ("start", "stop", "restart"):
        return _fail("action must be start, stop or restart.")
    on_disk = txsvc.scan_resources(inst)
    info = txapi.fxserver_info(inst)
    if info is None:
        return _fail("The game server isn't running.")
    running = set(info.get("resources") or [])
    if d.get("folder") is not None:
        f = str(d["folder"])
        names = [r["name"] for r in on_disk if not f or r["folder"] == f or r["folder"].startswith(f + "/")]
    else:
        known = {r["name"] for r in on_disk}
        names = [n for n in (d.get("names") or []) if isinstance(n, str) and n in known]
    if action == "start":
        targets = [n for n in names if n not in running]
    else:
        targets = [n for n in names if n in running and n not in BULK_PROTECTED]
    if not targets:
        return _ok(done=[], failed=[], message="Nothing to do — they're already " + ("running." if action == "start" else "stopped."))
    if len(targets) > 300:
        return _fail("Too many resources at once (max 300).")
    c = txapi.client_for(inst)
    tx_action = {"start": "ensure_res", "stop": "stop_res", "restart": "restart_res"}[action]
    if action == "start":
        # FXServer only knows folders that existed at its last refresh;
        # without this, newly added resources fail with "Couldn't find resource".
        c.post("/fxserver/commands", {"action": "refresh_res", "parameter": ""})
    done, failed = [], []
    for n in sorted(targets, key=str.lower):
        ok, msg, _ = txapi.tx_result(c.post("/fxserver/commands", {"action": tx_action, "parameter": n}))
        (done if ok else failed).append(n if ok else {"name": n, "error": msg})
    _audit(inst, f"bulk {action}", f"{len(done)} ok, {len(failed)} failed: {', '.join(done)[:300]}")
    verb = {"start": "Started", "stop": "Stopped", "restart": "Restarted"}[action]
    return _ok(done=done, failed=failed, message=f"{verb} {len(done)} resource{'s' if len(done) != 1 else ''}" +
               (f", {len(failed)} failed" if failed else ""))


@txapi_bp.route("/servers/<int:inst_id>/resources/<action>", methods=["POST"])
@api_auth
def resource_action(inst_id, action):
    inst = _inst(inst_id)
    c = txapi.client_for(inst)
    if action == "refresh":
        _audit(inst, "refresh resources")
        return _relay(c.post("/fxserver/commands", {"action": "refresh_res", "parameter": ""}))
    if action not in RESOURCE_ACTIONS:
        return _fail("action must be start, stop, restart, ensure or refresh.")
    name = ((request.get_json(silent=True) or {}).get("name") or "").strip()
    if not name or len(name) > 128 or any(ch.isspace() for ch in name):
        return _fail("A single resource name is required.")
    _audit(inst, f"resource {action}", name)
    if action in ("start", "ensure"):
        c.post("/fxserver/commands", {"action": "refresh_res", "parameter": ""})  # pick up newly added folders
    return _relay(c.post("/fxserver/commands", {"action": RESOURCE_ACTIONS[action], "parameter": name}))


# ---------------------------------------------------------------- live errors

@txapi_bp.route("/servers/<int:inst_id>/errors")
@api_auth
def errors_list(inst_id):
    from services import tx_errors
    inst = _inst(inst_id)
    w = tx_errors.watcher_for(inst)
    errs = w.recent(resource=request.args.get("resource") or None, since_id=request.args.get("since", 0, type=int),
                    limit=min(200, request.args.get("limit", 50, type=int)))
    return _ok(errors=list(reversed(errs)), log=w.path, watching=os.path.exists(w.path))


@txapi_bp.route("/servers/<int:inst_id>/errors/clear", methods=["POST"])
@api_auth
def errors_clear(inst_id):
    from services import tx_errors
    inst = _inst(inst_id)
    tx_errors.watcher_for(inst).clear((request.get_json(silent=True) or {}).get("resource") or None)
    return _ok()


@txapi_bp.route("/servers/<int:inst_id>/errors/<int:err_id>/claude", methods=["POST"])
@api_auth
def errors_to_claude(inst_id, err_id):
    """Queue an error for the Claude session(s) whose linked folder contains it."""
    from models.tx_claude import TxClaudeLink
    from services import claude_hooks, claude_rc, tx_errors
    inst = _inst(inst_id)
    w = tx_errors.watcher_for(inst)
    err = next((e for e in w.recent(limit=300) if e["id"] == err_id), None)
    if not err:
        return _fail("That error isn't in the recent list any more.", 404)
    folder_of = {r["name"]: r["folder"] for r in txsvc.scan_resources(inst)}
    res_path = ((folder_of.get(err["resource"]) or "") + "/" + err["resource"]).strip("/") if err["resource"] in folder_of else None
    if not res_path:
        return _fail(f"{err['resource']} isn't a resource folder on disk, so no Claude session covers it.")
    covering = [l for l in TxClaudeLink.query.filter_by(instance_id=inst.id).all()
                if l.rel_path == "" or res_path == l.rel_path or res_path.startswith(l.rel_path + "/")]
    if not covering:
        return _fail("No Claude session covers this resource yet. Link its folder on the Claude Code tab first.", 409)
    live = [l for l in covering if claude_rc.session_alive(claude_rc.link_key(l.id))]
    claude_hooks.push(inst, err)
    with w.lock:
        err.setdefault("sent_to", [])
        for l in covering:
            if l.name not in err["sent_to"]:
                err["sent_to"].append(l.name)
        w._persist()
    best = min(covering, key=lambda l: -len(l.rel_path))   # most specific folder first
    _audit(inst, "error to claude", f"{err['resource']} #{err_id}")
    return _ok(sessions=[l.name for l in covering], live=[l.name for l in live], best=best.name,
               message=f"Sent to “{best.name}”" + ("" if live else ". Start that link to deliver it."))


# ---------------------------------------------------------------- resource files

@txapi_bp.route("/servers/<int:inst_id>/resource-files")
@api_auth
def resource_files(inst_id):
    inst = _inst(inst_id)
    try:
        return _ok(**txsvc.list_resource_files(inst, request.args.get("resource", "")))
    except txsvc.TxError as exc:
        return _fail(exc)


@txapi_bp.route("/servers/<int:inst_id>/resource-file")
@api_auth
def resource_file_read(inst_id):
    inst = _inst(inst_id)
    try:
        return _ok(**txsvc.read_resource_file(inst, request.args.get("resource", ""), request.args.get("path", "")))
    except txsvc.TxError as exc:
        return _fail(exc)


@txapi_bp.route("/servers/<int:inst_id>/resource-file", methods=["POST"])
@api_auth
def resource_file_write(inst_id):
    inst = _inst(inst_id)
    d = request.get_json(silent=True) or {}
    if not isinstance(d.get("content"), str):
        return _fail("content is required.")
    try:
        res = txsvc.write_resource_file(inst, d.get("resource") or "", d.get("path") or "", d["content"], d.get("mtime"))
        _audit(inst, "file save", f"{d.get('resource')}/{d.get('path')}")
        return _ok(**res)
    except txsvc.TxError as exc:
        return _fail(exc)


# ---------------------------------------------------------------- cfg editor

@txapi_bp.route("/servers/<int:inst_id>/cfg")
@api_auth
def cfg_list(inst_id):
    inst = _inst(inst_id)
    profile, main = txsvc.cfg_paths(inst)
    return _ok(files=txsvc.list_cfg_files(inst), profile=profile, main=main)


@txapi_bp.route("/servers/<int:inst_id>/cfg/file")
@api_auth
def cfg_read(inst_id):
    inst = _inst(inst_id)
    try:
        return _ok(name=request.args.get("name", ""), **txsvc.read_cfg(inst, request.args.get("name", "")))
    except txsvc.TxError as exc:
        return _fail(exc)


@txapi_bp.route("/servers/<int:inst_id>/cfg/file", methods=["POST"])
@api_auth
def cfg_write(inst_id):
    """{name, content, mtime, direct?}. The main server.cfg goes through
    txAdmin's own editor endpoint (validates exec/endpoint lines, keeps
    server.cfg.bkp, logs the admin) unless `direct` is set; other files are
    written directly with a timestamped backup."""
    inst = _inst(inst_id)
    d = request.get_json(silent=True) or {}
    name, content = d.get("name") or "", d.get("content")
    if not isinstance(content, str):
        return _fail("content is required.")
    if len(content) > 512 * 1024:
        return _fail("File too large.")
    _, main = txsvc.cfg_paths(inst)
    try:
        if name == main and not d.get("direct"):
            # conflict check before handing to txAdmin
            if d.get("mtime") is not None and abs(txsvc.cfg_mtime(inst, name) - float(d["mtime"])) > 0.001:
                return _fail("The file changed on disk since you opened it. Reload it to see the latest version.")
            res = txapi.client_for(inst).post("/cfgEditor/save", {"cfgData": content})
            kind = res.get("type") if isinstance(res, dict) else None
            msg = txapi._strip_html((res or {}).get("message") or (res or {}).get("msg") or "")
            _audit(inst, "cfg save (txAdmin)", name)
            if kind == "danger" or kind == "error":
                return jsonify({"ok": False, "error": msg or "txAdmin rejected the file.", "validation": "error"}), 400
            return _ok(message=msg or "File saved.", validation="warning" if kind == "warning" else "ok",
                       mtime=txsvc.cfg_mtime(inst, name), via="txadmin")
        result = txsvc.write_cfg(inst, name, content, d.get("mtime"))
        _audit(inst, "cfg save (direct)", name)
        return _ok(message=f"Saved. Backup: {result['backup']}", validation="none", mtime=result["mtime"], via="direct")
    except txsvc.TxError as exc:
        return _fail(exc)


# ---------------------------------------------------------------- players

def _player_ref():
    a = request.args
    if a.get("license"):
        return {"license": a["license"]}
    if a.get("netid"):
        return {"mutex": a.get("mutex") or "current", "netid": a["netid"]}
    abort(400, description="Address the player with ?netid=<id> (online) or ?license=<license>.")


@txapi_bp.route("/servers/<int:inst_id>/players")
@api_auth
def players_online(inst_id):
    inst = _inst(inst_id)
    data = txapi.overview(inst)
    return _ok(players=data["players"], mutex=data["mutex"])


@txapi_bp.route("/servers/<int:inst_id>/players/search")
@api_auth
def players_search(inst_id):
    inst = _inst(inst_id)
    a = request.args
    params = {"sortingKey": a.get("sort", "tsLastConnection"), "sortingDesc": a.get("desc", "true")}
    if a.get("q"):
        params.update(searchValue=a["q"], searchType=a.get("type", "playerName"))
    if a.get("filters"):
        params["filters"] = a["filters"]
    if a.get("offset_param") and a.get("offset_license"):
        params.update(offsetParam=a["offset_param"], offsetLicense=a["offset_license"])
    return _relay(txapi.client_for(inst).get("/player/search", **params))


@txapi_bp.route("/servers/<int:inst_id>/players/stats")
@api_auth
def players_stats(inst_id):
    return _relay(txapi.client_for(_inst(inst_id)).get("/player/stats"))


@txapi_bp.route("/servers/<int:inst_id>/player")
@api_auth
def player(inst_id):
    inst = _inst(inst_id)
    return _relay(txapi.client_for(inst).get("/player", **_player_ref()))


@txapi_bp.route("/servers/<int:inst_id>/player/<action>", methods=["POST"])
@api_auth
def player_action(inst_id, action):
    """kick {reason} · warn {reason} · ban {reason, duration: "2 hours"|"permanent"}
    · message {message} · save_note {note} · whitelist {status: true|false}"""
    inst = _inst(inst_id)
    if action not in PLAYER_ACTIONS:
        return _fail(f"action must be one of: {', '.join(sorted(PLAYER_ACTIONS))}")
    body = request.get_json(silent=True) or {}
    ref = _player_ref()
    _audit(inst, f"player {action}", f"{ref} {str(body)[:200]}")
    return _relay(txapi.client_for(inst).post(f"/player/{action}", body, **ref))


# ---------------------------------------------------------------- history (bans / warns)

@txapi_bp.route("/servers/<int:inst_id>/history")
@api_auth
def history(inst_id):
    inst = _inst(inst_id)
    a = request.args
    params = {"sortingKey": "timestamp", "sortingDesc": a.get("desc", "true")}
    if a.get("q"):
        params.update(searchValue=a["q"], searchType=a.get("type", "identifiers"))
    if a.get("filter_type") in ("ban", "warn"):
        params["filterbyType"] = a["filter_type"]
    if a.get("offset_param") and a.get("offset_action"):
        params.update(offsetParam=a["offset_param"], offsetActionId=a["offset_action"])
    return _relay(txapi.client_for(inst).get("/history/search", **params))


@txapi_bp.route("/servers/<int:inst_id>/history/revoke", methods=["POST"])
@api_auth
def history_revoke(inst_id):
    inst = _inst(inst_id)
    action_id = ((request.get_json(silent=True) or {}).get("action_id") or "").strip()
    if not action_id:
        return _fail("action_id is required.")
    _audit(inst, "revoke action", action_id)
    return _relay(txapi.client_for(inst).post("/history/revokeAction", {"actionId": action_id}))


@txapi_bp.route("/servers/<int:inst_id>/ban-ids", methods=["POST"])
@api_auth
def ban_ids(inst_id):
    """Ban identifiers of a player who isn't in the database (offline ban)."""
    inst = _inst(inst_id)
    d = request.get_json(silent=True) or {}
    ids = d.get("identifiers") or []
    if not isinstance(ids, list) or not ids:
        return _fail("identifiers must be a non-empty list, e.g. [\"license:…\", \"discord:…\"].")
    body = {"identifiers": ids, "reason": d.get("reason") or "", "duration": d.get("duration") or "permanent"}
    _audit(inst, "ban ids", str(ids)[:200])
    return _relay(txapi.client_for(inst).post("/history/addLegacyBan", body))


# ---------------------------------------------------------------- tokens (panel session only)

def _session_only():
    if g.api_token is not None:
        abort(403)


@txapi_bp.route("/tokens")
@api_auth
def tokens_list():
    _session_only()
    return _ok(tokens=[t.to_dict() for t in TxApiToken.query.order_by(TxApiToken.created_at.desc()).all()])


@txapi_bp.route("/tokens", methods=["POST"])
@api_auth
def tokens_create():
    _session_only()
    d = request.get_json(silent=True) or {}
    name = (d.get("name") or "").strip()
    if not 2 <= len(name) <= 80:
        return _fail("Give the token a name (2–80 characters).")
    scope = d.get("scope") or "*"
    if scope != "*":
        ids = [str(int(x)) for x in (scope if isinstance(scope, list) else str(scope).split(",")) if str(x).strip()]
        if not ids:
            return _fail("Pick at least one server, or all servers.")
        scope = ",".join(ids)
    raw = TxApiToken.generate()
    tok = TxApiToken(name=name, token_hash=TxApiToken.hash(raw), prefix=raw[:10], scope=scope, created_by=current_user.id)
    db.session.add(tok)
    db.session.commit()
    current_app.logger.warning("TXAPI token created by %s: %s (scope %s)", current_user.username, name, scope)
    return _ok(token=raw, info=tok.to_dict())


@txapi_bp.route("/tokens/<int:token_id>", methods=["DELETE"])
@api_auth
def tokens_delete(token_id):
    _session_only()
    tok = db.session.get(TxApiToken, token_id)
    if not tok:
        abort(404)
    db.session.delete(tok)
    db.session.commit()
    current_app.logger.warning("TXAPI token revoked by %s: %s", current_user.username, tok.name)
    return _ok()
