"""Thin client for the GoDaddy Domains v3 REST API
(https://developer.godaddy.com/en/docs/references/rest/domains/v3).

Bearer-token auth (a Personal Access Token from the GoDaddy developer
dashboard) — same shape as cloudflare_service.py: every function here
takes the token explicitly as its first argument rather than reading
one out of app config.

Two things make this meaningfully different from the other two provider
services in this codebase:

1. v3 has no "list every domain I own" endpoint — that operation is
   still v1-only (see the API's own "what v3 does not cover" table).
   So this panel can't populate a zone dropdown for GoDaddy the way it
   does for Cloudflare and Namecheap. Instead the domain is entered
   once, alongside the token, when GoDaddy is connected (see
   godaddy_provider.py / GoDaddyCredentialsForm), and get_domain() is
   used to confirm it's real and owned by this account before it's
   saved. list_domains() below just re-confirms that one saved domain
   afterward, so the panel's zone picker always renders (a dropdown of
   exactly one item is expected here, not a bug).

2. v3 has no per-record update endpoint — only list, create, and delete
   (https://developer.godaddy.com/en/docs/references/rest/domains/v3/records).
   update_dns_record() below is delete-then-create composed from those
   two primitives, same spirit as namecheap_service's getHosts/setHosts
   dance, just a two-call version instead of a full-zone replace. If
   the create half fails after the delete half succeeds, the record is
   gone rather than reverted — a failed update should be treated as
   "go check the zone", not "the original record is still there".
"""
import requests

API_BASE = "https://api.godaddy.com/v3/domains"
TIMEOUT = 15

# Record types the panel's Add/Edit form exposes. GoDaddy also supports
# structured types like SRV and CAA that use fields (service/port/
# weight/protocol, or flag/tag) this form doesn't collect — deliberately
# left out here rather than half-supporting them with a form that can't
# represent their real shape. GoDaddy-managed SOA and NS records are
# read-only at the zone apex (the API returns 409 dns_record_not_mutable
# on any attempt to touch them), so those are left out too. Those can
# still be managed directly in the GoDaddy dashboard.
RECORD_TYPES = ["A", "AAAA", "CNAME", "TXT", "MX", "ALIAS"]

# GoDaddy has no concept of edge-proxying a record (that's a Cloudflare
# thing) — this stays empty so the shared template's Proxy column just
# renders "—" for every row, same as Namecheap.
PROXYABLE_TYPES = set()

# The API rejects any ttl below this; there's no "Auto" TTL concept like
# Cloudflare's 1. DEFAULT_TTL is used whenever the panel's shared record
# form submits its own default of 1.
MIN_TTL = 600
DEFAULT_TTL = 3600


class GoDaddyError(Exception):
    pass


def _headers(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _request(method, path, token, **kwargs):
    if not token:
        raise GoDaddyError("No GoDaddy API token provided for this request.")
    try:
        resp = requests.request(method, f"{API_BASE}{path}", headers=_headers(token), timeout=TIMEOUT, **kwargs)
    except requests.RequestException as exc:
        raise GoDaddyError(f"Couldn't reach GoDaddy: {exc}") from exc

    if resp.status_code == 401:
        raise GoDaddyError("GoDaddy rejected this token (401 Unauthorized). Generate a new Personal Access Token from the GoDaddy developer dashboard.")
    if resp.status_code == 403:
        raise GoDaddyError("This token doesn't have permission for that operation (403 Forbidden).")
    if resp.status_code == 404:
        raise GoDaddyError("GoDaddy returned 404 — check the domain name is correct and owned by this account.")
    if resp.status_code == 409:
        raise GoDaddyError("GoDaddy rejected this change as a conflict (409) — this is often a GoDaddy-managed system record (SOA/NS) that can't be edited here.")
    if not resp.ok:
        try:
            body = resp.json()
            message = body.get("message") or body.get("name") or resp.text
        except ValueError:
            message = resp.text
        raise GoDaddyError(f"GoDaddy API error ({resp.status_code}): {message}")

    if resp.status_code == 204 or not resp.content:
        return None
    try:
        return resp.json()
    except ValueError:
        return None


def _clamp_ttl(ttl):
    """The shared record-form default (1, meaning "Auto" on Cloudflare/
    Namecheap) is below GoDaddy's minimum — fall back to a sane default
    instead of letting the API 400 on it."""
    if not ttl or ttl < MIN_TTL:
        return DEFAULT_TTL
    return ttl


def verify_token(token, domain=None):
    """Cheapest real call that proves the token authenticates: check
    availability of a domain. This doesn't require the token to own
    anything — check-availability works for any domain name, so it's a
    clean way to confirm the token itself is valid before also checking
    ownership of the specific domain the user entered."""
    probe = domain or "example.com"
    _request("GET", "/check-availability", token, params={"domain": probe})
    return True


def get_domain(token, domain):
    """Confirms `domain` is real and owned by this account, and returns
    its status. Used both to validate the domain entered at connect
    time and to populate list_domains()'s single-entry result."""
    data = _request("GET", f"/domain-names/{domain}", token)
    name = (data or {}).get("domain", domain)
    status = ((data or {}).get("status") or "unknown").lower()
    return {"id": name, "name": name, "status": status}


def list_domains(token, domain):
    """v3 has no bulk domain list — this just re-confirms the one saved
    domain still resolves, so the panel's zone dropdown (a dropdown of
    one) behaves the same shape as every other provider's."""
    if not domain:
        return []
    try:
        return [get_domain(token, domain)]
    except GoDaddyError:
        return []


def list_dns_records(token, zone):
    """Pages through every record in the zone — v3 caps pageSize at 100,
    so a zone with more records than that needs more than one call."""
    records = []
    page = 1
    while True:
        data = _request("GET", f"/zones/{zone}/dns-records", token, params={"page": page, "pageSize": 100}) or {}
        items = data.get("items", [])
        for item in items:
            records.append({
                "id": item.get("recordId"),
                "type": item.get("type"),
                "name": item.get("name"),
                "content": item.get("data"),
                "ttl": item.get("ttl"),
                "proxied": False,
                "priority": item.get("priority"),
            })
        if len(items) < 100:
            break
        page += 1
    records.sort(key=lambda r: (r["type"], r["name"]))
    return records


def _record_body(record_type, name, content, ttl, priority):
    body = {"name": name or "@", "type": record_type, "data": content, "ttl": _clamp_ttl(ttl)}
    if record_type == "MX" and priority is not None:
        body["priority"] = priority
    return body


def create_dns_record(token, zone, record_type, name, content, ttl=1, proxied=False, priority=None):
    # proxied is accepted for signature parity with the other providers'
    # create_record calls — GoDaddy has nothing corresponding to it.
    body = _record_body(record_type, name, content, ttl, priority)
    return _request("POST", f"/zones/{zone}/dns-records", token, json=body)


def delete_dns_record(token, zone, record_id):
    return _request("DELETE", f"/zones/{zone}/dns-records/{record_id}", token)


def update_dns_record(token, zone, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
    """v3 has no PUT/PATCH for a single record (see module docstring) —
    delete the old one, then create its replacement."""
    delete_dns_record(token, zone, record_id)
    return create_dns_record(token, zone, record_type, name, content, ttl=ttl, proxied=proxied, priority=priority)

