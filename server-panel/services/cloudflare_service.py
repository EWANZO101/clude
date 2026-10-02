"""Thin wrapper around the Cloudflare v4 REST API for managing DNS
records. Plain authenticated HTTPS calls via `requests` — no Cloudflare
SDK dependency.

Every function here takes the API token explicitly as its first argument
rather than reading one global token out of app config. That's what makes
multi-account support possible: the panel can hold several saved
Cloudflare accounts (config.get_cloudflare_connections()), each with its
own token, and this module doesn't need to know or care how many there
are — it just talks to whichever token it's handed for that call.
"""
import requests

API_BASE = "https://api.cloudflare.com/client/v4"
TIMEOUT = 15

# Record types the panel's Add/Edit form exposes. Cloudflare also supports
# structured types like SRV/CAA/DS that use a nested "data" object instead
# of a flat "content" string — deliberately left out here rather than
# half-supporting them with a form that can't represent their real shape.
# Those can still be managed directly in the Cloudflare dashboard.
RECORD_TYPES = ["A", "AAAA", "CNAME", "TXT", "MX", "NS"]

# Record types Cloudflare allows to be proxied through its edge network
# (the "orange cloud"). Everything else must stay DNS-only.
PROXYABLE_TYPES = {"A", "AAAA", "CNAME"}


class CloudflareError(Exception):
    pass


def _request(method, path, token, **kwargs):
    if not token:
        raise CloudflareError("No Cloudflare API token provided for this request.")

    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    try:
        resp = requests.request(method, f"{API_BASE}{path}", headers=headers, timeout=TIMEOUT, **kwargs)
    except requests.RequestException as exc:
        raise CloudflareError(f"Couldn't reach Cloudflare: {exc}") from exc

    try:
        payload = resp.json()
    except ValueError:
        raise CloudflareError(f"Cloudflare returned an unexpected response (HTTP {resp.status_code}).")

    if not payload.get("success"):
        messages = [e.get("message", "Unknown error") for e in payload.get("errors", [])]
        raise CloudflareError("; ".join(messages) or f"Cloudflare API error (HTTP {resp.status_code}).")

    return payload.get("result")


def verify_token(token):
    """Validates a token before it's saved as a new connection, so a
    typo'd/scoped-wrong token never gets written to disk."""
    _request("GET", "/user/tokens/verify", token)
    return True


def list_zones(token):
    result = _request("GET", "/zones?per_page=50", token)
    return [{"id": z["id"], "name": z["name"], "status": z.get("status", "unknown")} for z in result]


def list_dns_records(token, zone_id):
    result = _request("GET", f"/zones/{zone_id}/dns_records?per_page=100", token)
    records = [
        {
            "id": r["id"],
            "type": r["type"],
            "name": r["name"],
            "content": r["content"],
            "ttl": r["ttl"],
            "proxied": r.get("proxied", False),
            "priority": r.get("priority"),
        }
        for r in result
    ]
    records.sort(key=lambda r: (r["type"], r["name"]))
    return records


def _record_body(record_type, name, content, ttl, proxied, priority):
    body = {"type": record_type, "name": name, "content": content, "ttl": int(ttl or 1)}
    if record_type in PROXYABLE_TYPES:
        body["proxied"] = bool(proxied)
    if record_type == "MX" and priority not in (None, ""):
        body["priority"] = int(priority)
    return body


def create_dns_record(token, zone_id, record_type, name, content, ttl=1, proxied=False, priority=None):
    body = _record_body(record_type, name, content, ttl, proxied, priority)
    return _request("POST", f"/zones/{zone_id}/dns_records", token, json=body)


def update_dns_record(token, zone_id, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
    body = _record_body(record_type, name, content, ttl, proxied, priority)
    return _request("PUT", f"/zones/{zone_id}/dns_records/{record_id}", token, json=body)


def delete_dns_record(token, zone_id, record_id):
    _request("DELETE", f"/zones/{zone_id}/dns_records/{record_id}", token)
    return True

