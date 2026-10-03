"""Live FXServer error capture for txAdmin servers.

Follows txAdmin's live console log (txData/default/logs/fxserver.log),
groups each error with its continuation lines (query, cause, stack), works
out which resource it belongs to, de-duplicates repeats and keeps the
recent ones per server — in memory for the panel, and in a JSONL file
(ERR_DIR/<slug>.jsonl) so Claude Code hooks/MCP tools running in other
processes can read them.

Only server-side errors are visible here; client (F8) errors never reach
the server console.
"""
import hashlib
import json
import os
import re
import threading
import time
from collections import deque

from services import txadmin_service as txsvc

ERR_DIR = os.path.join(txsvc.ENV_DIR, "errors")
KEEP = 300                # per-server error history
GROUP_IDLE = 1.2          # seconds of quiet that closes an error block
MAX_BLOCK_LINES = 40

LINE_RE = re.compile(r"^\[\s*([^\]]+?)\s*\]\s?(.*)$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# (regex on the message, how to get the resource) — first match wins
TRIGGERS = [
    (re.compile(r"SCRIPT ERROR: @([\w.\-]+)/([^:]+):(\d+): ?(.*)"), "script_error"),
    (re.compile(r"Error parsing script @([\w.\-]+)/(\S+?)(?: in resource ([\w.\-]+))?: ?(.*)"), "parse_error"),
    (re.compile(r"Error loading script ([\w./\-]+) in resource ([\w.\-]+): ?(.*)"), "load_error"),
    (re.compile(r"Error: ([\w.\-]+) was unable to execute a query!"), "sql_error"),
    (re.compile(r"Couldn't start resource ([\w.\-]+)\.?(.*)"), "start_error"),
    (re.compile(r"Failed to load script ([\w./\-]+)\.?"), "load_error"),
    (re.compile(r"Could not find dependency ([\w.\-]+) for resource ([\w.\-]+)"), "dependency"),
    (re.compile(r"^(?:\^1)?(?:Error|ERROR)[: ](.*)"), "generic"),
]
CHANNEL_RES_RE = re.compile(r"^script:([\w.\-]+)$")
IGNORE_RE = re.compile(r"txaPing|txAdmin|\[INFO\]")


def _signature(resource, kind, first):
    norm = re.sub(r"\d+", "N", first)[:200]
    norm = re.sub(r'"[^"]*"|\'[^\']*\'', "S", norm)
    return hashlib.sha1(f"{resource}|{kind}|{norm}".encode()).hexdigest()[:12]


class ErrorWatcher:
    """Tails one instance's fxserver.log."""

    def __init__(self, inst_id, slug, name, txdata_dir):
        self.inst_id, self.slug, self.name = inst_id, slug, name
        self.path = os.path.join(txdata_dir, "default", "logs", "fxserver.log")
        self.errors = deque(maxlen=KEEP)          # newest last
        self.by_sig = {}
        self.listeners = []                       # callables(err_dict)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.block = None
        self.last_line_at = 0
        self.seq = 0
        os.makedirs(ERR_DIR, mode=0o700, exist_ok=True)
        self.file = os.path.join(ERR_DIR, f"{slug}.jsonl")
        self._load_history()

    # ------------------------------------------------------------ persistence
    def _load_history(self):
        try:
            with open(self.file) as f:
                for line in f.readlines()[-KEEP:]:
                    e = json.loads(line)
                    self.errors.append(e)
                    self.by_sig[e["sig"]] = e
                    self.seq = max(self.seq, e.get("id", 0))
        except (OSError, ValueError):
            pass

    def _persist(self):
        tmp = self.file + ".tmp"
        with open(tmp, "w") as f:
            for e in self.errors:
                f.write(json.dumps(e) + "\n")
        os.replace(tmp, self.file)

    # ------------------------------------------------------------ parsing
    def _start_block(self, channel, msg, kind, m):
        g = m.groups()
        res, file, line = None, None, None
        if kind == "script_error":
            res, file, line = g[0], g[1], int(g[2])
        elif kind == "parse_error":
            res, file = g[2] or g[0], g[1]
            lm = re.search(r":(\d+):", g[3] or "")
            line = int(lm.group(1)) if lm else None
        elif kind == "load_error":
            if len(g) >= 2 and g[1]:
                file, res = g[0], g[1]
            else:
                file = g[0]
                res = file.split("/")[0].lstrip("@")
        elif kind in ("sql_error", "start_error"):
            res = g[0]
        elif kind == "dependency":
            res = g[1]
        cm = CHANNEL_RES_RE.match(channel)
        if not res and cm:
            res = cm.group(1)
        self.block = {"channel": channel, "kind": kind, "resource": res or channel, "file": file, "line": line,
                      "lines": [msg], "started": time.time()}

    def _finish_block(self):
        b, self.block = self.block, None
        if not b:
            return
        first = b["lines"][0]
        detail = [l for l in b["lines"][1:] if not l.startswith("> <unknown>") and "citizen//scripting" not in l][:25]
        reason = next((l for l in detail if re.search(r"doesn't exist|error in your SQL|attempt to|nil value|expected|not found|unknown column|Duplicate", l, re.I)), None)
        sig = _signature(b["resource"], b["kind"], first if b["kind"] != "sql_error" else (reason or first))
        now = time.time()
        with self.lock:
            existing = self.by_sig.get(sig)
            if existing:
                existing["count"] += 1
                existing["last"] = now
                existing["detail"] = detail or existing["detail"]
                self.errors.remove(existing)
                self.errors.append(existing)
                err, is_new = existing, False
            else:
                self.seq += 1
                err = {"id": self.seq, "sig": sig, "server": self.slug, "resource": b["resource"], "kind": b["kind"],
                       "file": b["file"], "line": b["line"], "message": first[:500], "reason": reason, "detail": detail,
                       "count": 1, "first": now, "last": now, "sent_to": []}
                self.errors.append(err)
                self.by_sig[sig] = err
                is_new = True
            self._persist()
        for fn in list(self.listeners):
            try:
                fn(err, is_new)
            except Exception:  # noqa: BLE001
                pass

    def feed(self, raw):
        raw = ANSI_RE.sub("", raw).rstrip("\n")
        m = LINE_RE.match(raw)
        channel, msg = (m.group(1), m.group(2)) if m else ("", raw)
        self.last_line_at = time.time()
        if self.block and channel == self.block["channel"]:
            # a new trigger on the same channel starts a new error
            if any(t.search(msg) for t, kind in TRIGGERS[:-1]):
                self._finish_block()
            elif len(self.block["lines"]) < MAX_BLOCK_LINES:
                self.block["lines"].append(msg)
                return
        elif self.block:
            self._finish_block()
        if IGNORE_RE.search(msg):
            return
        for rx, kind in TRIGGERS:
            mm = rx.search(msg)
            if mm:
                if kind == "generic" and not CHANNEL_RES_RE.match(channel):
                    return
                self._start_block(channel, msg, kind, mm)
                return

    # ------------------------------------------------------------ tailing
    def run(self):
        pos, ino = None, None
        while not self.stop.is_set():
            try:
                st = os.stat(self.path)
            except OSError:
                time.sleep(3)
                continue
            if ino != st.st_ino or (pos is not None and st.st_size < pos):
                pos, ino = (st.st_size if pos is None and ino is None else 0), st.st_ino   # start at end on first run
            if st.st_size > pos:
                with open(self.path, "r", encoding="utf-8", errors="replace") as f:
                    f.seek(pos)
                    chunk = f.read(1024 * 1024)
                    pos = f.tell()
                for line in chunk.splitlines():
                    self.feed(line)
            if self.block and time.time() - self.last_line_at > GROUP_IDLE:
                self._finish_block()
            time.sleep(0.5)

    def recent(self, resource=None, folder_resources=None, since_id=0, limit=50):
        with self.lock:
            out = [e for e in self.errors if e["id"] > since_id
                   and (resource is None or e["resource"] == resource)
                   and (folder_resources is None or e["resource"] in folder_resources)]
        return out[-limit:]

    def clear(self, resource=None):
        with self.lock:
            keep = [e for e in self.errors if resource and e["resource"] != resource]
            self.errors.clear()
            self.errors.extend(keep)
            self.by_sig = {e["sig"]: e for e in keep}
            self._persist()


_watchers = {}
_guard = threading.Lock()


def watcher_for(inst):
    with _guard:
        w = _watchers.get(inst.id)
        if w is None:
            w = ErrorWatcher(inst.id, inst.slug, inst.name, inst.txdata_dir)
            threading.Thread(target=w.run, daemon=True, name=f"tx-errors-{inst.slug}").start()
            _watchers[inst.id] = w
        return w


def start_all(app):
    """Watch every instance; pick up new ones every 30s."""
    def loop():
        from models.tx_instance import TxInstance
        while True:
            try:
                with app.app_context():
                    for inst in TxInstance.query.all():
                        watcher_for(inst)
            except Exception as exc:  # noqa: BLE001
                app.logger.warning("error watcher loop: %s", exc)
            time.sleep(30)
    threading.Thread(target=loop, daemon=True, name="tx-errors-discover").start()
