"""
Crash-resilience supervisor for the embedded kiosk server.

Runs the Flask app (via waitress, a production WSGI server) in a
background thread. If that thread ever dies — an unhandled exception,
a crashed worker, anything — this loop notices within `POLL_SECONDS`
and starts a fresh one. This is the "minimize downtime" mechanism: it
works without a Windows Service install (no admin rights needed), which
matters because the whole point is a single .exe with zero setup.

Windows Service registration is a natural Part 4/5 addition for
customers who *do* want auto-start-on-boot without a logged-in user
session — this watchdog is the piece that makes that upgrade safe to
add later without changing the app itself.
"""
import logging
import threading
import time

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("watchdog")

POLL_SECONDS = 2
_MAX_RESTARTS_PER_MINUTE = 5


def _serve():
    from waitress import serve
    from app import create_app
    app = create_app()
    log.info("Embedded kiosk API starting on http://127.0.0.1:8420")
    serve(app, host="127.0.0.1", port=8420, threads=8)


class Supervisor:
    def __init__(self):
        self._thread: threading.Thread | None = None
        self._restart_times: list[float] = []
        self._stop = False

    def _spawn(self):
        self._thread = threading.Thread(target=self._run_guarded, daemon=True)
        self._thread.start()

    def _run_guarded(self):
        try:
            _serve()
        except Exception:
            log.exception("Embedded server thread crashed")

    def _too_many_restarts(self) -> bool:
        now = time.time()
        self._restart_times = [t for t in self._restart_times if now - t < 60]
        return len(self._restart_times) >= _MAX_RESTARTS_PER_MINUTE

    def run_forever(self):
        self._spawn()
        while not self._stop:
            time.sleep(POLL_SECONDS)
            if self._thread and not self._thread.is_alive():
                if self._too_many_restarts():
                    log.error(
                        "Embedded server crashed %d times in the last minute — "
                        "pausing 30s before trying again to avoid a crash loop.",
                        _MAX_RESTARTS_PER_MINUTE,
                    )
                    time.sleep(30)
                self._restart_times.append(time.time())
                log.warning("Embedded server is down — restarting it now.")
                self._spawn()

    def stop(self):
        self._stop = True


if __name__ == "__main__":
    Supervisor().run_forever()
