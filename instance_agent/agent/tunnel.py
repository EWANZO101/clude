"""
Remote tunnel client (spec Section 2.2's "Remote access tunnel" line item)
— a STUB, exactly as scoped in the 6-part build plan, not a full
implementation. What's real: the poll loop and status-reporting plumbing,
tested the same way every other loop in this project is (a fake client,
real threading, real stop_event semantics). What's stubbed: actually
opening a tunnel.

WHY THIS STAYS A STUB, HONESTLY: a working remote-access tunnel needs a
tunnel *broker* on the Admin Panel side (something to terminate the
reverse connection and hand an operator a way to reach it — e.g. a
WebSocket relay or a reverse SSH endpoint with per-instance host keys) that
doesn't exist in the Admin Panel project. Building a real tunnel client
against a broker that isn't there would mean guessing a protocol, which is
worse than not building it — it would look done without being connectable
to anything. This module instead builds everything that doesn't depend on
that missing piece (detecting a request, reporting outcome) and stops
cleanly at the one part that does, reporting 'unsupported' rather than
silently doing nothing or pretending to succeed.

When a real broker exists, the only thing that needs to change is
`_establish_tunnel()` below — the poll loop, rate limiting, and status
reporting around it are already real.
"""
import logging
import time

from agent.api_client import ApiClient, ApiError

log = logging.getLogger("agent.tunnel")


def _establish_tunnel(tunnel_request: dict) -> (bool, str):
    """STUBBED — see module docstring. Always returns (False, <reason>)
    honestly rather than pretending a tunnel opened. Real implementation
    needs a tunnel broker on the Admin Panel side to connect out to."""
    return False, (
        "remote tunnel establishment is not implemented yet (Agent-side stub only, "
        "spec Section 2.2 line item) — no tunnel broker exists on the Admin Panel "
        "side to connect to. The request was seen and is being reported honestly "
        "as unsupported rather than silently ignored."
    )


def run_tunnel_cycle(client: ApiClient) -> bool:
    """One cycle: checks whether a tunnel has been requested and, if so,
    attempts it (currently always the stub above) and reports the outcome.
    Returns True if a request was seen, False if there was nothing
    pending."""
    result = client.get_tunnel_request()
    request = result.get("request")
    if not request:
        return False

    tunnel_id = request["id"]
    log.info("Remote tunnel requested (tunnel_id=%s) — attempting...", tunnel_id)

    established, message = _establish_tunnel(request)
    if established:
        client.report_tunnel_status(tunnel_id, "connected", message)
        log.info("Tunnel %s connected.", tunnel_id)
    else:
        client.report_tunnel_status(tunnel_id, "unsupported", message)
        log.warning("Tunnel %s could not be established: %s", tunnel_id, message)

    return True


def run_tunnel_poll_loop(client: ApiClient, interval_seconds: int, stop_event):
    while not stop_event.is_set():
        try:
            run_tunnel_cycle(client)
        except ApiError as e:
            log.debug("Tunnel poll failed (endpoint may not exist on the Admin Panel yet): %s", e)
        except Exception:
            log.exception("Unexpected error during tunnel poll")
        stop_event.wait(interval_seconds)
