"""
Remote start/stop/restart/configure/run_command channel. Polls GET
/api/v1/instances/commands, executes against the ProcessSupervisor (or, for
run_command, a real subprocess), acks success/failed back to the Admin
Panel. This is the client-side half of what app/blueprints/agent_api.py
(get_pending_command/ack_command) and app/blueprints/instances.py
(_queue_command, kiosk_configure, run_command) already expected but that had
no caller anywhere in the Agent before now.

'configure' (from the Admin Panel's "Configure what starts the kiosk
process" form) is a command_type on the SAME InstanceCommand queue as
start/stop/restart, carrying kiosk_start_command / kiosk_working_dir /
kiosk_health_check_url / kiosk_health_check_command in its payload - it is
NOT the separate /instances/config version-push channel (config_manager.py),
which is for arbitrary application config, not what starts the process.
Applying it: persist the new fields to settings.json (so a later Agent
restart doesn't forget them), then reconfigure() + restart() the SAME
ProcessSupervisor instance every other thread already holds a reference to.

'run_command' is genuine, unrestricted remote code execution - the Admin
Panel's answer to "add or install things on the kiosk remotely" where no
real remote-desktop/tunnel exists yet (see instances.py::run_command's own
docstring). It is NOT sandboxed or allow-listed; the trust boundary is the
Admin Panel's manage_instances permission check on the way in, not
anything enforced here.
"""
import logging
import subprocess

import requests

from agent.api_client import ApiClient, ApiError
from agent.config import AgentSettings, save_settings
from agent.heartbeat import send_heartbeat
from agent.backup_sync import run_backup_now, run_db_reset
from agent.self_update import run_agent_update

log = logging.getLogger("agent.commands")

RUN_COMMAND_TIMEOUT_SECONDS = 120
RUN_COMMAND_MAX_OUTPUT_CHARS = 4000


def _apply_configure(supervisor, settings: AgentSettings, settings_path, payload: dict) -> str:
    """Returns a human-readable result message; raises on failure so the
    caller's existing try/except -> ack('failed', str(e)) handles it.

    Payload keys are still named kiosk_* regardless of product (nothing on
    the Admin Panel side sends this command for an inventory-ops instance
    today — there's no "configure" action in app/blueprints/
    inventory_ops_instances.py — but if one's ever added it can keep using
    these same key names). Routed to whichever settings fields are actually
    "active" for this instance's product via set_active_app_command(), so a
    kiosk instance keeps writing kiosk_* exactly as before."""
    new_command = (payload.get("kiosk_start_command") or "").strip()
    working_dir = (payload.get("kiosk_working_dir") or "").strip()
    health_check_url = (payload.get("kiosk_health_check_url") or "").strip()

    settings.set_active_app_command(new_command, working_dir)
    if settings.product == "inventory-ops":
        settings.inventory_ops_health_check_url = health_check_url
    else:
        health_check_command = (payload.get("kiosk_health_check_command") or "").strip()
        inventory_sync_url = (payload.get("kiosk_inventory_sync_url") or "").strip()
        settings.kiosk_health_check_url = health_check_url
        settings.kiosk_health_check_command = health_check_command
        settings.kiosk_inventory_sync_url = inventory_sync_url
    save_settings(settings, settings_path)

    if not new_command:
        supervisor.stop()
        supervisor.reconfigure(None)
        return "Cleared — nothing configured to run."

    supervisor.reconfigure(new_command, working_dir or None)
    supervisor.restart()
    if not supervisor.is_running():
        raise RuntimeError("configured process did not stay running after start")
    return "Configured and started."


ROLE_COMMAND_TYPES = ("role_create", "role_delete", "role_set_login", "role_set_sidebar")
ROLE_REQUEST_TIMEOUT_SECONDS = 10


def _run_role_command(command_type: str, payload: dict, settings: AgentSettings) -> tuple:
    """Relays a role_* command straight to kiosk_app's own sync_api.py
    role routes (which call the exact same kiosk_app/app/role_admin.py
    logic the terminal's own /admin panel uses) — this Agent has no role
    business logic of its own, it's purely a loopback relay, same as
    inventory_sync.py is for items/tools/local_users. Returns (ok, message)
    the way _run_remote_command does, so check_and_execute can ack it the
    same way. Fails with a clear message if kiosk_inventory_sync_url isn't
    configured — same "nothing to supervise/sync yet" convention used
    elsewhere rather than a bare connection-error traceback."""
    base_url = settings.kiosk_inventory_sync_url.rstrip("/") if settings.kiosk_inventory_sync_url else ""
    if not base_url:
        return False, "kiosk_inventory_sync_url is not configured on this Agent — nothing to relay to."

    role_name = (payload.get("name") or "").strip()
    body = {"actor": payload.get("actor") or "remote"}

    if command_type == "role_create":
        body["name"] = role_name
        body["description"] = payload.get("description")
        url = f"{base_url}/api/sync/roles/create"
    elif command_type == "role_delete":
        url = f"{base_url}/api/sync/roles/{role_name}/delete"
    elif command_type == "role_set_login":
        body["enabled"] = bool(payload.get("enabled"))
        url = f"{base_url}/api/sync/roles/{role_name}/login"
    elif command_type == "role_set_sidebar":
        body["visibility"] = payload.get("visibility") or {}
        url = f"{base_url}/api/sync/roles/{role_name}/sidebar"
    else:
        return False, f"Unsupported role command_type: {command_type!r}"

    try:
        resp = requests.post(url, json=body, timeout=ROLE_REQUEST_TIMEOUT_SECONDS)
    except requests.RequestException as e:
        return False, f"Couldn't reach the Kiosk App to relay this: {e}"

    try:
        result = resp.json()
    except ValueError:
        return False, f"Kiosk App returned a non-JSON response (status {resp.status_code})."
    return bool(result.get("ok")), result.get("message") or f"status {resp.status_code}"


def _run_sidebar_reorder_command(payload: dict, settings: AgentSettings) -> tuple:
    """Relays a sidebar_reorder command to kiosk_app's own
    sync_api.py::reorder_sidebar — same loopback-relay pattern
    _run_role_command uses above, for the sidebar builder feature (see
    /root/.claude/plans/sprightly-meandering-whisper.md)."""
    base_url = settings.kiosk_inventory_sync_url.rstrip("/") if settings.kiosk_inventory_sync_url else ""
    if not base_url:
        return False, "kiosk_inventory_sync_url is not configured on this Agent — nothing to relay to."

    order = payload.get("order") or []
    try:
        resp = requests.post(
            f"{base_url}/api/sync/sidebar/reorder", json={"order": order},
            timeout=ROLE_REQUEST_TIMEOUT_SECONDS,
        )
    except requests.RequestException as e:
        return False, f"Couldn't reach the Kiosk App to relay this: {e}"

    try:
        result = resp.json()
    except ValueError:
        return False, f"Kiosk App returned a non-JSON response (status {resp.status_code})."
    return bool(result.get("ok")), result.get("message") or f"status {resp.status_code}"


def _run_remote_command(payload: dict) -> tuple:
    """Runs an arbitrary shell command on this machine. Returns (ok, message).
    Deliberately not sandboxed - see module docstring. shell=True so an
    admin can paste exactly the one-liner they'd type at a real prompt
    (an msiexec invocation, a pip install, a PowerShell pipeline) without
    needing to know shlex-quoting rules first."""
    command_text = (payload.get("command") or "").strip()
    if not command_text:
        return False, "No command was provided."

    try:
        result = subprocess.run(
            command_text, shell=True, capture_output=True, text=True,
            timeout=RUN_COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return False, f"Timed out after {RUN_COMMAND_TIMEOUT_SECONDS}s with no result."
    except OSError as e:
        return False, f"Could not run command: {e}"

    output = ((result.stdout or "") + (result.stderr or "")).strip()
    if len(output) > RUN_COMMAND_MAX_OUTPUT_CHARS:
        omitted = len(output) - RUN_COMMAND_MAX_OUTPUT_CHARS
        output = output[:RUN_COMMAND_MAX_OUTPUT_CHARS] + f"\n... (truncated, {omitted} more characters)"

    message = f"exit code {result.returncode}"
    if output:
        message += f":\n{output}"
    return result.returncode == 0, message


def check_and_execute(client: ApiClient, supervisor, settings: AgentSettings, settings_path,
                       wait_seconds: float = 0) -> bool:
    """One poll cycle. Returns True if a command was found (regardless of
    outcome — check the ack for that), False if nothing was pending.
    wait_seconds > 0 long-polls (see ApiClient.get_pending_command) so a
    command queued while this call is in flight is picked up immediately,
    not after the next full poll interval."""
    result = client.get_pending_command(wait_seconds=wait_seconds)
    command = result.get("command")
    if not command:
        return False

    command_id = command["id"]
    command_type = command.get("command_type")
    log.info("Received command %s: %s", command_id, command_type)

    process_lifecycle_command = command_type in ("configure", "start", "stop", "restart")

    try:
        client.start_command(command_id)
    except ApiError as e:
        # Best-effort — this only feeds the Admin Panel's live status
        # display (InstanceCommand.started_at), it must never block
        # actually running the command below. Worst case if this fails,
        # the UI just falls back to guessing from when the command was
        # queued instead of when execution truly began, same as before
        # this endpoint existed.
        log.warning("start_command notification failed for %s (continuing anyway): %s", command_id, e)

    try:
        if command_type == "configure":
            message = _apply_configure(supervisor, settings, settings_path, command.get("payload") or {})
            client.ack_command(command_id, "success", message)
        elif command_type == "run_command":
            ok, message = _run_remote_command(command.get("payload") or {})
            client.ack_command(command_id, "success" if ok else "failed", message)
        elif command_type in ROLE_COMMAND_TYPES:
            ok, message = _run_role_command(command_type, command.get("payload") or {}, settings)
            client.ack_command(command_id, "success" if ok else "failed", message)
        elif command_type == "sidebar_reorder":
            ok, message = _run_sidebar_reorder_command(command.get("payload") or {}, settings)
            client.ack_command(command_id, "success" if ok else "failed", message)
        elif command_type == "backup_now":
            source = (command.get("payload") or {}).get("source", "scheduled")
            ok, message = run_backup_now(client, settings.kiosk_inventory_sync_url, source)
            client.ack_command(command_id, "success" if ok else "failed", message)
        elif command_type == "db_reset":
            ok, message = run_db_reset(client, settings.kiosk_inventory_sync_url)
            client.ack_command(command_id, "success" if ok else "failed", message)
        elif command_type == "agent_update":
            ok, message = run_agent_update(settings, command.get("payload") or {})
            client.ack_command(command_id, "success" if ok else "failed", message)
        elif not supervisor.is_configured():
            client.ack_command(
                command_id, "failed",
                f"No start command is configured for {settings.product} on this instance — nothing to {command_type}.",
            )
        elif command_type == "start":
            supervisor.start()
            if not supervisor.is_running():
                raise RuntimeError("process did not stay running after start()")
            client.ack_command(command_id, "success", "Started.")
        elif command_type == "stop":
            supervisor.stop()
            client.ack_command(command_id, "success", "Stopped.")
        elif command_type == "restart":
            supervisor.restart()
            if not supervisor.is_running():
                raise RuntimeError("process did not stay running after restart()")
            client.ack_command(command_id, "success", "Restarted.")
        else:
            client.ack_command(command_id, "failed", f"Unsupported command_type: {command_type!r}")
    except Exception as e:
        log.exception("Command %s (%s) failed", command_id, command_type)
        client.ack_command(command_id, "failed", str(e))

    if process_lifecycle_command:
        # Without this, the Admin Panel's "Kiosk Process" status pill only
        # updates on the next scheduled heartbeat (heartbeat_interval_seconds,
        # 60s default) — completely decoupled from the command ack above,
        # which lands almost instantly. That gap is what made Start/Stop/
        # Restart look "stuck": Recent Commands would say "success" right
        # away while the status pill sat on the old value for up to a
        # minute. Firing a heartbeat here, right after the process state
        # actually changed (success OR failure — a failed start can still
        # have left the process in a different state than before), closes
        # that gap so the pill reflects reality within a couple of seconds
        # instead of up to a minute.
        try:
            send_heartbeat(client, supervisor=supervisor)
        except ApiError as e:
            log.warning("Post-command heartbeat failed (will still catch up on the next scheduled one): %s", e)

    return True


def run_command_poll_loop(client: ApiClient, supervisor, settings: AgentSettings, settings_path,
                           interval_seconds: int, stop_event, long_poll_wait_seconds: float = 20):
    """Long-polls by default (see check_and_execute/ApiClient.get_pending_command)
    so Start/Stop/Restart/Configure/Run-command reach the Agent within
    about a second of being clicked, instead of waiting up to
    interval_seconds for the next ordinary poll. interval_seconds is still
    used, but only as the backoff after a failed poll (server unreachable,
    auth error, etc.) — not as the steady-state cadence, which the long
    poll itself now provides."""
    while not stop_event.is_set():
        try:
            check_and_execute(client, supervisor, settings, settings_path,
                               wait_seconds=long_poll_wait_seconds)
        except ApiError as e:
            log.warning("Command poll failed: %s", e)
            stop_event.wait(interval_seconds)
        except Exception:
            log.exception("Unexpected error during command poll")
            stop_event.wait(interval_seconds)
        # No wait on the ordinary path: the long poll above already waited
        # (up to long_poll_wait_seconds) when nothing was pending, and if a
        # command WAS found, looping straight back around picks up
        # anything else already queued without delay.
