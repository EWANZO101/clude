"""Networking for txAdmin servers: firewall ports and join domains.

Ports: full admins (firewall.manage) get ports opened directly; everyone
else files a TxPortRequest that an admin approves from /tx.

Join domains: managed subdomains are A records in the panel's DNS provider
(the one configured on the DNS page — Cloudflare for opslabsystems.cloud),
always DNS-only because FiveM's game traffic is UDP and can't go through a
proxy. Custom domains are the user's own hostname CNAME'd (or A'd) at us;
we only verify they resolve to this server.
"""
import os
import re
import socket
import subprocess
import time

from flask import current_app

from services import txadmin_service as txsvc

JOIN_ZONE = os.environ.get("TX_JOIN_ZONE", "opslabsystems.cloud")
SHARED_TARGET_LABEL = os.environ.get("TX_JOIN_TARGET_LABEL", "join")

LABEL_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$")
HOST_RE = re.compile(r"^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
RESERVED_LABELS = {
    "www", "mail", "smtp", "imap", "pop", "ftp", "ns", "ns1", "ns2", "mx", "api", "admin", "panel", "serverpanel",
    "dashboard", "cdn", "static", "status", "join", "play", "app", "auth", "login", "vpn", "ssh", "git", "dev", "staging",
}

# Ports nobody gets to request: SSH, web, mail, databases, the panel itself.
RESERVED_PORTS = {21, 22, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995, 3306, 5432, 6379, 9500, 33060}
PORT_MIN, PORT_MAX = 1024, 65535


class NetError(Exception):
    pass


def is_full_admin(user):
    return bool(user and user.is_authenticated and user.has_permission("firewall.manage"))


# ---------------------------------------------------------------- ports

def validate_custom_ports(tx_port, game_port, taken_tx, taken_game, ignore_listening=()):
    try:
        tx_port, game_port = int(tx_port), int(game_port)
    except (TypeError, ValueError):
        raise NetError("Ports must be numbers.")
    for label, p in (("txAdmin port", tx_port), ("Game port", game_port)):
        if not PORT_MIN <= p <= PORT_MAX:
            raise NetError(f"{label} must be between {PORT_MIN} and {PORT_MAX}.")
        if p in RESERVED_PORTS:
            raise NetError(f"{label} {p} is reserved for system services.")
    if tx_port == game_port:
        raise NetError("txAdmin and game ports must be different.")
    if tx_port == 30120:
        raise NetError("txAdmin can't use 30120 (txAdmin refuses it to avoid confusion with the game port).")
    if game_port == 40120 and 40120 in taken_tx:
        raise NetError("Game port 40120 is used by another txAdmin.")
    listening = txsvc._listening_ports() - set(ignore_listening)
    for label, p in (("txAdmin port", tx_port), ("Game port", game_port)):
        if p in listening or p in taken_tx or p in taken_game:
            raise NetError(f"{label} {p} is already in use on this server.")
    return tx_port, game_port


_ufw_cache = {"at": 0, "text": ""}


def _ufw_status():
    if time.time() - _ufw_cache["at"] < 5:
        return _ufw_cache["text"]
    try:
        r = subprocess.run(["ufw", "status"], capture_output=True, text=True, timeout=10)
        text = r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        text = ""
    _ufw_cache.update(at=time.time(), text=text)
    return text


def firewall_active():
    return "Status: active" in _ufw_status()


def port_state(inst):
    """Which of the instance's ports are allowed from anywhere in ufw."""
    text = _ufw_status()
    if "Status: active" not in text:
        return {"firewall": "inactive", "open": True, "missing": []}
    lines = [l for l in text.splitlines() if "ALLOW" in l and "(v6)" not in l]

    def allowed(port, proto):
        pat = re.compile(rf"^{port}(/{proto})?\s+ALLOW\s+(IN\s+)?Anywhere\b")
        return any(pat.match(l.strip()) for l in lines)

    needed = [(inst.tx_port, "tcp"), (inst.game_port, "tcp"), (inst.game_port, "udp")]
    missing = [f"{p}/{proto}" for p, proto in needed if not allowed(p, proto)]
    return {"firewall": "active", "open": not missing, "missing": missing}


def open_ports(inst):
    from services import firewall_service as fw
    if not fw.is_installed():
        return []
    opened = []
    for port, proto, label in ((inst.tx_port, "tcp", "txadmin"), (inst.game_port, "tcp", "fivem"), (inst.game_port, "udp", "fivem")):
        fw.open_port(port, proto, f"{label} {inst.slug}")
        opened.append(f"{port}/{proto}")
    _ufw_cache["at"] = 0
    return opened


# ---------------------------------------------------------------- DNS

def _provider():
    from services.dns_providers.registry import get_provider, DEFAULT_PROVIDER
    key = current_app.config.get("DNS_PROVIDER") or os.environ.get("DNS_PROVIDER") or DEFAULT_PROVIDER
    p = get_provider(key)
    if not p or not p.is_configured():
        raise NetError("No DNS provider is configured. Set one up on the DNS page first.")
    return p


def _zone():
    p = _provider()
    try:
        zones = p.list_domains()
    except Exception as exc:  # noqa: BLE001 - provider errors vary
        raise NetError(f"DNS provider error: {exc}") from exc
    z = next((z for z in zones if z["name"].lower() == JOIN_ZONE.lower()), None)
    if not z:
        raise NetError(f"The DNS provider can't manage {JOIN_ZONE}.")
    return p, z["id"]


def zone_info():
    try:
        _zone()
        return {"zone": JOIN_ZONE, "available": True, "shared_target": f"{SHARED_TARGET_LABEL}.{JOIN_ZONE}"}
    except NetError as exc:
        return {"zone": JOIN_ZONE, "available": False, "error": str(exc)}


def _records_named(p, zone_id, fqdn):
    fqdn = fqdn.lower().rstrip(".")
    return [r for r in p.list_records(zone_id) if r["name"].lower().rstrip(".") == fqdn]


def create_managed(label):
    label = (label or "").strip().lower()
    if not LABEL_RE.match(label):
        raise NetError("Use 1–40 lowercase letters, numbers or hyphens (not starting or ending with a hyphen).")
    if label in RESERVED_LABELS:
        raise NetError(f"'{label}' is reserved — pick another name.")
    fqdn = f"{label}.{JOIN_ZONE}"
    p, zone_id = _zone()
    if _records_named(p, zone_id, fqdn):
        raise NetError(f"{fqdn} is already taken.")
    try:
        rec = p.create_record(zone_id, "A", fqdn, txsvc.public_ip(), ttl=1, proxied=False)
    except Exception as exc:  # noqa: BLE001
        raise NetError(f"Couldn't create the DNS record: {exc}") from exc
    rec_id = rec.get("id") if isinstance(rec, dict) else None
    return fqdn, zone_id, rec_id


def delete_managed(zone_id, record_id, hostname):
    p = _provider()
    try:
        if record_id:
            p.delete_record(zone_id, record_id)
        else:
            for r in _records_named(p, zone_id, hostname):
                if r["type"] == "A":
                    p.delete_record(zone_id, r["id"])
    except Exception as exc:  # noqa: BLE001
        raise NetError(f"Couldn't delete the DNS record: {exc}") from exc


def ensure_shared_target():
    """join.<zone> — the generic CNAME target for custom domains of servers
    that don't have a managed subdomain. Created on first use."""
    fqdn = f"{SHARED_TARGET_LABEL}.{JOIN_ZONE}"
    p, zone_id = _zone()
    ip = txsvc.public_ip()
    recs = _records_named(p, zone_id, fqdn)
    if not recs:
        p.create_record(zone_id, "A", fqdn, ip, ttl=1, proxied=False)
    elif not any(r["type"] == "A" and r["content"] == ip for r in recs):
        raise NetError(f"{fqdn} already exists and doesn't point at this server — set TX_JOIN_TARGET_LABEL to another name.")
    return fqdn


def normalize_custom(hostname):
    h = (hostname or "").strip().lower().rstrip(".")
    h = re.sub(r"^[a-z]+://", "", h).split("/")[0].split(":")[0]
    if not HOST_RE.match(h):
        raise NetError("Enter a hostname like play.myserver.com.")
    if h == JOIN_ZONE or h.endswith("." + JOIN_ZONE):
        raise NetError(f"For {JOIN_ZONE} names, use “Free subdomain” instead.")
    return h


def resolve(hostname):
    try:
        infos = socket.getaddrinfo(hostname, None, socket.AF_INET)
        return sorted({i[4][0] for i in infos})
    except socket.gaierror:
        return []


def check(hostname):
    """-> (status, detail)"""
    ips = resolve(hostname)
    ip = txsvc.public_ip()
    if not ips:
        return "pending", "Not resolving yet. DNS changes can take a few minutes to spread."
    if ip in ips:
        return "active", f"Resolves to {ip}"
    return "error", f"Resolves to {', '.join(ips)}, not this server ({ip}). If you use Cloudflare, make sure the record is DNS only (grey cloud)."
