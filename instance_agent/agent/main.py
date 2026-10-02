"""
Instance Agent entrypoint — wires together identity/registration, heartbeat
(Part 1), config sync (Part 1), update lifecycle + automatic rollback
(Parts 2 and 4), Kiosk Application process supervision (Part 3), error
reporting, and the remote-tunnel stub (Part 6).

Usage:
    python -m agent.main

First run on a fresh machine needs OPSLAB_ADMIN_URL and
OPSLAB_REGISTRATION_TOKEN in the environment (or already present in
settings.json — see config.py for the default path). After a successful
registration, the token is consumed and never needed again.
"""
import logging
import os
import signal
import sys
import threading

from agent.config import AgentSettings, load_settings, save_settings, default_settings_path
from agent.identity import ensure_registered, RegistrationError
from agent.api_client import ApiClient
from agent.heartbeat import run_heartbeat_loop
from agent.config_manager import run_config_poll_loop
from agent.update_manager import run_update_poll_loop, read_local_version
from agent.process_supervisor import ProcessSupervisor
from agent.tunnel import run_tunnel_poll_loop
from agent import error_reporter


def setup_logging():
    logging.basicConfig(
        level=os.environ.get("OPSLAB_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
    )


def load_settings_with_env_overrides(path=None) -> AgentSettings:
    settings = load_settings(path)
    # Environment variables are for first-run bootstrap only — once
    # settings.json has an identity, these are ignored so a stray env var
    # left set on the machine can't silently re-point an already-registered
    # agent at a different Admin Panel.
    if not settings.is_registered():
        settings.admin_url = os.environ.get("OPSLAB_ADMIN_URL", settings.admin_url)
        settings.registration_token = os.environ.get(
            "OPSLAB_REGISTRATION_TOKEN", settings.registration_token
        )
    settings.kiosk_config_path = os.environ.get("OPSLAB_KIOSK_CONFIG_PATH", settings.kiosk_config_path)
    return settings


def run(settings_path=None, external_stop_event=None):
    setup_logging()
    log = logging.getLogger("agent.main")

    settings_path = settings_path or default_settings_path()
    settings = load_settings_with_env_overrides(settings_path)

    try:
        settings = ensure_registered(settings, settings_path)
    except RegistrationError as e:
        log.error("Cannot start: %s", e)
        sys.exit(1)

    # Registration succeeds without kiosk_config_path necessarily being set
    # (it's not needed to identify the instance) — but persist it now if an
    # env var supplied one this run, so future runs don't need the env var.
    save_settings(settings, settings_path)

    client = ApiClient(settings.admin_url, settings.instance_id, settings.instance_secret)

    # Error reporting (Part 6): attached to the "agent" logger, which is the
    # parent of every agent.* logger in this project — every existing
    # log.error()/log.exception() call throughout the codebase (a failed
    # health check, a crash-loop give-up, an install failure, etc.) starts
    # flowing to the Admin Panel from here on, with no per-module changes
    # needed. Attached only after the client has real credentials, since an
    # error report before registration has nowhere authenticated to go.
    error_reporter.install(
        client,
        max_reports_per_window=settings.error_report_max_per_window,
        window_seconds=settings.error_report_window_seconds,
        dedup_seconds=settings.error_report_dedup_seconds,
    )

    supervisor = None
    if settings.kiosk_start_command:
        supervisor = ProcessSupervisor(
            settings.kiosk_start_command,
            working_dir=settings.kiosk_working_dir or settings.resolve_app_install_dir(),
            name="kiosk-app",
        )
        supervisor.start()
        supervisor.start_watchdog()
        log.info("Kiosk application process supervision started.")
    else:
        log.info("No kiosk_start_command configured — nothing to supervise yet.")

    stop_event = external_stop_event or threading.Event()

    def handle_signal(signum, frame):
        log.info("Received signal %s, shutting down...", signum)
        stop_event.set()

    # Only safe to install OS signal handlers from the main thread of the
    # main interpreter (Python raises ValueError otherwise) — true for the
    # normal `python -m agent.main` / systemd ExecStart path, but NOT true
    # for the Windows service wrapper (service_files/windows/
    # opslab_agent_service.py), which calls this run() from a worker thread
    # and instead signals shutdown via external_stop_event directly from
    # SvcStop(). Skipping this on a non-main thread is correct, not a
    # missing feature — that caller already has its own shutdown path.
    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)
    else:
        log.debug(
            "Not running in the main thread (e.g. under the Windows service wrapper) — "
            "skipping OS signal handler registration; shutdown is via external_stop_event."
        )

    threads = [
        threading.Thread(
            target=run_heartbeat_loop,
            args=(client, settings.heartbeat_interval_seconds, stop_event,
                  lambda: read_local_version(settings), supervisor),
            name="heartbeat", daemon=True,
        ),
        threading.Thread(
            target=run_config_poll_loop,
            args=(client, settings, settings.config_poll_interval_seconds, stop_event),
            name="config-poll", daemon=True,
        ),
        threading.Thread(
            target=run_update_poll_loop,
            args=(client, settings, settings.update_poll_interval_seconds, stop_event, supervisor),
            name="update-poll", daemon=True,
        ),
        threading.Thread(
            target=run_tunnel_poll_loop,
            args=(client, settings.tunnel_poll_interval_seconds, stop_event),
            name="tunnel-poll", daemon=True,
        ),
    ]
    for t in threads:
        t.start()

    log.info("Agent running as instance %s. Press Ctrl+C to stop.", settings.instance_id)
    stop_event.wait()
    for t in threads:
        t.join(timeout=5)
    if supervisor is not None:
        supervisor.stop_watchdog()
        supervisor.stop()
    log.info("Agent stopped.")


if __name__ == "__main__":
    run()
