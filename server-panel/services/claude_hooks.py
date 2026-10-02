"""Wires txerr (tools/txerr) into Claude Code sessions for linked folders,
so live FiveM errors reach the claude.ai/code session working on them.

  * claude-hooks.json (root-only): which servers exist, where their error
    feed / console log live, and a local API token for `txerr restart`.
  * <folder>/.claude/settings.local.json: SessionStart (intro + watcher),
    Stop (re-arm watcher) and UserPromptSubmit (catch-up) hooks. Our entries
    are merged into anything already there and removed again on unlink.
  * push file per server: "Fix with Claude" requests from the panel.
"""
import json
import os
import secrets
import time

from services import txadmin_service as txsvc
from services import tx_errors

TXERR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "txerr")
CONF = os.path.join(txsvc.ENV_DIR, "claude-hooks.json")
PUSH_DIR = os.path.join(txsvc.ENV_DIR, "claude-push")
TOKEN_NAME = "Claude Code live errors (internal)"


def _hook(cmd, **extra):
    return {"type": "command", "command": f"{TXERR} {cmd}", **extra}


OUR_HOOKS = {
    "SessionStart": [{"hooks": [_hook("intro", timeout=15), _hook("watch", **{"async": True, "asyncRewake": True})]}],
    "Stop": [{"hooks": [_hook("watch", **{"async": True, "asyncRewake": True})]}],
    "UserPromptSubmit": [{"hooks": [_hook("context", timeout=15)]}],
}
OUR_ALLOW = ["Bash(txerr errors:*)", "Bash(txerr errors)", "Bash(txerr console:*)", "Bash(txerr console)", "Bash(txerr resources)"]


def _is_ours(entry):
    return any(TXERR in (h.get("command") or "") for h in entry.get("hooks", []))


def write_config(app):
    """(Re)write claude-hooks.json from the current instances."""
    from database import db
    from models.tx_api_token import TxApiToken
    from models.tx_instance import TxInstance
    try:
        with open(CONF) as f:
            old = json.load(f)
    except (OSError, ValueError):
        old = {}
    token = old.get("token")
    tok_row = TxApiToken.query.filter_by(name=TOKEN_NAME).first()
    if not token or not tok_row or tok_row.token_hash != TxApiToken.hash(token):
        if tok_row:
            db.session.delete(tok_row)
        token = TxApiToken.generate()
        db.session.add(TxApiToken(name=TOKEN_NAME, token_hash=TxApiToken.hash(token), prefix=token[:10], scope="*"))
        db.session.commit()
    os.makedirs(PUSH_DIR, mode=0o700, exist_ok=True)
    servers = []
    for inst in TxInstance.query.all():
        try:
            root = txsvc._resources_root(inst)
        except txsvc.TxError:
            continue
        servers.append({"id": inst.id, "slug": inst.slug, "name": inst.name, "resources_root": root,
                        "errors_file": os.path.join(tx_errors.ERR_DIR, f"{inst.slug}.jsonl"),
                        "push_file": os.path.join(PUSH_DIR, f"{inst.slug}.jsonl"),
                        "log_path": os.path.join(inst.txdata_dir, "default", "logs", "fxserver.log")})
    port = app.config.get("PANEL_PORT", 9500)
    data = {"api_base": f"http://127.0.0.1:{port}/tx/api/v1", "token": token, "servers": servers}
    fd = os.open(CONF + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(CONF + ".tmp", CONF)
    return data


def install(folder):
    """Merge our hooks + read-only txerr permissions into folder/.claude/settings.local.json."""
    d = os.path.join(folder, ".claude")
    path = os.path.join(d, "settings.local.json")
    os.makedirs(d, exist_ok=True)
    try:
        with open(path) as f:
            cur = json.load(f)
    except (OSError, ValueError):
        cur = {}
    hooks = cur.setdefault("hooks", {})
    for event, entries in OUR_HOOKS.items():
        kept = [e for e in hooks.get(event, []) if not _is_ours(e)]
        hooks[event] = kept + entries
    perms = cur.setdefault("permissions", {})
    allow = perms.setdefault("allow", [])
    for a in OUR_ALLOW:
        if a not in allow:
            allow.append(a)
    with open(path + ".tmp", "w") as f:
        json.dump(cur, f, indent=2)
    os.replace(path + ".tmp", path)
    return path


def uninstall(folder):
    path = os.path.join(folder, ".claude", "settings.local.json")
    try:
        with open(path) as f:
            cur = json.load(f)
    except (OSError, ValueError):
        return
    hooks = cur.get("hooks", {})
    for event in list(hooks):
        hooks[event] = [e for e in hooks[event] if not _is_ours(e)]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        cur.pop("hooks", None)
    allow = cur.get("permissions", {}).get("allow")
    if allow is not None:
        cur["permissions"]["allow"] = [a for a in allow if a not in OUR_ALLOW]
        if not cur["permissions"]["allow"]:
            cur["permissions"].pop("allow")
        if not cur["permissions"]:
            cur.pop("permissions")
    if cur:
        with open(path, "w") as f:
            json.dump(cur, f, indent=2)
    else:
        os.remove(path)
        try:
            os.rmdir(os.path.dirname(path))
        except OSError:
            pass


def installed(folder):
    try:
        with open(os.path.join(folder, ".claude", "settings.local.json")) as f:
            return any(_is_ours(e) for e in json.load(f).get("hooks", {}).get("Stop", []))
    except (OSError, ValueError):
        return False


def push(inst, err):
    """Queue a 'Fix with Claude' request for sessions covering err['resource']."""
    os.makedirs(PUSH_DIR, mode=0o700, exist_ok=True)
    loc = (err.get("file") or "") + (f":{err['line']}" if err.get("line") else "")
    text = f"Resource {err['resource']}" + (f" ({loc})" if loc else "") + f": {err['message']}"
    if err.get("reason") and err["reason"] not in err["message"]:
        text += f"\nCause: {err['reason']}"
    det = [x for x in (err.get("detail") or []) if x.strip()][:12]
    if det:
        text += "\nDetail:\n" + "\n".join("  " + x[:300] for x in det)
    text += f"\nIt has happened {err.get('count', 1)} time(s). Please find the cause in the files and fix it, then restart the resource with `txerr restart {err['resource']}` (tell me first if players might be affected)."
    entry = {"id": secrets.token_hex(6), "resource": err["resource"], "text": text, "ts": time.time(), "error_id": err["id"]}
    path = os.path.join(PUSH_DIR, f"{inst.slug}.jsonl")
    lines = []
    try:
        with open(path) as f:
            lines = f.readlines()[-49:]
    except OSError:
        pass
    lines.append(json.dumps(entry) + "\n")
    with open(path + ".tmp", "w") as f:
        f.writelines(lines)
    os.replace(path + ".tmp", path)
    return entry
