"""
Error reporting (spec Section 2.2's "Error reporting" line item, and the
forward reference left in Part 3's process_supervisor.py: "status()
['giving_up'] flags this for something upstream to surface"). Ships
ERROR/CRITICAL log records — from anywhere in the Agent, not just this
module — to the Admin Panel, so an operator can see a machine is in trouble
without needing to SSH/RDP in and read local logs.

Three things make a "report every error over the network" handler
dangerous if done naively, all handled deliberately here:

  1. Recursion: reporting an error over HTTP can itself fail and log an
     error (e.g. requests' own logger, or agent.api_client on a connection
     failure) — which would try to report itself, forever. A re-entrancy
     guard (thread-local) makes emit() a no-op for anything logged while
     emit() is already running.
  2. Storms: a genuinely broken machine can produce hundreds of identical
     errors a minute (e.g. every heartbeat failing the same way). Rate
     limiting (max reports per window) and de-duplication (an identical
     logger+message within a short window collapses to one) keep this from
     turning a local problem into a self-inflicted network/Admin-Panel
     load problem.
  3. Reporting failures must never raise or block: emit() catches
     everything. A network blip while trying to report a network blip is
     not itself worth doing anything about.
"""
import logging
import threading
import time
import traceback as tb_module

from agent.api_client import ApiClient, ApiError

log = logging.getLogger("agent.error_reporter")

DEFAULT_MAX_REPORTS_PER_WINDOW = 10
DEFAULT_WINDOW_SECONDS = 60.0
DEFAULT_DEDUP_SECONDS = 30.0


class ErrorReportingHandler(logging.Handler):
    """Attach to the root logger (or any logger) with addHandler(). Every
    record at level >= ERROR that reaches this handler is queued for
    best-effort delivery to the Admin Panel via client.report_error()."""

    def __init__(self, client: ApiClient,
                 max_reports_per_window: int = DEFAULT_MAX_REPORTS_PER_WINDOW,
                 window_seconds: float = DEFAULT_WINDOW_SECONDS,
                 dedup_seconds: float = DEFAULT_DEDUP_SECONDS,
                 level=logging.ERROR):
        super().__init__(level=level)
        self.client = client
        self.max_reports_per_window = max_reports_per_window
        self.window_seconds = window_seconds
        self.dedup_seconds = dedup_seconds

        self._lock = threading.Lock()
        self._report_timestamps = []          # for the rolling rate limit
        self._recent = {}                     # (logger, message) -> last-sent monotonic time
        self._in_emit = threading.local()      # re-entrancy guard, per thread
        self._suppressed_since_report = 0      # how many were dropped by rate-limit/dedup

    def emit(self, record: logging.LogRecord) -> None:
        if getattr(self._in_emit, "active", False):
            return  # a report attempt itself logged an error — drop it, don't recurse
        self._in_emit.active = True
        try:
            self._try_emit(record)
        except Exception:
            pass  # never let error reporting itself raise into the logging system
        finally:
            self._in_emit.active = False

    def _try_emit(self, record: logging.LogRecord) -> None:
        message = record.getMessage()
        now = time.monotonic()

        with self._lock:
            key = (record.name, message)
            last_sent = self._recent.get(key)
            if last_sent is not None and (now - last_sent) < self.dedup_seconds:
                self._suppressed_since_report += 1
                return  # identical error from the same logger, too recent — collapse it

            self._report_timestamps = [t for t in self._report_timestamps if now - t < self.window_seconds]
            if len(self._report_timestamps) >= self.max_reports_per_window:
                self._suppressed_since_report += 1
                return  # storming — stop shipping individual reports until the window clears

            self._report_timestamps.append(now)
            self._recent[key] = now
            suppressed = self._suppressed_since_report
            self._suppressed_since_report = 0

        exc_text = None
        if record.exc_info:
            exc_text = "".join(tb_module.format_exception(*record.exc_info))

        try:
            self.client.report_error(
                level=record.levelname,
                logger_name=record.name,
                message=message,
                traceback=exc_text,
                suppressed_since_last=suppressed,
            )
        except ApiError:
            pass  # Admin Panel rejected it (e.g. not registered yet) — nothing more to do
        except Exception:
            pass  # network/timeout/etc — this is best-effort, never worth raising further


def install(client: ApiClient, logger_name: str = "agent",
            max_reports_per_window: int = DEFAULT_MAX_REPORTS_PER_WINDOW,
            window_seconds: float = DEFAULT_WINDOW_SECONDS,
            dedup_seconds: float = DEFAULT_DEDUP_SECONDS) -> ErrorReportingHandler:
    """Attaches an ErrorReportingHandler to the 'agent' logger (the parent
    of every agent.* logger in this project, per Python logging's
    hierarchical propagation — attaching here catches all of them without
    needing every module to know reporting exists). Returns the handler so
    callers can remove it later (e.g. in tests, or on shutdown)."""
    handler = ErrorReportingHandler(
        client, max_reports_per_window=max_reports_per_window,
        window_seconds=window_seconds, dedup_seconds=dedup_seconds,
    )
    logging.getLogger(logger_name).addHandler(handler)
    return handler
