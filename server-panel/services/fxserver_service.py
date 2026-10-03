"""Talks to FXServer over its two stable, official interfaces:

  1. The built-in HTTP endpoint (/players.json, /dynamic.json, /info.json)
     that every FXServer exposes on its game port — used for read-only
     status (player list, count, resources, server metadata).
  2. RCON over UDP (rcon_password in server.cfg) — used to issue console
     commands (kick, say, resource start/stop, custom commands).

Neither of these touches txAdmin's private/undocumented UI API, so both
keep working regardless of which txAdmin version (if any) is in front of
the server.
"""

import random
import socket

import requests

HTTP_TIMEOUT = 4
RCON_TIMEOUT = 3


class FXServerError(Exception):
    """Raised for any HTTP or RCON failure talking to an FXServer instance."""


# ---------------------------------------------------------------------------
# HTTP status endpoints
# ---------------------------------------------------------------------------

def _get_json(base_url, path):
    url = f"{base_url}/{path}"
    try:
        resp = requests.get(url, timeout=HTTP_TIMEOUT)
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.ConnectionError as exc:
        raise FXServerError(
            f"Couldn't reach {url} — server may be down, or the HTTP port/host is wrong."
        ) from exc
    except requests.exceptions.Timeout as exc:
        raise FXServerError(f"Timed out reaching {url}.") from exc
    except requests.exceptions.HTTPError as exc:
        raise FXServerError(f"{url} returned {resp.status_code}.") from exc
    except ValueError as exc:
        raise FXServerError(f"{url} didn't return valid JSON.") from exc


def get_players(server):
    """Raw list from /players.json: id, name, ping, identifiers, etc."""
    return _get_json(server.base_url(), "players.json")


def get_dynamic(server):
    """/dynamic.json: hostname, gametype, mapname, clients, sv_maxclients, ..."""
    return _get_json(server.base_url(), "dynamic.json")


def get_info(server):
    """/info.json: server version, resources list, vars, icon, etc."""
    return _get_json(server.base_url(), "info.json")


def get_status_snapshot(server):
    """Combined, best-effort snapshot for the detail page / poller.
    Each section fails independently so one bad endpoint doesn't blank
    the whole card."""
    snapshot = {"online": False, "error": None, "dynamic": None, "players": None, "resources": None}
    try:
        snapshot["dynamic"] = get_dynamic(server)
        snapshot["online"] = True
    except FXServerError as exc:
        snapshot["error"] = str(exc)
        return snapshot

    try:
        snapshot["players"] = get_players(server)
    except FXServerError as exc:
        snapshot["error"] = str(exc)

    try:
        info = get_info(server)
        snapshot["resources"] = info.get("resources") if isinstance(info, dict) else None
    except FXServerError:
        pass  # non-critical — resource list is a nice-to-have

    return snapshot


# ---------------------------------------------------------------------------
# RCON (UDP) — FXServer's RCON is a GoldSrc/Quake3-style UDP protocol, not
# the TCP "Source RCON Protocol". Request/response are both prefixed with
# 0xFFFFFFFF and plain text:
#   request:  \xff\xff\xff\xff rcon <password> <command>
#   response: \xff\xff\xff\xff print\n<output>
# There's no auth handshake — every request carries the password, and a
# wrong password gets no reply at all (which is why we time out on it).
# ---------------------------------------------------------------------------

_PACKET_PREFIX = b"\xff\xff\xff\xff"


def send_rcon_command(host, port, password, command, timeout=RCON_TIMEOUT):
    if not password:
        raise FXServerError("No RCON password configured for this server.")

    request_id = random.randint(0, 99999)
    payload = _PACKET_PREFIX + f'rcon {request_id} "{password}" {command}'.encode("utf-8", "replace")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(payload, (host, port))
        try:
            data, _ = sock.recvfrom(8192)
        except socket.timeout as exc:
            raise FXServerError(
                "No response from RCON — wrong password, RCON disabled "
                "(rcon_password unset), or the port/host is wrong."
            ) from exc
    except socket.gaierror as exc:
        raise FXServerError(f"Can't resolve host {host}.") from exc
    finally:
        sock.close()

    text = data[len(_PACKET_PREFIX):] if data.startswith(_PACKET_PREFIX) else data
    text = text.decode("utf-8", "replace")
    if text.startswith("print\n"):
        text = text[len("print\n"):]
    return text.rstrip("\n")


def test_rcon(server):
    """Round-trips a harmless command to confirm host/port/password all work."""
    return send_rcon_command(
        server.effective_rcon_host(), server.effective_rcon_port(),
        server.rcon_password, "echo panel-rcon-test",
    )
