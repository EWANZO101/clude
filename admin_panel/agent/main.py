"""
Instance Agent entrypoint (Part 1: identity, heartbeat, config sync only —
update download/install is Part 2, process supervision of the Kiosk
Application is Part 3).

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

from agent.config import AgentSettings, load_settings, save_settings, default_settings_path, default_log_dir
from agent.identity import ensure_registered, RegistrationError
from agent.api_client import ApiClient
from agent.heartbeat import run_heartbeat_loop
from agent.config_manager import run_config_poll_loop
from agent.update_manager import run_update_poll_loop, read_local_version
from agent.process_supervisor import ProcessSupervisor
from agent.commands import run_command_poll_loop
from agent.inventory_sync import run_inventory_sync_loop


def setup_logging():
    # A Windows SERVICE (pythonservice.exe, no attached console) is very
    # likely to have sys.stderr as None or an otherwise-unusable stream -
    # basicConfig's default StreamHandler(sys.stderr) would then silently
    # (Python's logging module never lets a handler failure raise) produce
    # NOTHING, anywhere, ever - exactly what was observed running as the
    # real service: no crash, no Event Log errors, the service reporting
    # itself RUNNING throughout, but zero visible log output and zero
    # visible progress, with no way to tell whether the background threads
    # were even running at all. A real file handler doesn't depend on a
    # console existing. The stream handler is kept too (guarded) so
    # foreground/console "run" mode - used throughout this project's own
    # debugging - still sees output live, same as before.
    handlers = []
    try:
        log_dir = str(default_log_dir())
        os.makedirs(log_dir, exist_ok=True)
        handlers.append(logging.FileHandler(os.path.join(log_dir, "agent.log"), encoding="utf-8"))
    except OSError:
        pass  # falls through to whatever else can be attached below

    try:
        if sys.stderr is not None:
            handlers.append(logging.StreamHandler(sys.stderr))
    except Exception:
        pass

    logging.basicConfig(
        level=os.environ.get("OPSLAB_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
        handlers=handlers,
    )

    # An UNCAUGHT exception in a thread does NOT go through the logging
    # config above at all — Python reports it via a completely separate
    # mechanism, threading.excepthook, whose own default implementation
    # also just writes to sys.stderr. Fixing basicConfig's handlers alone
    # left this path untouched, so an exception raised directly in
    # run()'s own body (which executes on the Windows service wrapper's
    # background thread — see service_files/windows/opslab_agent_service.py)
    # would still vanish with no trace: no crash reported to the SCM, no
    # Event Log entry, nothing in agent.log, the service just silently
    # doing nothing forever after. Routed through our own logging (which
    # now has a real file handler) instead of the default hook.
    def _log_thread_exceptions(args):
        thread_name = args.thread.name if args.thread else "?"
        logging.getLogger("agent.thread").error(
            "Unhandled exception in thread %r — this thread has now stopped.",
            thread_name, exc_info=(args.exc_type, args.exc_value, args.exc_traceback),
        )

    threading.excepthook = _log_thread_exceptions


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

    # Always created (never None) so a remote "configure" command
    # (agent/commands.py) can call supervisor.reconfigure() on the SAME
    # instance every other thread already holds a reference to, instead of
    # needing to build a new supervisor and somehow hand it to threads that
    # already started. start()/start_watchdog() are safe no-ops when nothing
    # is configured yet (ProcessSupervisor.is_configured() is False).
    # Explicitly wire the Agent's own kiosk_config_path into the child's
    # environment rather than relying on kiosk_app's built-in default to
    # happen to match — those were previously two independently-hardcoded
    # paths that only coincided on Linux, so an "applied" config push (the
    # Agent genuinely did write the file at ITS path) could still never
    # reach kiosk_app on a platform whose default pointed elsewhere (e.g.
    # Windows). Copies os.environ rather than replacing it — the child
    # still needs its normal PATH/etc. to even start.
    kiosk_env = None
    if settings.kiosk_config_path:
        kiosk_env = dict(os.environ)
        kiosk_env["OPSLAB_KIOSK_CONFIG_PATH"] = settings.kiosk_config_path

    # active_app_command()/active_app_working_dir() resolve to the kiosk_*
    # or inventory_ops_* fields depending on settings.product (see
    # config.py) — every existing install has product="kiosk" (the field's
    # own default) and so behaves exactly as before; this branch only ever
    # takes the other path on a machine freshly registered against an
    # inventory-ops enrollment token.
    supervised_app_name = f"{settings.product}-app"
    supervisor = ProcessSupervisor(
        settings.active_app_command() or None,
        working_dir=settings.active_app_working_dir() or settings.resolve_app_install_dir(),
        env=kiosk_env,
        name=supervised_app_name,
        log_path=os.path.join(settings.resolve_log_dir(), f"{supervised_app_name}.log"),
    )
    supervisor.start_watchdog()
    if settings.active_app_command():
        supervisor.start()
        log.info("%s process supervision started.", settings.product)
    else:
        log.info("No start command configured yet for %s — waiting for a remote 'configure' command.", settings.product)

    stop_event = external_stop_event or threading.Event()

    def handle_signal(signum, frame):
        log.info("Received signal %s, shutting down...", signum)
        stop_event.set()

    # signal.signal() only works on the main thread of the main
    # interpreter — raises ValueError anywhere else. That's exactly where
    # this always runs when hosted as a Windows service: the service
    # wrapper (service_files/windows/opslab_agent_service.py) deliberately
    # runs agent_run() on a background thread so SvcStop() can signal a
    # clean shutdown via a Win32 event instead of relying on OS signals,
    # which behave differently for services. This call used to run
    # unconditionally and raise there every single time, killing this
    # entire function silently right after logging the kiosk-supervision
    # line above and before ever reaching the "Agent running..." line or
    # starting any of the four polling threads below — invisible until
    # agent.log existed to catch it (see git history for that fix) and
    # invisible even then until threading.excepthook was also fixed to
    # route through it, since an uncaught thread exception doesn't go
    # through logging.* at all by default. Every foreground/console "run"
    # test throughout this project's own debugging worked perfectly
    # because that path calls agent_run() directly on the main thread —
    # the actual installed service has been broken this way the entire
    # time. Signal handling isn't even needed in the service case: SvcStop
    # already signals external_stop_event directly.
    if threading.current_thread() is threading.main_thread():
        try:
            signal.signal(signal.SIGTERM, handle_signal)
            signal.signal(signal.SIGINT, handle_signal)
        except ValueError as e:
            log.warning("Could not install signal handlers (%s) — relying on "
                        "external_stop_event (if any) for shutdown instead.", e)
    else:
        log.info("Running on a background thread (e.g. as a Windows service) — "
                  "skipping OS signal handler registration, which only works on "
                  "the main thread; shutdown is already coordinated via "
                  "external_stop_event in that case.")

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
            args=(client, settings, settings.update_poll_interval_seconds, stop_event, supervisor, settings_path),
            name="update-poll", daemon=True,
        ),
        threading.Thread(
            target=run_command_poll_loop,
            args=(client, supervisor, settings, settings_path, settings.command_poll_interval_seconds, stop_event),
            name="command-poll", daemon=True,
        ),
        threading.Thread(
            target=run_inventory_sync_loop,
            args=(client, settings, settings.inventory_sync_interval_seconds, stop_event),
            name="inventory-sync", daemon=True,
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
