"""Thin client for the Namecheap XML API (https://www.namecheap.com/support/api/intro/).

Two things make this meaningfully different from cloudflare_service.py:

1. It's XML, not JSON, and every response is wrapped in a default XML
   namespace — _parse() strips namespaces off every tag on the way in so
   the rest of this file can use plain tag names.

2. domains.dns.setHosts is a full replace, not a per-record PUT. Namecheap
   has no "update this one record" or "delete this one record" endpoint —
   you send the *entire* host list you want to exist, every time. So
   create/update/delete here all follow the same pattern: getHosts, mutate
   the in-memory list, setHosts the whole thing back. This is the actual
   Namecheap API shape, not a workaround.

Namecheap also requires the calling IP to be whitelisted on the account
(Profile → Tools → API Access) — ClientIp here must match a whitelisted
address or every call fails with an auth error, independent of whether
ApiUser/ApiKey are correct.
"""
import xml.etree.ElementTree as ET

import requests
from flask import current_app

API_BASE = "https://api.namecheap.com/xml.response"
TIMEOUT = 20

RECORD_TYPES = ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "URL", "URL301", "FRAME"]

# Namecheap has no concept of edge-proxying a record (that's a Cloudflare
# thing) — this stays empty so the shared template's Proxy column just
# renders "—" for every row with no special-casing needed.
PROXYABLE_TYPES = set()

DEFAULT_TTL = 1800
DEFAULT_MX_PREF = 10


class NamecheapError(Exception):
    pass


def _creds():
    cfg = current_app.config
    return {
        "ApiUser": cfg.get("NAMECHEAP_API_USER", ""),
        "ApiKey": cfg.get("NAMECHEAP_API_KEY", ""),
        "UserName": cfg.get("NAMECHEAP_USERNAME", "") or cfg.get("NAMECHEAP_API_USER", ""),
        "ClientIp": cfg.get("NAMECHEAP_CLIENT_IP", ""),
    }


def is_configured():
    c = _creds()
    return bool(c["ApiUser"] and c["ApiKey"] and c["ClientIp"])


def _strip_namespaces(elem):
    for e in elem.iter():
        if "}" in e.tag:
            e.tag = e.tag.split("}", 1)[1]
    return elem


def _request(command, override_creds=None, **params):
    creds = override_creds if override_creds is not None else _creds()
    if not (creds.get("ApiUser") and creds.get("ApiKey") and creds.get("ClientIp")):
        raise NamecheapError("Namecheap API credentials aren't fully configured yet (API user, key, and whitelisted client IP are all required).")

    query = {**creds, "Command": command, **params}
    try:
        resp = requests.get(API_BASE, params=query, timeout=TIMEOUT)
    except requests.RequestException as exc:
        raise NamecheapError(f"Couldn't reach Namecheap: {exc}") from exc

    try:
        root = _strip_namespaces(ET.fromstring(resp.text))
    except ET.ParseError as exc:
        raise NamecheapError(f"Namecheap returned an unreadable response (HTTP {resp.status_code}).") from exc

    if root.attrib.get("Status") != "OK":
        errors = root.find("Errors")
        if errors is not None and len(errors):
            messages = [e.text or e.attrib.get("Number", "unknown") for e in errors]
            raise NamecheapError("; ".join(messages))
        raise NamecheapError("Namecheap API request failed for an unknown reason.")

    return root.find("CommandResponse")


def verify_credentials(api_user, api_key, username, client_ip):
    """Cheapest real call that proves the credentials + whitelisted IP
    actually work: ask for the account's domain list."""
    override = {"ApiUser": api_user, "ApiKey": api_key, "UserName": username or api_user, "ClientIp": client_ip}
    _request("namecheap.domains.getList", override_creds=override, PageSize=1)
    return True


def list_domains():
    cr = _request("namecheap.domains.getList", PageSize=100, SortBy="NAME")
    result = cr.find("DomainGetListResult") if cr is not None else None
    domains = []
    if result is not None:
        for d in result.findall("Domain"):
            name = d.attrib.get("Name", "")
            expired = d.attrib.get("IsExpired", "false").lower() == "true"
            locked = d.attrib.get("IsLocked", "false").lower() == "true"
            status = "expired" if expired else ("locked" if locked else "active")
            domains.append({"id": name, "name": name, "status": status})
    return domains


def _split_domain(domain):
    if "." not in domain:
        raise NamecheapError(f"'{domain}' isn't a valid domain (no TLD).")
    sld, tld = domain.split(".", 1)
    return sld, tld


def get_hosts(domain):
    sld, tld = _split_domain(domain)
    cr = _request("namecheap.domains.dns.getHosts", SLD=sld, TLD=tld)
    result = cr.find("DomainDNSGetHostsResult") if cr is not None else None
    hosts = []
    if result is not None:
        for h in result.findall("host"):
            hosts.append({
                "id": h.attrib.get("HostId", ""),
                "type": h.attrib.get("Type", ""),
                "name": h.attrib.get("Name", ""),
                "content": h.attrib.get("Address", ""),
                "ttl": int(h.attrib.get("TTL", DEFAULT_TTL) or DEFAULT_TTL),
                "proxied": False,
                "priority": int(h.attrib["MXPref"]) if h.attrib.get("MXPref") else None,
            })
    hosts.sort(key=lambda r: (r["type"], r["name"]))
    return hosts


def _set_hosts(domain, hosts):
    """Push the full host list back to Namecheap. `hosts` is the
    normalized dict shape used throughout this module."""
    sld, tld = _split_domain(domain)
    params = {"SLD": sld, "TLD": tld}
    for i, h in enumerate(hosts, start=1):
        params[f"HostName{i}"] = h["name"] or "@"
        params[f"RecordType{i}"] = h["type"]
        params[f"Address{i}"] = h["content"]
        params[f"TTL{i}"] = str(h.get("ttl") or DEFAULT_TTL)
        if h["type"] == "MX":
            params[f"MXPref{i}"] = str(h.get("priority") or DEFAULT_MX_PREF)
    _request("namecheap.domains.dns.setHosts", **params)
    return True


def create_host(domain, record_type, name, content, ttl=DEFAULT_TTL, priority=None):
    hosts = get_hosts(domain)
    hosts.append({
        "type": record_type, "name": name, "content": content,
        "ttl": ttl or DEFAULT_TTL, "priority": priority,
    })
    _set_hosts(domain, hosts)
    return True


def update_host(domain, host_id, record_type, name, content, ttl=DEFAULT_TTL, priority=None):
    hosts = get_hosts(domain)
    found = False
    for h in hosts:
        if h["id"] == str(host_id):
            h.update({"type": record_type, "name": name, "content": content,
                       "ttl": ttl or DEFAULT_TTL, "priority": priority})
            found = True
            break
    if not found:
        raise NamecheapError("That record no longer exists on Namecheap's side — reload the page.")
    _set_hosts(domain, hosts)
    return True


def delete_host(domain, host_id):
    hosts = get_hosts(domain)
    remaining = [h for h in hosts if h["id"] != str(host_id)]
    if len(remaining) == len(hosts):
        raise NamecheapError("That record no longer exists on Namecheap's side — reload the page.")
    _set_hosts(domain, remaining)
    return True


def get_nameserver_mode(domain):
    sld, tld = _split_domain(domain)
    cr = _request("namecheap.domains.dns.getList", SLD=sld, TLD=tld)
    result = cr.find("DomainDNSGetListResult") if cr is not None else None
    if result is None:
        return {"using_provider_dns": True, "nameservers": []}
    using_own = result.attrib.get("IsUsingOurDNS", "true").lower() == "true"
    nameservers = [ns.text for ns in result.findall("Nameserver") if ns.text]
    return {"using_provider_dns": using_own, "nameservers": nameservers}


def set_default_dns(domain):
    sld, tld = _split_domain(domain)
    _request("namecheap.domains.dns.setDefault", SLD=sld, TLD=tld)
    return True


def set_custom_nameservers(domain, nameservers):
    sld, tld = _split_domain(domain)
    _request("namecheap.domains.dns.setCustom", SLD=sld, TLD=tld, Nameservers=",".join(nameservers))
    return True
