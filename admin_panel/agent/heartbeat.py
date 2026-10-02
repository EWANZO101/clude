import logging

from agent import system_info
from agent.api_client import ApiClient, ApiError

log = logging.getLogger("agent.heartbeat")


def _kiosk_process_status(supervisor) -> str:
    """Maps ProcessSupervisor's own status() onto the string values the
    Admin Panel already understands and renders (Instance.kiosk_process_status
    / app/templates/instances/detail.html) — the server side of this was
    already fully built and waiting; heartbeat.py just never actually sent
    it, which is the entire reason "Kiosk Process Status" stayed stuck on
    "Unknown (no heartbeat yet)" even once the app was confirmed running
    and passing its update-flow health check."""
    if supervisor is None or not supervisor.is_configured():
        return "not_configured"
    status = supervisor.status()
    if status["giving_up"]:
        return "giving_up"
    return "running" if status["running"] else "stopped"


def send_heartbeat(client: ApiClient, app_version: str = None, supervisor=None) -> dict:
    """One heartbeat call. Returns the Admin Panel's response, or raises
    ApiError — callers decide whether that's worth logging-and-continuing
    (it almost always is; a single missed heartbeat is not an incident)."""
    payload = {
        "agent_version": system_info.agent_version(),
        "app_version": app_version,
        "os_version": system_info.detect_os_version(),
        "local_ip": system_info.detect_local_ip(),
        "kiosk_process_status": _kiosk_process_status(supervisor),
        # public_ip/port are left for a later part once the Kiosk Application
        # (and therefore a real bound port) exists.
    }
    result = client.heartbeat(**payload)
    log.debug("Heartbeat ok: %s", result)
    return result


_LICENSE_ERROR_CODES = ("license_suspended", "license_expired")


def _handle_license_rejection(e: ApiError, supervisor) -> bool:
    """True if this ApiError is the Admin Panel telling us the instance's
    license is suspended/expired (app/instance_auth.py::instance_auth_required)
    — in which case this is a real kill switch, not a transient failure:
    stop the locally supervised kiosk process right now rather than
    leaving it running just because the network call to say so failed on
    a technicality. Idempotent — safe to call every heartbeat for as long
    as the suspension lasts; supervisor.stop() on an already-stopped
    process is a no-op."""
    if e.status_code != 403 or e.payload.get("error") not in _LICENSE_ERROR_CODES:
        return False
    reason = e.payload.get("error")
    if supervisor is not None and supervisor.is_running():
        log.warning("Instance license rejected (%s) — stopping the supervised kiosk process.", reason)
        supervisor.stop()
    else:
        log.warning("Instance license rejected (%s) — kiosk process already not running.", reason)
    return True


def run_heartbeat_loop(client: ApiClient, interval_seconds: int, stop_event, app_version_getter=None,
                        supervisor=None):
    """Runs until stop_event is set. app_version_getter is a zero-arg
    callable so later parts can report the version the Agent actually has
    installed rather than a fixed string — optional here since Part 1 has
    no update/install logic yet."""
    while not stop_event.is_set():
        try:
            app_version = app_version_getter() if app_version_getter else None
            send_heartbeat(client, app_version=app_version, supervisor=supervisor)
        except ApiError as e:
            if not _handle_license_rejection(e, supervisor):
                log.warning("Heartbeat failed: %s", e)
        except Exception:
            log.exception("Unexpected error sending heartbeat")
        stop_event.wait(interval_seconds)
