"""
Real test that agent/heartbeat.py surfaces a real ProcessSupervisor's
status — the forward reference left in Part 3's process_supervisor.py
("status()['giving_up'] flags this for something upstream to surface
(Part 6's error reporting)"). Uses a real ProcessSupervisor against a real
subprocess, and a lightweight recording stand-in for the Admin Panel client
(no mocking of the supervisor or the process it manages).

Run directly:
    python3 -m unittest tests.test_heartbeat_supervisor_status -v
"""
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.heartbeat import send_heartbeat
from agent.process_supervisor import ProcessSupervisor


class _RecordingClient:
    def __init__(self):
        self.calls = []

    def heartbeat(self, **fields):
        self.calls.append(fields)
        return {"ok": True}


class TestHeartbeatSupervisorStatus(unittest.TestCase):
    def test_heartbeat_without_supervisor_has_no_supervisor_status_field(self):
        client = _RecordingClient()
        send_heartbeat(client, app_version="1.0.0", supervisor_status=None)
        self.assertNotIn("supervisor_status", client.calls[0])

    def test_heartbeat_with_running_supervisor_reports_running_true(self):
        client = _RecordingClient()
        supervisor = ProcessSupervisor("sleep 5", name="hb-test")
        supervisor.start()
        try:
            send_heartbeat(client, app_version="1.0.0", supervisor_status=supervisor.status())
        finally:
            supervisor.stop()

        status = client.calls[0]["supervisor_status"]
        self.assertTrue(status["running"])
        self.assertFalse(status["giving_up"])
        self.assertIsNotNone(status["pid"])

    def test_heartbeat_after_real_give_up_reports_giving_up_true(self):
        client = _RecordingClient()
        # 'false' exits immediately with a nonzero code every time — a
        # genuine crash loop, driving the watchdog to actually give up.
        supervisor = ProcessSupervisor(
            "false", name="hb-crash-test",
            restart_backoff_seconds=0.05, max_restarts_in_window=2, window_seconds=5.0,
        )
        supervisor.start()
        supervisor.start_watchdog(poll_interval=0.05)
        try:
            deadline = time.monotonic() + 5.0
            while not supervisor.status()["giving_up"] and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(supervisor.status()["giving_up"], "watchdog never gave up within timeout")

            send_heartbeat(client, app_version="1.0.0", supervisor_status=supervisor.status())
        finally:
            supervisor.stop_watchdog()
            supervisor.stop()

        status = client.calls[0]["supervisor_status"]
        self.assertTrue(status["giving_up"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
