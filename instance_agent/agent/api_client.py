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

    def get_config(self) -> dict:
        return self._request("GET", "/api/v1/instances/config")

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

    # --- error reporting (Part 6) ---
    def report_error(self, level: str, logger_name: str, message: str,
                      traceback: str = None, suppressed_since_last: int = 0) -> dict:
        """Ships one error/critical log event to the Admin Panel (spec
        Section 2.2's error reporting line item). Endpoint is new in Part 6
        — see PROGRESS.txt for the same "not verified against a real Admin
        Panel" caveat already flagged for Part 4's rolling_back/rolled_back
        statuses, for the same reason (no Admin Panel checkout available in
        this build environment)."""
        return self._request("POST", "/api/v1/instances/errors", json={
            "level": level,
            "logger": logger_name,
            "message": message,
            "traceback": traceback,
            "suppressed_since_last": suppressed_since_last,
        })

    # --- remote tunnel (Part 6, stub — see agent/tunnel.py) ---
    def get_tunnel_request(self) -> dict:
        """Polls whether an operator has requested remote access to this
        instance. New in Part 6, same unverified-against-a-real-Admin-Panel
        caveat as report_error() above."""
        return self._request("GET", "/api/v1/instances/tunnel")

    def report_tunnel_status(self, tunnel_id: str, status: str, message: str = None) -> dict:
        return self._request("POST", f"/api/v1/instances/tunnel/{tunnel_id}/status", json={
            "status": status, "message": message,
        })
