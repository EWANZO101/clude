"""
StockTool Kiosk (v2) — crash-resilience supervisor.

Runs the embedded Flask API in a background thread and restarts it
automatically if it ever dies (uncaught exception, dropped port, etc.),
without requiring a Windows Service install or admin rights. This is
what main.py imports and drives.

NOTE ON THE FILENAME: this used to be watchdog.py, but that collides
with the real "watchdog" package on PyPI (filesystem-change monitoring
-- unrelated to this file, but a common transitive dependency of dev
tooling). If that package is present in the build venv, PyInstaller's
import analysis can get confused by the name clash and silently drop
this file from the frozen exe instead of the real package (which
doesn't have a Supervisor class either, so neither choice would have
worked) -- producing "ModuleNotFoundError: No module named 'watchdog'"
at runtime despite this file clearly existing right next to main.py.
Renamed to server_supervisor.py to make the collision impossible rather
than depend on venv contents/PyInstaller's resolution order.
"""
import time
import logging

from waitress import serve

log = logging.getLogger("server_supervisor")

RESTART_BACKOFF_SECONDS = 2
MAX_CONSECUTIVE_FAILURES = 10  # give up spamming restarts if something is fundamentally broken


class Supervisor:
    def __init__(self, host: str | None = None, port: int | None = None):
        # host/port passed explicitly (e.g. by tests) override whatever
        # settings.json says; otherwise resolved from settings at each
        # run so a config change picked up between crash-restarts (or via
        # the Setup Wizard while the service is stopped) takes effect
        # without rebuilding the .exe.
        self._host_override = host
        self._port_override = port

    def _run_once(self):
        """Builds and runs the Flask app. Blocks until the server thread
        exits (crash or normal shutdown)."""
        from app import create_app
        from app.settings import load_settings, resolve_bind_host
        from sync_loop import start_sync_loop
        from backup_loop import start_backup_loop
        from relay_client import start_relay_client
        from update_check_loop import start_update_check_loop

        app = create_app()

        settings = load_settings(app.config["DATA_DIR"])
        host = self._host_override or resolve_bind_host(settings)
        port = self._port_override or settings.get("port", 8420)
        bind_mode = settings.get("bind_mode", "local")

        if bind_mode == "public":
            log.warning(
                "bind_mode=public — listening on %s:%d, reachable from "
                "outside this machine. Most API routes have no "
                "authentication; make sure that's intentional.",
                host, port,
            )
        elif bind_mode == "tunnel":
            log.info(
                "bind_mode=tunnel — API on 127.0.0.1:%d; the Cloudflared "
                "Windows service (if installed) is what exposes it "
                "externally.", port,
            )

        # Sync engine is attached to the app config by create_app() when
        # cloud credentials/config are available; sync loop no-ops safely
        # if it isn't.
        if app.config.get("SYNC_ENGINE"):
            start_sync_loop(app)
        else:
            log.warning("No SYNC_ENGINE configured — running offline-only, no cloud sync this run.")

        # Backup loop, relay client, and the update-check loop all no-op
        # internally until app/cloud_setup.py has paired this kiosk.
        start_backup_loop(app)
        start_relay_client(app)
        start_update_check_loop(app)

        self.host, self.port = host, port

        # waitress instead of Flask's dev server: the dev server logs a
        # loud "do not use in production" warning and isn't meant to take
        # untrusted traffic, which matters as soon as bind_mode is
        # "tunnel" or "public" (it's harmless but overkill for "local").
        serve(app, host=host, port=port, threads=8)

    def run_forever(self):
        consecutive_failures = 0
        while True:
            try:
                self._run_once()
                # app.run() returning normally means a clean shutdown was
                # requested somewhere — don't treat that as a crash.
                log.info("Server stopped cleanly.")
                return
            except Exception:
                consecutive_failures += 1
                log.exception(
                    "Embedded server crashed (failure #%d) — restarting in %ds.",
                    consecutive_failures, RESTART_BACKOFF_SECONDS,
                )
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    log.critical(
                        "Server crashed %d times in a row — giving up auto-restart.",
                        consecutive_failures,
                    )
                    raise
                time.sleep(RESTART_BACKOFF_SECONDS)
