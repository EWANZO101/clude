import logging

from agent import system_info
from agent.api_client import ApiClient, ApiError

log = logging.getLogger("agent.heartbeat")


def send_heartbeat(client: ApiClient, app_version: str = None, supervisor_status: dict = None) -> dict:
    """One heartbeat call. Returns the Admin Panel's response, or raises
    ApiError — callers decide whether that's worth logging-and-continuing
    (it almost always is; a single missed heartbeat is not an incident).
    supervisor_status, if given, is the dict from ProcessSupervisor.status()
    — surfaces the Kiosk Application's running/giving_up state (spec
    Section 44-45) so it's visible from the Admin Panel side without
    needing to read this machine's local logs. This is a best-effort extra
    field: the Admin Panel isn't available in this build environment to
    confirm it accepts (or ignores) an unrecognized key, so this is written
    defensively — see PROGRESS.txt."""
    payload = {
        "agent_version": system_info.agent_version(),
        "app_version": app_version,
        "os_version": system_info.detect_os_version(),
        "local_ip": system_info.detect_local_ip(),
        # public_ip/port are left for a later part once the Kiosk Application
        # (and therefore a real bound port) exists.
    }
    if supervisor_status is not None:
        payload["supervisor_status"] = supervisor_status
    result = client.heartbeat(**payload)
    log.debug("Heartbeat ok: %s", result)
    return result


def run_heartbeat_loop(client: ApiClient, interval_seconds: int, stop_event,
                        app_version_getter=None, supervisor=None):
    """Runs until stop_event is set. app_version_getter is a zero-arg
    callable so later parts can report the version the Agent actually has
    installed rather than a fixed string — optional here since Part 1 has
    no update/install logic yet. supervisor, if given, is a ProcessSupervisor
    whose .status() is included in every heartbeat (Part 6)."""
    while not stop_event.is_set():
        try:
            app_version = app_version_getter() if app_version_getter else None
            supervisor_status = supervisor.status() if supervisor is not None else None
            send_heartbeat(client, app_version=app_version, supervisor_status=supervisor_status)
        except ApiError as e:
            log.warning("Heartbeat failed: %s", e)
        except Exception:
            log.exception("Unexpected error sending heartbeat")
        stop_event.wait(interval_seconds)
