"""Client for a txAdmin instance's own web API, used by the panel's custom
txAdmin control panel (/tx/<id>/panel) and its REST API (/tx/api/v1/...).

txAdmin 8 has no public API; this speaks the same private HTTP + socket.io
protocol its web UI uses (routes from core/index.js of the bundled monitor
resource):

  * POST /auth/password {username,password} -> session cookie + csrfToken.
    Every later request sends the cookie and `x-txadmin-csrftoken`.
    Login is rate-limited, so sessions are cached per instance and only
    renewed when txAdmin answers {logout: true}.
  * socket.io with ?rooms=status,dashboard,liveconsole,playerlist pushes the
    live console, server status and online player list; console commands
    are the `consoleCommand` event of the liveconsole room.

The panel logs in as the instance's saved master account, so every action
shows up in txAdmin's own admin log under that name.
"""
import threading
import time

import requests
import socketio

HTTP_TIMEOUT = 10
CONSOLE_BUFFER_MAX = 512 * 1024
LINK_IDLE_SECONDS = 300          # drop the socket link when nobody has polled for a while
ROOMS = "status,dashboard,liveconsole,playerlist"


class TxApiError(Exception):
    pass


class TxClient:
    def __init__(self, inst_id, port, username, password):
        self.inst_id = inst_id
        self.base = f"http://127.0.0.1:{port}"
        self.username = username
        self.password = password
        self.session = requests.Session()
        self.csrf = None
        self.admin = None
        self.lock = threading.RLock()

        # live link state
        self.sio = None
        self.console = ""
        self.console_offset = 0       # absolute offset of console[0]
        self.players = {}             # netid -> player dict
        self.mutex = None
        self.status = None
        self.dashboard = None
        self.last_poll = 0
        self.link_error = None

    # ------------------------------------------------------------ http

    def login(self):
        with self.lock:
            if not self.username or not self.password:
                raise TxApiError("No saved txAdmin login for this server. Use 'Reset password' on the /tx page first.")
            self.session.cookies.clear()
            try:
                r = self.session.post(self.base + "/auth/password", timeout=HTTP_TIMEOUT,
                                      json={"username": self.username, "password": self.password})
            except requests.RequestException as exc:
                raise TxApiError(f"txAdmin isn't reachable on {self.base}: {exc}") from exc
            if r.status_code == 429:
                raise TxApiError("txAdmin is rate-limiting logins — wait a minute and try again.")
            data = _json(r)
            if data.get("error") or not data.get("csrfToken"):
                raise TxApiError(f"txAdmin login failed: {data.get('error') or 'no session returned'}. "
                                 f"Check the saved username/password on the /tx page.")
            self.csrf = data["csrfToken"]
            self.admin = {k: data.get(k) for k in ("name", "permissions", "isMaster", "isTempPassword")}
            return self.admin

    def call(self, method, path, params=None, body=None, _retry=True):
        with self.lock:
            if not self.csrf:
                self.login()
            try:
                r = self.session.request(method, self.base + path, params=params, json=body, timeout=HTTP_TIMEOUT,
                                         headers={"x-txadmin-csrftoken": self.csrf or ""})
            except requests.RequestException as exc:
                raise TxApiError(f"txAdmin request failed: {exc}") from exc
            data = _json(r)
            if isinstance(data, dict) and data.get("logout"):
                if not _retry:
                    raise TxApiError(f"txAdmin rejected the session: {data.get('reason')}")
                self.csrf = None
                self.stop_link()
                return self.call(method, path, params, body, _retry=False)
            return data

    def get(self, path, **params):
        return self.call("GET", path, params={k: v for k, v in params.items() if v is not None})

    def post(self, path, body=None, **params):
        return self.call("POST", path, params={k: v for k, v in params.items() if v is not None} or None, body=body or {})

    # ------------------------------------------------------------ live link

    def ensure_link(self):
        """Connect (or reconnect) the socket.io link. Cheap when already up."""
        self.last_poll = time.time()
        with self.lock:
            if self.sio is not None and self.sio.connected:
                return
            if not self.csrf:
                self.login()
            self.stop_link()
            sio = socketio.Client(reconnection=True, reconnection_attempts=3, logger=False, engineio_logger=False)

            @sio.on("consoleData")
            def _console(data):
                if isinstance(data, str):
                    self._append_console(data)

            @sio.on("playerlist")
            def _players(events):
                for ev in events if isinstance(events, list) else [events]:
                    self._apply_player_event(ev)

            @sio.on("status")
            def _status(data):
                self.status = data

            @sio.on("dashboard")
            def _dashboard(data):
                self.dashboard = data

            @sio.on("logout")
            def _logout(*_):
                self.csrf = None

            @sio.on("disconnect")
            def _disc(*_):
                self.link_error = "disconnected"

            # A fresh connection replays the recent console buffer; start clean
            # before connecting so that replay isn't thrown away.
            self.console, self.console_offset = "", self.console_offset + len(self.console)
            cookie = "; ".join(f"{c.name}={c.value}" for c in self.session.cookies)
            try:
                sio.connect(f"{self.base}?rooms={ROOMS}", headers={"Cookie": cookie},
                            transports=["polling"], socketio_path="socket.io", wait_timeout=10)
            except Exception as exc:  # noqa: BLE001 - socketio raises its own ConnectionError types
                self.link_error = str(exc)
                raise TxApiError(f"Couldn't open txAdmin's live connection: {exc}") from exc
            self.sio = sio
            self.link_error = None

    def stop_link(self):
        sio, self.sio = self.sio, None
        if sio is not None:
            try:
                sio.disconnect()
            except Exception:  # noqa: BLE001
                pass

    def _append_console(self, chunk):
        with self.lock:
            self.console += chunk
            overflow = len(self.console) - CONSOLE_BUFFER_MAX
            if overflow > 0:
                self.console = self.console[overflow:]
                self.console_offset += overflow

    def _apply_player_event(self, ev):
        if not isinstance(ev, dict):
            return
        if ev.get("mutex") and ev.get("mutex") != self.mutex and ev.get("type") != "fullPlayerlist":
            # player events from a previous server run — ignore
            pass
        t = ev.get("type")
        if t == "fullPlayerlist":
            self.mutex = ev.get("mutex")
            self.players = {p["netid"]: p for p in ev.get("playerlist") or [] if "netid" in p}
        elif t == "playerJoining" and "netid" in ev:
            self.players[ev["netid"]] = {k: ev.get(k) for k in ("netid", "displayName", "pureName", "license")}
        elif t == "playerDropped":
            self.players.pop(ev.get("netid"), None)

    def console_since(self, offset):
        with self.lock:
            end = self.console_offset + len(self.console)
            if offset is None or offset < self.console_offset or offset > end:
                return self.console, end, True     # reset: send whole buffer
            return self.console[offset - self.console_offset:], end, False

    def send_console(self, command):
        self.ensure_link()
        command = (command or "").replace("\n", " ").strip()
        if not command:
            raise TxApiError("Empty command.")
        self.sio.emit("consoleCommand", command)


# ---------------------------------------------------------------- registry

_clients = {}
_registry_lock = threading.Lock()


def client_for(inst):
    """One cached client per instance; rebuilt when the saved login or port changes."""
    with _registry_lock:
        c = _clients.get(inst.id)
        if c and (c.username, c.password, c.base) != (inst.tx_username, inst.tx_password, f"http://127.0.0.1:{inst.tx_port}"):
            c.stop_link()
            c = None
        if c is None:
            c = _clients[inst.id] = TxClient(inst.id, inst.tx_port, inst.tx_username, inst.tx_password)
        return c


def forget(inst_id):
    with _registry_lock:
        c = _clients.pop(inst_id, None)
    if c:
        c.stop_link()


def reap_idle_links():
    now = time.time()
    with _registry_lock:
        clients = list(_clients.values())
    for c in clients:
        if c.sio is not None and now - c.last_poll > LINK_IDLE_SECONDS:
            c.stop_link()


def _json(r):
    try:
        return r.json()
    except ValueError:
        if r.status_code in (401, 403):
            return {"logout": True, "reason": f"HTTP {r.status_code}"}
        raise TxApiError(f"txAdmin returned HTTP {r.status_code} (not JSON) for {r.request.method} {r.url.split('?')[0]}")


# ---------------------------------------------------------------- high level helpers

def overview(inst):
    c = client_for(inst)
    c.ensure_link()
    # give a brand-new link a moment to receive its initial room data
    for _ in range(10):
        if c.status is not None:
            break
        time.sleep(0.2)
    return {"admin": c.admin, "status": c.status, "dashboard": c.dashboard,
            "players": sorted(c.players.values(), key=lambda p: p.get("netid", 0)), "mutex": c.mutex,
            "link": "connected" if c.sio and c.sio.connected else (c.link_error or "down")}


def fxserver_info(inst):
    """FXServer's own /info.json on the game port (resources, vars, version)."""
    try:
        r = requests.get(f"http://127.0.0.1:{inst.game_port}/info.json", timeout=4)
        return r.json()
    except (requests.RequestException, ValueError):
        return None


def tx_result(data):
    """Normalise txAdmin's mixed response styles into (ok, message, data)."""
    if not isinstance(data, dict):
        return True, None, data
    if data.get("error"):
        return False, str(data["error"]), data
    if data.get("type") in ("error", "danger"):
        return False, _strip_html(data.get("msg") or "Error"), data
    return True, _strip_html(data.get("msg")) if data.get("msg") else None, data


def _strip_html(s):
    import re
    return re.sub(r"<[^>]+>", " ", s or "").replace("  ", " ").strip()
