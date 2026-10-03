"""
Real tests for agent/error_reporter.py. The logging system itself is real
(actual logging.Logger, actual propagation) — only the network call
(client.report_error) is a lightweight recording stub, since there's no
real Admin Panel error-ingestion endpoint to hit in this build environment
(see PROGRESS.txt).

Run directly:
    python3 -m unittest tests.test_error_reporter -v
"""
import logging
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.error_reporter import ErrorReportingHandler, install
from agent.api_client import ApiError


class _RecordingClient:
    """Stands in for ApiClient.report_error — see module docstring."""

    def __init__(self, raise_on_call: Exception = None):
        self.calls = []
        self.raise_on_call = raise_on_call
        self.lock = threading.Lock()

    def report_error(self, level, logger_name, message, traceback=None, suppressed_since_last=0):
        with self.lock:
            self.calls.append({
                "level": level, "logger_name": logger_name, "message": message,
                "traceback": traceback, "suppressed_since_last": suppressed_since_last,
            })
        if self.raise_on_call:
            raise self.raise_on_call


class TestBasicReporting(unittest.TestCase):
    def setUp(self):
        self.logger = logging.getLogger("agent.test_error_reporter")
        self.logger.setLevel(logging.DEBUG)
        self.client = _RecordingClient()
        self.handler = ErrorReportingHandler(self.client, dedup_seconds=0.05, window_seconds=1.0,
                                              max_reports_per_window=100)
        self.logger.addHandler(self.handler)

    def tearDown(self):
        self.logger.removeHandler(self.handler)

    def test_error_level_is_reported(self):
        self.logger.error("something broke")
        self.assertEqual(len(self.client.calls), 1)
        self.assertEqual(self.client.calls[0]["level"], "ERROR")
        self.assertEqual(self.client.calls[0]["message"], "something broke")

    def test_warning_level_is_not_reported_by_default(self):
        self.logger.warning("minor thing")
        self.assertEqual(len(self.client.calls), 0)

    def test_info_level_is_not_reported(self):
        self.logger.info("just fyi")
        self.assertEqual(len(self.client.calls), 0)

    def test_critical_is_reported(self):
        self.logger.critical("very broke")
        self.assertEqual(len(self.client.calls), 1)
        self.assertEqual(self.client.calls[0]["level"], "CRITICAL")

    def test_exception_includes_traceback(self):
        try:
            raise ValueError("boom")
        except ValueError:
            self.logger.exception("caught something")
        self.assertEqual(len(self.client.calls), 1)
        self.assertIn("ValueError: boom", self.client.calls[0]["traceback"])


class TestDeduplication(unittest.TestCase):
    def setUp(self):
        self.logger = logging.getLogger("agent.test_error_reporter_dedup")
        self.logger.setLevel(logging.DEBUG)
        self.client = _RecordingClient()
        self.handler = ErrorReportingHandler(self.client, dedup_seconds=0.3, window_seconds=5.0,
                                              max_reports_per_window=100)
        self.logger.addHandler(self.handler)

    def tearDown(self):
        self.logger.removeHandler(self.handler)

    def test_identical_message_within_window_is_collapsed(self):
        for _ in range(5):
            self.logger.error("repeated failure")
        self.assertEqual(len(self.client.calls), 1)
        self.assertEqual(self.client.calls[0]["suppressed_since_last"], 0)

    def test_repeat_after_dedup_window_sends_again_with_suppressed_count(self):
        self.logger.error("repeated failure")
        self.logger.error("repeated failure")  # suppressed
        self.logger.error("repeated failure")  # suppressed
        time.sleep(0.35)  # let the dedup window pass
        self.logger.error("repeated failure")
        self.assertEqual(len(self.client.calls), 2)
        self.assertEqual(self.client.calls[1]["suppressed_since_last"], 2)

    def test_different_messages_are_not_deduped(self):
        self.logger.error("failure A")
        self.logger.error("failure B")
        self.assertEqual(len(self.client.calls), 2)


class TestRateLimiting(unittest.TestCase):
    def setUp(self):
        self.logger = logging.getLogger("agent.test_error_reporter_rate")
        self.logger.setLevel(logging.DEBUG)
        self.client = _RecordingClient()
        # dedup effectively off (unique messages), tiny window+cap so the
        # storm scenario is exercised quickly
        self.handler = ErrorReportingHandler(self.client, dedup_seconds=0.001,
                                              window_seconds=1.0, max_reports_per_window=3)
        self.logger.addHandler(self.handler)

    def tearDown(self):
        self.logger.removeHandler(self.handler)

    def test_storm_of_unique_errors_is_capped_per_window(self):
        for i in range(20):
            self.logger.error("unique failure #%d", i)
        self.assertEqual(len(self.client.calls), 3)

    def test_window_clears_after_it_elapses(self):
        for i in range(3):
            self.logger.error("burst A #%d", i)
        self.assertEqual(len(self.client.calls), 3)
        time.sleep(1.1)
        self.logger.error("after the window")
        self.assertEqual(len(self.client.calls), 4)


class TestRecursionSafety(unittest.TestCase):
    def test_a_reporting_failure_that_itself_logs_does_not_recurse_forever(self):
        logger = logging.getLogger("agent.test_error_reporter_recursion")
        logger.setLevel(logging.DEBUG)

        class _SelfLoggingClient:
            def __init__(self):
                self.attempts = 0

            def report_error(self, **kwargs):
                self.attempts += 1
                # Simulate a broken reporting path that itself logs an
                # error via the *same* logger — this must not recurse.
                logger.error("reporting itself failed")
                raise ApiError(500, {"error": "boom"})

        client = _SelfLoggingClient()
        handler = ErrorReportingHandler(client, dedup_seconds=0.001, window_seconds=5.0,
                                         max_reports_per_window=100)
        logger.addHandler(handler)
        try:
            logger.error("original failure")
        finally:
            logger.removeHandler(handler)

        # Exactly one outer attempt — the nested log.error() inside
        # report_error() must have been dropped by the re-entrancy guard,
        # not triggered a second (or infinite) round of reporting.
        self.assertEqual(client.attempts, 1)

    def test_emit_never_raises_even_when_client_is_broken(self):
        logger = logging.getLogger("agent.test_error_reporter_broken_client")
        logger.setLevel(logging.DEBUG)

        class _BrokenClient:
            def report_error(self, **kwargs):
                raise RuntimeError("network is on fire")

        handler = ErrorReportingHandler(_BrokenClient(), dedup_seconds=0.001, window_seconds=5.0)
        logger.addHandler(handler)
        try:
            logger.error("this should not raise out of the logging call")
        finally:
            logger.removeHandler(handler)
        # Reaching here at all is the assertion — a raise would fail the test.


class TestInstallHelper(unittest.TestCase):
    def test_install_attaches_to_parent_agent_logger_and_catches_children(self):
        client = _RecordingClient()
        handler = install(client, logger_name="agent.test_install_parent",
                           dedup_seconds=0.001, window_seconds=5.0)
        child_logger = logging.getLogger("agent.test_install_parent.child_module")
        child_logger.setLevel(logging.DEBUG)
        try:
            child_logger.error("error from a child logger")
        finally:
            logging.getLogger("agent.test_install_parent").removeHandler(handler)

        self.assertEqual(len(client.calls), 1)
        self.assertEqual(client.calls[0]["logger_name"], "agent.test_install_parent.child_module")


if __name__ == "__main__":
    unittest.main(verbosity=2)
