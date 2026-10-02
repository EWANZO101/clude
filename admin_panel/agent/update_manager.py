"""
Drives one instance through the update lifecycle the Admin Panel expects
(spec Sections 28, 33 — same state machine as app/models.py::ALLOWED_TRANSITIONS
on the Admin Panel side): waiting -> downloading -> validating -> preparing
-> installing -> restarting -> health_check -> successful/failed, with
automatic rollback (health_check fails -> rolling_back -> rolled_back) now
wired up for real (Part 4, spec Section 29).

The health check itself (agent/health_check.py) is a real functional check
when kiosk_health_check_url or kiosk_health_check_command is configured —
not just "does the process still exist" (that was as far as Part 3 could
honestly go). On failure, this module restores the recovery point Part 2
already proved works, restarts the supervisor onto the restored files, and
re-checks health on the restored version before declaring the rollback
itself successful. If even the restore can't run, or the restored version
also fails its health check, this reports 'failed' plainly rather than
claiming a rollback that didn't actually leave things working — that's the
one outcome with no good automatic answer, and it's left visible rather
than papered over.
"""
import logging
import os
import time

from agent import system_info
from agent.api_client import ApiClient, ApiError
from agent.config import AgentSettings, save_settings
from agent.package_validation import (
    PackageValidationError, verify_checksum, validate_package_structure,
)
from agent.recovery import make_recovery_point, restore_recovery_point, RecoveryError
from agent.installer import install_package, InstallError
from agent.health_check import run_health_check, HealthCheckResult

log = logging.getLogger("agent.update_manager")


def _version_file_path(settings: AgentSettings) -> str:
    return os.path.join(os.path.dirname(settings.resolve_app_install_dir()), "current_version.txt")


def read_local_version(settings: AgentSettings) -> str:
    path = _version_file_path(settings)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip() or None


def write_local_version(settings: AgentSettings, version: str) -> None:
    path = _version_file_path(settings)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(version)
    os.replace(tmp, path)


def clear_local_version(settings: AgentSettings) -> None:
    """Used after a rollback restores a machine to 'nothing was installed
    before this deployment' (previous_version is None) — the version file
    must not keep claiming the version that was just rolled back away
    from."""
    path = _version_file_path(settings)
    if os.path.isfile(path):
        os.remove(path)


def _report_status_safe(client: ApiClient, deployment_id: str, status: str,
                         message: str = None, health_check_passed: bool = None) -> None:
    """report_update_status wrapped so a reporting failure (network blip,
    or the Admin Panel not yet recognizing a status value like
    'rolling_back'/'rolled_back') never blocks the actual local recovery
    action it describes. The action already happened or is about to happen
    regardless of whether the Admin Panel could be told about it — losing
    the status update is a real problem (see NOT BUILT AT ALL YET below)
    but it must never be the reason a rollback doesn't happen."""
    try:
        client.report_update_status(deployment_id, status, message=message,
                                     health_check_passed=health_check_passed)
    except ApiError as e:
        log.warning("Could not report status '%s' for deployment %s (continuing anyway): %s",
                    status, deployment_id, e)


# Default health-check port per product, matching each app's own run.py
# default (OPSLAB_KIOSK_PORT / INVENTORY_OPS_PORT) — see each default's own
# comment for why kiosk sits on 8421. Only ever used the very first time
# nothing is configured yet; a "configure" push or the app's own port env
# var overriding this later needs the health check URL updated to match.
_DEFAULT_HEALTH_CHECK_PORT = {"kiosk": 8421, "inventory-ops": 8521}


def _auto_default_kiosk_command(supervisor, settings: AgentSettings, settings_path) -> None:
    """Zero-touch bring-up: if nothing has ever set this instance's active
    app command (no admin ever clicked "Configure what starts the process"),
    and a package has just been installed for the first time, default it to
    running the just-installed app's own run.py with THIS agent's own
    Python interpreter, in its own install directory. This is what lets a
    fresh `install.ps1` enrollment end with a fully running, fully managed
    app with no further manual step - the Admin Panel auto-schedules its
    latest release (for this instance's own product — see
    agent_api.py::register_instance/_auto_schedule_latest_release) to every
    newly-registered instance, so by the time this runs there's real
    application code sitting in app_install_dir with a run.py at its root
    (every product's release build script includes it at the package root).

    Never overwrites an operator's own explicit choice - only fires when
    the active app command is still empty."""
    if supervisor is None or supervisor.is_configured():
        return

    app_dir = settings.resolve_app_install_dir()
    python_exe = system_info.resolve_python_executable()
    default_command = f'"{python_exe}" run.py'

    log.info("No start command configured yet for %s — defaulting to the just-installed "
              "app: %s (in %s)", settings.product, default_command, app_dir)
    settings.set_active_app_command(default_command, app_dir)
    health_check_url_set = (
        settings.active_app_health_check_url()
        or (settings.product == "kiosk" and settings.kiosk_health_check_command)
    )
    if not health_check_url_set:
        # Every product ships its own unauthenticated /health route built
        # specifically for this — wiring it in here is what turns
        # update_manager's post-install health check from a "the process
        # still exists" guess into a real functional check, with no
        # separate configuration step.
        port = _DEFAULT_HEALTH_CHECK_PORT.get(settings.product, 8421)
        default_health_url = f"http://127.0.0.1:{port}/health"
        if settings.product == "inventory-ops":
            settings.inventory_ops_health_check_url = default_health_url
        else:
            settings.kiosk_health_check_url = default_health_url
    if settings_path is not None:
        try:
            save_settings(settings, settings_path)
        except OSError as e:
            log.warning("Could not persist the auto-defaulted start command "
                        "(it will still run this session, but won't survive a restart): %s", e)
    supervisor.reconfigure(default_command, app_dir)


def run_update_cycle(client: ApiClient, settings: AgentSettings, supervisor=None, settings_path=None) -> bool:
    """One cycle: checks for a due update and, if found, drives it through
    the full lifecycle. Returns True if there was something to do (whether
    it succeeded or failed), False if there was nothing pending or it isn't
    due yet. `supervisor`, if given, is restarted at the 'restarting' step
    and factored into the health check (see agent.health_check).
    `settings_path`, if given, lets a first-ever successful install
    auto-default kiosk_start_command (see _auto_default_kiosk_command
    below) and persist that choice to settings.json."""
    result = client.get_current_update()
    deployment = result.get("deployment")
    if deployment is None:
        return False
    if not deployment.get("due"):
        log.debug("Deployment %s scheduled but not due yet.", deployment["id"])
        return False

    status = deployment["status"]
    if status != "waiting":
        # Something is already downloading/installing/etc from an earlier,
        # possibly-interrupted cycle. Resuming mid-flight safely is real
        # work (matching exactly where it left off) — out of scope for
        # Part 2, logged rather than silently retried from scratch.
        log.info("Deployment %s already in progress (status=%s) — not resuming.", deployment["id"], status)
        return True

    deployment_id = deployment["id"]
    package = deployment["package"]
    version = package["version"]
    checksum = package["checksum_sha256"]
    download_url = package["download_url"]

    download_dir = settings.resolve_download_dir()
    os.makedirs(download_dir, exist_ok=True)
    zip_path = os.path.join(download_dir, f"{deployment_id}.zip")

    log.info("Downloading update v%s (deployment %s)...", version, deployment_id)
    try:
        client.download_update(download_url, zip_path)
    except (ApiError, OSError) as e:
        log.error("Download failed: %s", e)
        client.report_update_status(deployment_id, "failed", f"download failed: {e}")
        return True

    client.report_update_status(deployment_id, "validating")
    try:
        verify_checksum(zip_path, checksum)
        # strict=True (require update.json + rescue/) only for kiosk — see
        # validate_package_structure's own docstring for why a non-kiosk
        # product's simpler release shape shouldn't be forced to imitate
        # Kiosk's packaging conventions.
        manifest = validate_package_structure(zip_path, version, strict=(settings.product == "kiosk"))
    except PackageValidationError as e:
        log.error("Validation failed: %s", e)
        client.report_update_status(deployment_id, "failed", str(e))
        return True

    client.report_update_status(deployment_id, "preparing")
    previous_version = read_local_version(settings)
    try:
        make_recovery_point(
            settings.resolve_recovery_dir(), deployment_id,
            settings.resolve_app_install_dir(), settings.kiosk_config_path,
            previous_version,
        )
    except RecoveryError as e:
        log.error("Recovery point creation failed: %s", e)
        client.report_update_status(deployment_id, "failed", f"could not create recovery point: {e}")
        return True

    client.report_update_status(deployment_id, "installing")
    if supervisor is not None:
        # Stop the kiosk process BEFORE touching app_install_dir. On Windows,
        # a running process's open files (e.g. kiosk_local.db) can't be
        # deleted or overwritten while it holds them — install_package would
        # fail with WinError 32. Stopping first releases those handles.
        # (Linux would tolerate unlink-while-open, which is why this only
        # surfaced on Windows installs.) stop() is a safe no-op if the
        # process isn't running.
        log.info("Stopping kiosk application process before install...")
        supervisor.stop()
    try:
        install_package(zip_path, settings.resolve_app_install_dir())
    except InstallError as e:
        log.error("Install failed: %s", e)
        client.report_update_status(deployment_id, "failed", str(e))
        if supervisor is not None:
            # We stopped it to install; the install failed, so bring the
            # (unchanged-or-recovered) app back up rather than leaving the
            # kiosk sitting dead until the next poll cycle.
            log.info("Install failed — restarting kiosk application process on existing files...")
            supervisor.start()
        return True

    client.report_update_status(deployment_id, "restarting")
    if supervisor is not None:
        _auto_default_kiosk_command(supervisor, settings, settings_path)
        log.info("Restarting kiosk application process...")
        supervisor.restart()
    else:
        log.info("(No process supervisor configured — nothing to restart yet.)")
    time.sleep(settings.health_check_grace_period_seconds)  # let the app come up before probing

    result = run_health_check(
        settings.resolve_app_install_dir(), settings, supervisor,
        retries=settings.health_check_retries,
        retry_delay_seconds=settings.health_check_retry_delay_seconds,
    )
    _report_status_safe(client, deployment_id, "health_check",
                         message=result.message, health_check_passed=result.passed)

    if result.passed:
        client.report_update_status(deployment_id, "successful")
        write_local_version(settings, version)
        log.info("Update to v%s completed successfully (%s check: %s).",
                  version, result.method, result.message)
    else:
        log.error("Health check failed for v%s (%s): %s", version, result.method, result.message)
        _attempt_rollback(client, settings, supervisor, deployment_id, version, result, settings_path)

    return True


def _clear_kiosk_configuration(supervisor, settings: AgentSettings, settings_path, reason: str) -> None:
    """Used when there is genuinely no valid app left to run — specifically,
    a rollback that restored to "no prior install" (this was the first-ever
    install, so there was nothing to roll back TO; restore_recovery_point
    still recreates app_install_dir, just empty). Leaving the stale
    kiosk_start_command in place would point at a script that no longer
    exists, which is exactly what was observed on a real deployment: exit
    code 2 ("can't open file 'run.py'"), crash-looping every couple of
    seconds until the watchdog's restart budget ran out. Clearing it
    instead means nothing tries to start until a future successful install
    repopulates app_install_dir — at which point
    _auto_default_kiosk_command fires fresh, exactly as it would for a
    genuinely first-time install."""
    if supervisor is not None:
        supervisor.stop()
        supervisor.reconfigure(None)
    settings.set_active_app_command("", "")
    if settings.product == "inventory-ops":
        settings.inventory_ops_health_check_url = ""
    else:
        settings.kiosk_health_check_url = ""
        settings.kiosk_health_check_command = ""
    if settings_path is not None:
        try:
            save_settings(settings, settings_path)
        except OSError as e:
            log.warning("Could not persist the cleared configuration (%s): %s", reason, e)
    log.warning("Cleared the %s start command and health check (%s) — nothing valid to "
                "supervise until the next successful install.", settings.product, reason)


def _attempt_rollback(client: ApiClient, settings: AgentSettings, supervisor, deployment_id: str,
                       failed_version: str, failure: HealthCheckResult, settings_path=None) -> None:
    """Spec Section 29's automatic-rollback flow: restore the recovery point
    Part 2 built and proved, restart onto the restored files, and confirm
    the restored version is actually healthy before calling this a
    successful rollback rather than just an attempted one."""
    log.warning(
        "Attempting automatic rollback for deployment %s (v%s failed health check: %s)",
        deployment_id, failed_version, failure.message,
    )
    _report_status_safe(
        client, deployment_id, "rolling_back",
        message=f"health check failed ({failure.message}); restoring last known good version",
    )

    try:
        meta = restore_recovery_point(
            settings.resolve_recovery_dir(), deployment_id, settings.resolve_app_install_dir(),
        )
    except RecoveryError as e:
        message = (
            f"health check failed for v{failed_version} AND automatic rollback could not run "
            f"({e}). The kiosk may be left in a broken state — manual intervention required."
        )
        log.critical(message)
        _report_status_safe(client, deployment_id, "failed", message)
        return

    if not meta.get("had_app"):
        # This was the first-ever install — there is no previous version to
        # restore, so restore_recovery_point just recreated an EMPTY
        # app_install_dir. Restarting the supervisor against it would only
        # crash-loop; clear the configuration instead of leaving a stale
        # command pointing at nothing.
        _clear_kiosk_configuration(
            supervisor, settings, settings_path,
            reason=f"rollback of v{failed_version} — no prior install existed",
        )
        clear_local_version(settings)
        message = (
            f"health check failed for v{failed_version} ({failure.message}); this was the first "
            f"install, so there was nothing to roll back TO — cleared the kiosk configuration "
            f"rather than leaving a stale start command pointing at an empty directory. The kiosk "
            f"will start automatically once a future update installs successfully."
        )
        log.warning(message)
        _report_status_safe(client, deployment_id, "failed", message)
        return

    if supervisor is not None:
        log.info("Restarting kiosk application process on the restored version...")
        supervisor.restart()
    time.sleep(settings.health_check_grace_period_seconds)

    rollback_result = run_health_check(
        settings.resolve_app_install_dir(), settings, supervisor,
        retries=settings.health_check_retries,
        retry_delay_seconds=settings.health_check_retry_delay_seconds,
    )

    if rollback_result.passed:
        restored_version = meta.get("previous_version")
        _report_status_safe(
            client, deployment_id, "rolled_back",
            message=f"restored and verified healthy at v{restored_version or '(none — no prior install)'}",
        )
        if restored_version:
            write_local_version(settings, restored_version)
        else:
            clear_local_version(settings)
        log.info("Automatic rollback for deployment %s succeeded — restored to v%s.",
                  deployment_id, restored_version)
    else:
        message = (
            f"health check failed for v{failed_version} ({failure.message}); automatic rollback "
            f"restored the previous files, but the restored version ALSO failed its health check "
            f"({rollback_result.message}). The kiosk is likely down — manual intervention required."
        )
        log.critical(message)
        _report_status_safe(client, deployment_id, "failed", message)


def run_update_poll_loop(client: ApiClient, settings: AgentSettings, interval_seconds: int, stop_event,
                          supervisor=None, settings_path=None):
    while not stop_event.is_set():
        try:
            run_update_cycle(client, settings, supervisor, settings_path)
        except ApiError as e:
            log.warning("Update poll failed: %s", e)
        except Exception:
            log.exception("Unexpected error during update cycle")
        stop_event.wait(interval_seconds)
