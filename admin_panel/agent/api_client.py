"""
Thin wrapper around the Admin Panel's agent-facing /api/v1 (see the Admin
Panel's app/blueprints/agent_api.py). Deliberately dumb — no retry/backoff
logic here, that belongs in the calling loops (heartbeat.py, config_manager.py,
update_manager.py in later parts) so each loop can decide how to handle a
transient failure without this module guessing.
"""
import requests

DEFAULT_TIMEOUT = 15  # seconds


class ApiError(Exception):
    def __init__(self, status_code: int, payload: dict):
        self.status_code = status_code
        self.payload = payload
        super().__init__(f"API error {status_code}: {payload}")


class ApiClient:
    def __init__(self, admin_url: str, instance_id: str = None, instance_secret: str = None,
                 timeout: int = DEFAULT_TIMEOUT):
        self.admin_url = admin_url.rstrip("/")
        self.instance_id = instance_id
        self.instance_secret = instance_secret
        self.timeout = timeout

    def _headers(self) -> dict:
        if not (self.instance_id and self.instance_secret):
            return {}
        return {"Authorization": f"Bearer {self.instance_id}.{self.instance_secret}"}

    def _request(self, method: str, path: str, **kwargs):
        url = f"{self.admin_url}{path}"
        kwargs.setdefault("timeout", self.timeout)
        kwargs.setdefault("headers", {}).update(self._headers())
        resp = requests.request(method, url, **kwargs)
        try:
            payload = resp.json()
        except ValueError:
            payload = {"raw": resp.text}
        if resp.status_code >= 400:
            raise ApiError(resp.status_code, payload)
        return payload

    # --- registration (no instance credentials yet) ---
    def register(self, registration_token: str, hostname: str, os_name: str,
                 os_version: str = None, agent_version: str = None, app_version: str = None) -> dict:
        return self._request("POST", "/api/v1/instances/register", json={
            "registration_token": registration_token,
            "hostname": hostname,
            "os": os_name,
            "os_version": os_version,
            "agent_version": agent_version,
            "app_version": app_version,
        })

    # --- authenticated instance calls ---
    def heartbeat(self, **fields) -> dict:
        return self._request("POST", "/api/v1/instances/heartbeat", json=fields)

    def me(self) -> dict:
        return self._request("GET", "/api/v1/instances/me")

    def get_config(self, wait_seconds: float = 0) -> dict:
        """wait_seconds > 0 long-polls: mirrors get_pending_command below —
        the server holds the connection open for up to that long waiting
        for a newly pushed config instead of returning "nothing pending"
        immediately. Request timeout set explicitly longer than
        wait_seconds so it doesn't fire before the server-side long-poll
        gets a chance to respond."""
        params = {"wait": wait_seconds} if wait_seconds else None
        request_timeout = max(self.timeout, wait_seconds + 10) if wait_seconds else self.timeout
        return self._request("GET", "/api/v1/instances/config", params=params, timeout=request_timeout)

    def ack_config(self, version: int, status: str, message: str = None) -> dict:
        return self._request("POST", "/api/v1/instances/config/ack", json={
            "version": version, "status": status, "message": message,
        })

    def get_current_update(self) -> dict:
        return self._request("GET", "/api/v1/instances/updates/current")

    def download_update(self, download_url: str, dest_path: str) -> None:
        url = f"{self.admin_url}{download_url}"
        with requests.get(url, headers=self._headers(), stream=True, timeout=120) as resp:
            if resp.status_code >= 400:
                try:
                    payload = resp.json()
                except ValueError:
                    payload = {"raw": resp.text}
                raise ApiError(resp.status_code, payload)
            with open(dest_path, "wb") as f:
                for chunk in resp.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        f.write(chunk)

    def report_update_status(self, deployment_id: str, status: str, message: str = None,
                              health_check_passed: bool = None) -> dict:
        body = {"status": status, "message": message}
        if health_check_passed is not None:
            body["health_check_passed"] = health_check_passed
        return self._request(
            "POST", f"/api/v1/instances/updates/{deployment_id}/status", json=body
        )

    # --- remote start/stop/restart commands ---
    def get_pending_command(self, wait_seconds: float = 0) -> dict:
        """wait_seconds > 0 long-polls: the server holds the connection
        open for up to that long waiting for a command instead of
        returning "nothing pending" immediately. The request's own HTTP
        timeout is set explicitly here, longer than wait_seconds — the
        default DEFAULT_TIMEOUT (15s) would otherwise fire and raise
        before a real long-poll (up to 25s server-side) ever got a chance
        to respond."""
        params = {"wait": wait_seconds} if wait_seconds else None
        request_timeout = max(self.timeout, wait_seconds + 10) if wait_seconds else self.timeout
        return self._request("GET", "/api/v1/instances/commands", params=params, timeout=request_timeout)

    def start_command(self, command_id: str) -> dict:
        """Tells the Admin Panel 'I've picked this up and am about to run
        it' — called right after get_pending_command returns a command,
        before actually executing it. Best-effort: callers should not let
        a failure here block running the command itself, since this only
        feeds the Admin Panel's status display, not command execution."""
        return self._request("POST", f"/api/v1/instances/commands/{command_id}/start")

    def ack_command(self, command_id: str, status: str, message: str = None) -> dict:
        return self._request(
            "POST", f"/api/v1/instances/commands/{command_id}/ack",
            json={"status": status, "message": message},
        )

    # --- Kiosk App inventory sync (see agent/inventory_sync.py) ---
    def get_equipment_sync(self) -> dict:
        return self._request("GET", "/api/v1/instances/equipment/sync")

    def push_equipment_sync(self, items: list, tools: list) -> dict:
        return self._request("POST", "/api/v1/instances/equipment/sync", json={"items": items, "tools": tools})

    def get_local_users_sync(self) -> dict:
        return self._request("GET", "/api/v1/instances/local-users/sync")

    def push_local_users_sync(self, local_users: list) -> dict:
        return self._request("POST", "/api/v1/instances/local-users/sync", json={"local_users": local_users})

    def push_roles_sync(self, roles: list) -> dict:
        return self._request("POST", "/api/v1/instances/roles/sync", json={"roles": roles})

    # --- Track 2 Phase B: generic inventory type system sync (see
    # /root/.claude/plans/sprightly-meandering-whisper.md) ---
    def get_item_types_sync(self) -> dict:
        return self._request("GET", "/api/v1/instances/item-types/sync")

    def push_item_types_sync(self, item_types: list) -> dict:
        return self._request("POST", "/api/v1/instances/item-types/sync", json={"item_types": item_types})

    def get_inventory_items_sync(self) -> dict:
        return self._request("GET", "/api/v1/instances/inventory-items/sync")

    def push_inventory_items_sync(self, inventory_items: list) -> dict:
        return self._request(
            "POST", "/api/v1/instances/inventory-items/sync", json={"inventory_items": inventory_items}
        )

    def push_nav_entries_sync(self, nav_entries: list) -> dict:
        return self._request("POST", "/api/v1/instances/nav-entries/sync", json={"nav_entries": nav_entries})

    # --- backups (see agent/backup_sync.py) ---
    def upload_backup(self, filename: str, file_bytes: bytes, source: str) -> dict:
        return self._request(
            "POST", "/api/v1/instances/backup/upload",
            files={"file": (filename, file_bytes)}, data={"source": source},
            timeout=max(self.timeout, 60),  # a real backup file can be a lot bigger than a normal JSON call
        )
