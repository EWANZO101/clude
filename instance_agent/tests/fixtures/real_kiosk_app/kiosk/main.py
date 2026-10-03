"""
OpsLab Kiosk Application — the actual application the Instance Agent
supervises, health-checks, and updates. Until this project existed, every
part of the Instance Agent that depended on a Kiosk Application (process
supervision, health checks, config sync's reader) was built and tested
against generic stand-ins, with that gap stated honestly throughout. This
is that missing piece, built to match exactly what the Instance Agent
expects:

  - A long-running foreground process (so agent.process_supervisor can
    manage it as a subprocess: start/stop/restart, detect an unexpected
    exit).
  - Exits cleanly on SIGTERM/SIGINT (so ProcessSupervisor.stop() doesn't
    need to escalate to SIGKILL on every normal restart).
  - Serves a real HTTP health endpoint (so agent.health_check's
    kiosk_health_check_url has something real to GET instead of falling
    back to process-liveness only).
  - Reads its config from the path the Instance Agent's config_manager.py
    writes to (kiosk_config_path), and picks up changes without a restart.

Usage:
    python -m kiosk.main --port 8090 --config /etc/opslab-agent/kiosk_config.json

Or via environment variables (what the Instance Agent's kiosk_start_command
would actually invoke in production):
    KIOSK_PORT=8090 KIOSK_CONFIG_PATH=/etc/opslab-agent/kiosk_config.json python -m kiosk.main
"""
import argparse
import html
import http.server
import json
import logging
import os
import signal
import sys
import threading

from kiosk import __version__
from kiosk.config import KioskConfig

log = logging.getLogger("kiosk.main")


def _make_handler(config: KioskConfig):
    class Handler(http.server.BaseHTTPRequestHandler):
        def _write_json(self, code: int, payload: dict):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                # A real functional check: confirms this process can still
                # read its own config, not just that the socket accepts
                # connections. Exactly the kind of check agent/health_check.py's
                # kiosk_health_check_url is meant to hit.
                try:
                    config.reload()
                    self._write_json(200, {"status": "healthy", "version": __version__})
                except Exception as e:  # pragma: no cover - defensive
                    self._write_json(500, {"status": "unhealthy", "error": str(e)})
                return

            if self.path == "/":
                snap = config.snapshot()
                body = (
                    "<html><head><title>{store}</title></head><body>"
                    "<h1>{store}</h1><p>{message}</p>"
                    "<p><small>OpsLab Kiosk v{version}</small></p>"
                    "</body></html>"
                ).format(
                    store=html.escape(str(snap.get("store_name"))),
                    message=html.escape(str(snap.get("display_message"))),
                    version=__version__,
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            self._write_json(404, {"error": "not found"})

        def log_message(self, fmt, *args):
            log.debug("%s - %s", self.address_string(), fmt % args)

    return Handler


def run(port: int, config_path: str, stop_event: threading.Event = None) -> None:
    logging.basicConfig(
        level=os.environ.get("KIOSK_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
    )

    config = KioskConfig(config_path)
    config.start_polling(interval_seconds=5.0)

    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), _make_handler(config))
    server_thread = threading.Thread(target=server.serve_forever, name="http", daemon=True)
    server_thread.start()
    log.info("Kiosk Application v%s listening on :%d (config=%s)", __version__, port, config_path)

    stop_event = stop_event or threading.Event()

    if threading.current_thread() is threading.main_thread():
        def handle_signal(signum, frame):
            log.info("Received signal %s, shutting down...", signum)
            stop_event.set()
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)

    stop_event.wait()
    log.info("Shutting down...")
    config.stop_polling()
    server.shutdown()
    server.server_close()
    log.info("Kiosk Application stopped.")


def main(argv=None):
    parser = argparse.ArgumentParser(description="OpsLab Kiosk Application")
    parser.add_argument("--port", type=int, default=int(os.environ.get("KIOSK_PORT", "8090")))
    parser.add_argument("--config", default=os.environ.get("KIOSK_CONFIG_PATH", ""))
    args = parser.parse_args(argv)
    run(args.port, args.config)


if __name__ == "__main__":
    main()
