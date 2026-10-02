"""
api_client.py — every single thing the admin website does that touches
data goes through here. There is no database connection anywhere else in
this codebase; this module is the entire boundary to stocktool-api.
"""
import requests
from flask import current_app, session


class APIError(Exception):
    """Raised for any non-2xx response from the API. `.message` is the
    API's own error string when it provided one, so callers can flash()
    it straight through to the person using the admin site."""
    def __init__(self, message: str, status_code: int = 500):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


def _base_url() -> str:
    return current_app.config["API_BASE_URL"].rstrip("/")


def _headers() -> dict:
    headers = {"Content-Type": "application/json"}
    token = session.get("api_token")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def _request(method: str, path: str, **kwargs):
    url = f"{_base_url()}{path}"
    try:
        resp = requests.request(method, url, headers=_headers(), timeout=10, **kwargs)
    except requests.exceptions.RequestException as e:
        raise APIError(f"Could not reach StockTool API at {_base_url()}: {e}", 502)

    if resp.status_code >= 400:
        try:
            payload = resp.json()
            message = payload.get("error") or payload.get("message") or resp.text
        except ValueError:
            message = resp.text or f"API request failed ({resp.status_code})"
        raise APIError(message, resp.status_code)

    if resp.status_code == 204 or not resp.content:
        return None
    try:
        return resp.json()
    except ValueError:
        return resp.content


def api_get(path: str, params: dict = None):
    return _request("GET", path, params=params or {})


def api_post(path: str, json: dict = None):
    return _request("POST", path, json=json or {})


def api_put(path: str, json: dict = None):
    return _request("PUT", path, json=json or {})


def api_delete(path: str, json: dict = None):
    return _request("DELETE", path, json=json or {})
