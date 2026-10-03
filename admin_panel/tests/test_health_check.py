"""
Real tests for agent/health_check.py — no mocking. Spins up an actual
HTTP server in a thread and toggles its response code, runs actual
subprocesses for the command-check path, and drives a real
ProcessSupervisor for the process-only fallback.

Run directly:
    python3 -m tests.test_health_check
or:
    python3 -m unittest tests.test_health_check -v
"""
import http.server
import os
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.config import AgentSettings
from agent.health_check import run_functional_check, run_health_check, check_structural
from agent.process_supervisor import ProcessSupervisor


class _ToggleableHandler(http.server.BaseHTTPRequestHandler):
    healthy = True

    def do_GET(self):
        if _ToggleableHandler.healthy:
            self.send_response(200)
        else:
            self.send_response(503)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass  # keep test output quiet


class _TestHttpServer:
    """A real HTTP server on a free local port, toggleable between healthy
    and unhealthy responses, running in a background thread."""

    def __init__(self):
        self.server = http.server.HTTPServer(("127.0.0.1", 0), _ToggleableHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        _ToggleableHandler.healthy = True
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()

    def set_healthy(self, healthy: bool):
        _ToggleableHandler.healthy = healthy

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}/health"


class TestHttpHealthCheck(unittest.TestCase):
    def setUp(self):
        self.server = _TestHttpServer()
        self.server.start()

    def tearDown(self):
        self.server.stop()

    def test_healthy_server_passes_immediately(self):
        settings = AgentSettings(kiosk_health_check_url=self.server.url)
        result = run_functional_check(settings, supervisor=None, retries=3, retry_delay_seconds=0.1)
        self.assertTrue(result.passed)
        self.assertEqual(result.method, "http")
        self.assertEqual(result.attempts, 1)

    def test_unhealthy_server_fails_after_exhausting_retries(self):
        self.server.set_healthy(False)
        settings = AgentSettings(kiosk_health_check_url=self.server.url)
        start = time.monotonic()
        result = run_functional_check(settings, supervisor=None, retries=3, retry_delay_seconds=0.2)
        elapsed = time.monotonic() - start
        self.assertFalse(result.passed)
        self.assertEqual(result.attempts, 3)
        self.assertIn("503", result.message)
        # 2 delays of 0.2s between 3 attempts should actually have elapsed —
        # proves this really retried rather than failing fast on attempt 1.
        self.assertGreaterEqual(elapsed, 0.35)

    def test_server_that_recovers_mid_retry_passes(self):
        self.server.set_healthy(False)

        def flip_healthy_after_delay():
            time.sleep(0.25)
            self.server.set_healthy(True)

        threading.Thread(target=flip_healthy_after_delay, daemon=True).start()
        settings = AgentSettings(kiosk_health_check_url=self.server.url)
        result = run_functional_check(settings, supervisor=None, retries=5, retry_delay_seconds=0.2)
        self.assertTrue(result.passed)
        self.assertGreater(result.attempts, 1)

    def test_unreachable_url_fails_with_connection_error_message(self):
        settings = AgentSettings(kiosk_health_check_url="http://127.0.0.1:1/health")
        result = run_functional_check(settings, supervisor=None, retries=1, retry_delay_seconds=0.1)
        self.assertFalse(result.passed)
        self.assertEqual(result.method, "http")

    def test_healthy_http_but_supervisor_says_process_dead_fails(self):
        # A stale HTTP response from something that isn't actually the
        # supervised process shouldn't be trusted over the supervisor.
        settings = AgentSettings(kiosk_health_check_url=self.server.url)
        supervisor = ProcessSupervisor("true", name="fake")  # 'true' exits immediately
        supervisor.start()
        time.sleep(0.3)  # let it actually exit
        self.assertFalse(supervisor.is_running())
        result = run_functional_check(settings, supervisor=supervisor, retries=1, retry_delay_seconds=0.1)
        self.assertFalse(result.passed)
        self.assertIn("not running", result.message)


class TestCommandHealthCheck(unittest.TestCase):
    def test_command_exit_zero_passes(self):
        settings = AgentSettings(kiosk_health_check_command="true")
        result = run_functional_check(settings, supervisor=None, retries=2, retry_delay_seconds=0.1)
        self.assertTrue(result.passed)
        self.assertEqual(result.method, "command")

    def test_command_exit_nonzero_fails(self):
        settings = AgentSettings(kiosk_health_check_command="false")
        result = run_functional_check(settings, supervisor=None, retries=2, retry_delay_seconds=0.1)
        self.assertFalse(result.passed)
        self.assertIn("exited 1", result.message)

    def test_command_timeout_fails(self):
        settings = AgentSettings(
            kiosk_health_check_command="sleep 2",
            health_check_timeout_seconds=0.2,
        )
        result = run_functional_check(settings, supervisor=None, retries=1, retry_delay_seconds=0.1)
        self.assertFalse(result.passed)
        self.assertIn("timed out", result.message)

    def test_url_takes_priority_over_command_when_both_set(self):
        server = _TestHttpServer()
        server.start()
        try:
            settings = AgentSettings(
                kiosk_health_check_url=server.url,
                kiosk_health_check_command="false",  # would fail if used
            )
            result = run_functional_check(settings, supervisor=None, retries=1, retry_delay_seconds=0.1)
            self.assertTrue(result.passed)
            self.assertEqual(result.method, "http")
        finally:
            server.stop()


class TestProcessOnlyFallback(unittest.TestCase):
    def test_no_check_configured_falls_back_to_process_liveness_running(self):
        settings = AgentSettings()  # no url/command
        supervisor = ProcessSupervisor("sleep 5", name="fake")
        supervisor.start()
        try:
            result = run_functional_check(settings, supervisor=supervisor, retries=1, retry_delay_seconds=0.1)
            self.assertTrue(result.passed)
            self.assertEqual(result.method, "process-only")
        finally:
            supervisor.stop()

    def test_no_check_configured_and_no_supervisor_reports_passed_but_honest(self):
        settings = AgentSettings()
        result = run_functional_check(settings, supervisor=None, retries=1, retry_delay_seconds=0.1)
        self.assertTrue(result.passed)
        self.assertIn("not checked", result.message)

    def test_no_check_configured_dead_process_fails(self):
        settings = AgentSettings()
        supervisor = ProcessSupervisor("true", name="fake")
        supervisor.start()
        time.sleep(0.3)
        result = run_functional_check(settings, supervisor=supervisor, retries=1, retry_delay_seconds=0.1)
        self.assertFalse(result.passed)
        self.assertEqual(result.method, "process-only")


class TestStructuralCheck(unittest.TestCase):
    def test_missing_dir_fails(self):
        ok, msg = check_structural("/nonexistent/path/for/real")
        self.assertFalse(ok)
        self.assertIn("does not exist", msg)

    def test_empty_dir_fails(self):
        with tempfile.TemporaryDirectory() as d:
            ok, msg = check_structural(d)
            self.assertFalse(ok)
            self.assertIn("empty", msg)

    def test_populated_dir_passes(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "app.py"), "w") as f:
                f.write("pass")
            ok, msg = check_structural(d)
            self.assertTrue(ok)


class TestFullHealthCheck(unittest.TestCase):
    def test_run_health_check_skips_functional_check_when_structural_fails(self):
        with tempfile.TemporaryDirectory() as d:
            empty_dir = os.path.join(d, "empty")
            os.makedirs(empty_dir)
            settings = AgentSettings(kiosk_health_check_url="http://127.0.0.1:1/health")
            result = run_health_check(empty_dir, settings, supervisor=None, retries=3, retry_delay_seconds=0.1)
            self.assertFalse(result.passed)
            self.assertEqual(result.method, "structural")

    def test_run_health_check_passes_when_both_pass(self):
        server = _TestHttpServer()
        server.start()
        try:
            with tempfile.TemporaryDirectory() as d:
                with open(os.path.join(d, "app.py"), "w") as f:
                    f.write("pass")
                settings = AgentSettings(kiosk_health_check_url=server.url)
                result = run_health_check(d, settings, supervisor=None, retries=2, retry_delay_seconds=0.1)
                self.assertTrue(result.passed)
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
