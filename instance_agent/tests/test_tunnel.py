"""
Real tests for agent/tunnel.py. The poll loop, threading, and stop_event
behavior are real. client is a lightweight scripted stand-in — see
tests/test_rollback_integration.py's module docstring for why (no real
Admin Panel available in this build environment).

Run directly:
    python3 -m unittest tests.test_tunnel -v
"""
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.tunnel import run_tunnel_cycle, run_tunnel_poll_loop, _establish_tunnel
from agent.api_client import ApiError


class _FakeClient:
    def __init__(self):
        self.tunnel_requests = []   # queue of request dicts (or None) popped per get_tunnel_request call
        self.status_reports = []    # (tunnel_id, status, message)

    def get_tunnel_request(self):
        if not self.tunnel_requests:
            return {"request": None}
        return {"request": self.tunnel_requests.pop(0)}

    def report_tunnel_status(self, tunnel_id, status, message=None):
        self.status_reports.append((tunnel_id, status, message))
        return {"ok": True}


class _ErrorRaisingClient(_FakeClient):
    def get_tunnel_request(self):
        raise ApiError(404, {"error": "no such endpoint"})


class TestEstablishTunnelStub(unittest.TestCase):
    def test_stub_always_returns_false_with_an_honest_reason(self):
        established, message = _establish_tunnel({"id": "t1"})
        self.assertFalse(established)
        self.assertIn("not implemented", message.lower())


class TestRunTunnelCycle(unittest.TestCase):
    def test_no_request_pending_returns_false(self):
        client = _FakeClient()
        client.tunnel_requests.append(None)
        self.assertFalse(run_tunnel_cycle(client))
        self.assertEqual(client.status_reports, [])

    def test_request_present_reports_unsupported(self):
        client = _FakeClient()
        client.tunnel_requests.append({"id": "tunnel-abc"})
        seen = run_tunnel_cycle(client)
        self.assertTrue(seen)
        self.assertEqual(len(client.status_reports), 1)
        tunnel_id, status, message = client.status_reports[0]
        self.assertEqual(tunnel_id, "tunnel-abc")
        self.assertEqual(status, "unsupported")
        self.assertIsNotNone(message)

    def test_multiple_requests_across_cycles_each_reported(self):
        client = _FakeClient()
        client.tunnel_requests.extend([{"id": "t1"}, {"id": "t2"}, None])
        self.assertTrue(run_tunnel_cycle(client))
        self.assertTrue(run_tunnel_cycle(client))
        self.assertFalse(run_tunnel_cycle(client))
        ids = [r[0] for r in client.status_reports]
        self.assertEqual(ids, ["t1", "t2"])


class TestPollLoop(unittest.TestCase):
    def test_loop_runs_until_stop_event_and_processes_requests(self):
        client = _FakeClient()
        client.tunnel_requests.extend([{"id": "loop-t1"}, None, None, None, None])
        stop_event = threading.Event()

        t = threading.Thread(target=run_tunnel_poll_loop, args=(client, 0.05, stop_event), daemon=True)
        t.start()
        time.sleep(0.3)
        stop_event.set()
        t.join(timeout=2)

        self.assertFalse(t.is_alive())
        self.assertGreaterEqual(len(client.status_reports), 1)
        self.assertEqual(client.status_reports[0][0], "loop-t1")

    def test_loop_survives_endpoint_not_existing_on_admin_panel(self):
        # A real concern flagged in PROGRESS.txt: the Admin Panel may not
        # have this endpoint yet. The loop must not crash the thread.
        client = _ErrorRaisingClient()
        stop_event = threading.Event()

        t = threading.Thread(target=run_tunnel_poll_loop, args=(client, 0.05, stop_event), daemon=True)
        t.start()
        time.sleep(0.2)
        self.assertTrue(t.is_alive())  # still running despite every poll erroring
        stop_event.set()
        t.join(timeout=2)
        self.assertFalse(t.is_alive())


if __name__ == "__main__":
    unittest.main(verbosity=2)
