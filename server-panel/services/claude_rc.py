"""Claude Code Remote Control for txAdmin server folders.

`claude remote-control` runs a persistent Claude Code server in a folder
that you drive from claude.ai/code (or the Claude app) — Claude works on
the real files on this machine. Each linked folder gets its own tmux
session (so it has a TTY for Claude Code's first-run questions) inside its
own transient systemd unit (so restarting the panel never kills it).

The panel never answers Claude Code's prompts by itself: it shows the
session's screen and the user clicks/types the answer, which is sent as
keystrokes. The same viewer drives `claude auth login`.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import time

CLAUDE = shutil.which("claude") or "/root/.local/bin/claude"
HOME = os.environ.get("HOME") or "/root"
CLAUDE_JSON = os.path.join(HOME, ".claude.json")
URL_RE = re.compile(r"https://claude\.ai/code[^\s'\"<>)]*")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][0-9A-B]|\x1b[=>]")
PERMISSION_MODES = ("default", "acceptEdits", "plan", "auto")


class ClaudeError(Exception):
    pass


def _run(args, timeout=20, check=True, env=None):
    e = dict(os.environ, HOME=HOME, TERM="xterm-256color")
    e.update(env or {})
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=e)
    except subprocess.TimeoutExpired as exc:
        raise ClaudeError(f"Timed out: {' '.join(args[:3])}") from exc
    if check and r.returncode != 0:
        raise ClaudeError((r.stderr or r.stdout).strip() or f"{args[0]} failed")
    return r


def installed():
    return os.path.isfile(CLAUDE) and os.access(CLAUDE, os.X_OK)


def version():
    try:
        return _run([CLAUDE, "--version"], timeout=15).stdout.strip()
    except ClaudeError:
        return None


def auth_status():
    if not installed():
        return {"installed": False, "loggedIn": False}
    try:
        data = json.loads(_run([CLAUDE, "auth", "status"], timeout=20, check=False).stdout or "{}")
    except ValueError:
        data = {}
    return {"installed": True, "version": version(), "loggedIn": bool(data.get("loggedIn")),
            "email": data.get("email"), "orgName": data.get("orgName"), "authMethod": data.get("authMethod")}


def logout():
    _run([CLAUDE, "auth", "logout"], timeout=20)


def is_trusted(path):
    """Claude Code trusts a folder if it, or any parent, accepted the trust dialog."""
    try:
        with open(CLAUDE_JSON) as f:
            projects = json.load(f).get("projects", {})
    except (OSError, ValueError):
        return False
    path = os.path.realpath(path)
    while True:
        if projects.get(path, {}).get("hasTrustDialogAccepted"):
            return True
        parent = os.path.dirname(path)
        if parent == path:
            return False
        path = parent


# ---------------------------------------------------------------- tmux sessions in systemd units

def _ids(key):
    safe = re.sub(r"[^a-z0-9-]", "-", key.lower())[:60]
    return f"claude-{safe}", f"claude-{safe}"   # (systemd unit, tmux socket)


def session_alive(key):
    _, sock = _ids(key)
    return _run(["tmux", "-L", sock, "has-session", "-t", "main"], check=False).returncode == 0


def start_session(key, cwd, command, keep_seconds=3600):
    """Run `command` in a fresh tmux session under its own systemd unit.
    When the command exits the pane stays up for `keep_seconds` showing the
    exit code, so errors are readable from the panel."""
    unit, sock = _ids(key)
    stop_session(key)
    wrapped = f"{command}; code=$?; printf '\\n[claude exited with code %s]\\n' \"$code\"; sleep {int(keep_seconds)}"
    path_env = os.environ.get("PATH", "") + ":" + os.path.dirname(CLAUDE)
    args = ["systemd-run", f"--unit={unit}", "--collect", "--quiet", "-p", "Type=forking", "-p", f"WorkingDirectory={cwd}",
            f"--setenv=HOME={HOME}", "--setenv=TERM=xterm-256color", f"--setenv=PATH={path_env}",
            "tmux", "-L", sock, "new-session", "-d", "-s", "main", "-x", "150", "-y", "45", "-c", cwd, "bash", "-lc", wrapped]
    _run(args, timeout=30)
    for _ in range(20):
        if session_alive(key):
            return True
        time.sleep(0.15)
    raise ClaudeError("Claude Code session didn't start.")


def stop_session(key):
    unit, sock = _ids(key)
    _run(["tmux", "-L", sock, "kill-server"], check=False)
    _run(["systemctl", "stop", f"{unit}.service"], check=False, timeout=30)
    _run(["systemctl", "reset-failed", f"{unit}.service"], check=False)


def screen(key, lines=400):
    _, sock = _ids(key)
    r = _run(["tmux", "-L", sock, "capture-pane", "-p", "-J", "-t", "main", "-S", f"-{lines}"], check=False)
    if r.returncode != 0:
        return None
    text = ANSI_RE.sub("", r.stdout).replace("\r", "")
    return text.rstrip("\n")


ALLOWED_KEYS = {"Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BSpace", "C-c", "y", "n", "1", "2", "3"}


def send(key, text=None, keys=None, enter=False):
    _, sock = _ids(key)
    if not session_alive(key):
        raise ClaudeError("That Claude Code session isn't running.")
    if text:
        if len(text) > 4000:
            raise ClaudeError("Too much text.")
        _run(["tmux", "-L", sock, "send-keys", "-t", "main", "-l", text])
    for k in keys or []:
        if k not in ALLOWED_KEYS:
            raise ClaudeError(f"Key '{k}' isn't allowed.")
        _run(["tmux", "-L", sock, "send-keys", "-t", "main", k])
    if enter:
        _run(["tmux", "-L", sock, "send-keys", "-t", "main", "Enter"])


def analyse(text):
    """Work out what the session is doing / asking from its screen."""
    if text is None:
        return {"state": "stopped", "prompt": None, "url": None}
    tail = "\n".join(text.splitlines()[-25:])
    urls = URL_RE.findall(text)
    url = urls[-1].rstrip(".,") if urls else None
    low = tail.lower()
    exited = re.search(r"\[claude exited with code (\d+)\]", tail)
    if "workspace not trusted" in low:
        return {"state": "untrusted", "prompt": None, "url": url}
    if exited:
        return {"state": "exited", "code": int(exited.group(1)), "prompt": None, "url": url}
    if "enable remote control?" in low:
        return {"state": "waiting", "prompt": "consent", "question": "Enable Remote Control for this account?", "url": url}
    if "trust the files" in low or "do you trust" in low or ("trust" in low and "proceed" in low):
        return {"state": "waiting", "prompt": "trust", "question": "Trust the files in this folder?", "url": url}
    if "paste code" in low or "authorization code" in low or "enter the code" in low:
        return {"state": "waiting", "prompt": "code", "question": "Paste the code from the login page", "url": url}
    if re.search(r"\(y/n\)\s*$", tail.strip(), re.I | re.M):
        return {"state": "waiting", "prompt": "yn", "question": tail.strip().splitlines()[-1][:200], "url": url}
    if "not logged in" in low or "please run /login" in low or "run `claude auth login`" in low:
        return {"state": "auth", "prompt": None, "url": url}
    return {"state": "running", "prompt": None, "url": url}


# ---------------------------------------------------------------- remote control links / trust / login

def link_key(link_id):
    return f"rc-{link_id}"


def start_remote_control(link_id, cwd, name, permission_mode="default"):
    if not installed():
        raise ClaudeError("Claude Code isn't installed on this server.")
    if not os.path.isdir(cwd):
        raise ClaudeError("That folder doesn't exist any more.")
    cmd = f"{shlex.quote(CLAUDE)} remote-control --name {shlex.quote(name)} --spawn same-dir"
    if permission_mode in PERMISSION_MODES and permission_mode != "default":
        cmd += f" --permission-mode {permission_mode}"
    start_session(link_key(link_id), cwd, cmd)


def start_trust(key, cwd):
    """Open interactive `claude` in cwd so the user can answer the trust dialog."""
    start_session(key, cwd, shlex.quote(CLAUDE), keep_seconds=120)


def start_login():
    start_session("login", HOME, f"{shlex.quote(CLAUDE)} auth login", keep_seconds=600)


def link_status(link_id):
    text = screen(link_key(link_id))
    info = analyse(text)
    info["alive"] = text is not None
    info["screen"] = "\n".join((text or "").splitlines()[-60:])
    return info
