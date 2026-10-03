"""
End-to-end test of the Part 4 automatic-rollback flow, driving the real
run_update_cycle() function.

REAL for real: package building/validation, checksum verification, recovery
point creation/restore (agent/recovery.py, untouched from Part 2), install
(agent/installer.py), ProcessSupervisor starting/stopping/restarting actual
subprocesses (agent/process_supervisor.py, untouched from Part 3), and
health checks making actual HTTP requests to actual running servers
(agent/health_check.py). Nothing in the local-machine path is mocked.

STUBBED, honestly: the Admin Panel itself. Unlike Parts 1-3 (built in an
environment with the actual Admin Panel checked out and run as a real HTTP
server), this build environment does not have the Admin Panel project
available to run against. `_FakeAdminPanelClient` below stands in for
ApiClient — it returns a scripted deployment and records every
report_update_status() call — but it is not a real server and this test
does not exercise real HTTP against a real Admin Panel the way Parts 1-3
were verified. That gap is called out again in PROGRESS.txt rather than
left implicit.

Run directly:
    python3 -m unittest tests.test_rollback_integration -v
"""
import json
import os
import shutil
import sys
import tempfile
import textwrap
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.config import AgentSettings
from agent.update_manager import run_update_cycle, read_local_version
from agent.process_supervisor import ProcessSupervisor


KIOSK_SERVER_TEMPLATE = textwrap.dedent("""
    import http.server
    import sys

    HEALTHY = {healthy}
    PORT = {port}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if HEALTHY:
                self.send_response(200)
            else:
                self.send_response(500)
            self.end_headers()
        def log_message(self, *a):
            pass

    if not HEALTHY and {crash_instead_of_serve}:
        sys.exit(1)  # simulate a version that crashes immediately on startup

    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
""")


class _FakeAdminPanelClient:
    """Stands in for agent.api_client.ApiClient — see module docstring for
    why a real Admin Panel isn't used here. Scripted with one deployment;
    records every status transition reported so the test can assert on the
    exact sequence the real Admin Panel would have received."""

    def __init__(self, deployment_id, version, checksum, download_src_path):
        self._deployment_id = deployment_id
        self._version = version
        self._checksum = checksum
        self._download_src_path = download_src_path
        self.reported_statuses = []  # list of (status, message, health_check_passed)
        self._served = False

    def get_current_update(self):
        if self._served:
            return {"deployment": None}
        return {
            "deployment": {
                "id": self._deployment_id,
                "due": True,
                "status": "waiting",
                "package": {
                    "version": self._version,
                    "checksum_sha256": self._checksum,
                    "download_url": "/fake/download",
                },
            }
        }

    def download_update(self, download_url, dest_path):
        shutil.copy2(self._download_src_path, dest_path)
        self._served = True

    def report_update_status(self, deployment_id, status, message=None, health_check_passed=None):
        self.reported_statuses.append((status, message, health_check_passed))
        return {"ok": True}


def _build_package(zip_path: str, version: str, port: int, healthy: bool,
                    crash_instead_of_serve: bool = False):
    """Builds a real, validation-passing update package whose app is a
    tiny real HTTP server bound to `port`, serving 200 (healthy) or 500
    (unhealthy), or exiting immediately (crash_instead_of_serve)."""
    server_code = KIOSK_SERVER_TEMPLATE.format(
        healthy=healthy, port=port, crash_instead_of_serve=crash_instead_of_serve,
    )
    manifest = {"version": version}
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("update.json", json.dumps(manifest))
        zf.writestr("server.py", server_code)
        zf.writestr("rescue/rescue.sh", "#!/bin/sh\necho rescue\n")


def _sha256(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


class TestAutomaticRollback(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="opslab-rollback-test-")
        self.settings = AgentSettings(
            app_install_dir=os.path.join(self.tmpdir, "app"),
            download_dir=os.path.join(self.tmpdir, "downloads"),
            recovery_dir=os.path.join(self.tmpdir, "recovery"),
            health_check_grace_period_seconds=0.6,
            health_check_retries=4,
            health_check_retry_delay_seconds=0.3,
        )
        self.port = self._free_port()
        self.settings.kiosk_health_check_url = f"http://127.0.0.1:{self.port}/health"
        self.supervisor = None

    def tearDown(self):
        if self.supervisor is not None:
            self.supervisor.stop()
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    @staticmethod
    def _free_port():
        import socket
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def _make_supervisor(self):
        # One supervisor instance persists across deployments within a
        # test, same as main.py does in real operation (a fresh
        # ProcessSupervisor per update cycle would lose track of the
        # process it already started, exactly the kind of bug this harness
        # would otherwise mask rather than catch).
        if self.supervisor is None:
            cmd = f"python3 {os.path.join(self.settings.resolve_app_install_dir(), 'server.py')}"
            self.supervisor = ProcessSupervisor(cmd, name="kiosk-app-under-test")
        return self.supervisor

    def _run_deployment(self, version, healthy, crash_instead_of_serve=False, deployment_id="dep-1"):
        pkg_path = os.path.join(self.tmpdir, f"{deployment_id}.zip")
        _build_package(pkg_path, version, self.port, healthy, crash_instead_of_serve)
        client = _FakeAdminPanelClient(deployment_id, version, _sha256(pkg_path), pkg_path)
        supervisor = self._make_supervisor()
        ran = run_update_cycle(client, self.settings, supervisor)
        return client, ran

    def test_healthy_deployment_reports_successful_and_writes_version(self):
        client, ran = self._run_deployment("1.0.0", healthy=True, deployment_id="dep-good")
        self.assertTrue(ran)
        statuses = [s for s, _, _ in client.reported_statuses]
        self.assertEqual(
            statuses,
            ["validating", "preparing", "installing", "restarting", "health_check", "successful"],
        )
        self.assertTrue(client.reported_statuses[-2][2])  # health_check_passed=True
        self.assertEqual(read_local_version(self.settings), "1.0.0")
        self.assertTrue(self.supervisor.is_running())

    def test_failed_deployment_with_no_prior_version_rolls_back_to_nothing(self):
        # First-ever deployment on a fresh machine fails health check —
        # rollback restores to "nothing was installed", which is the
        # honest correct outcome, not a crash.
        client, ran = self._run_deployment(
            "1.0.0", healthy=False, crash_instead_of_serve=True, deployment_id="dep-first-bad",
        )
        self.assertTrue(ran)
        statuses = [s for s, _, _ in client.reported_statuses]
        self.assertIn("health_check", statuses)
        self.assertIn("rolling_back", statuses)
        # Rollback restores to an empty app dir (nothing existed before) —
        # its own health check (structural) fails too, honestly, since
        # there's truly nothing to roll back TO.
        self.assertEqual(statuses[-1], "failed")
        self.assertIsNone(read_local_version(self.settings))

    def test_upgrade_that_fails_health_check_rolls_back_to_previous_good_version(self):
        # Deploy a genuinely good v1 first.
        client1, _ = self._run_deployment("1.0.0", healthy=True, deployment_id="dep-v1")
        self.assertEqual(read_local_version(self.settings), "1.0.0")
        self.assertTrue(self.supervisor.is_running())

        # Now "deploy" v2, which crashes on startup — this must trigger a
        # real automatic rollback back onto v1's actual files, restarted,
        # and re-verified healthy over real HTTP before being called done.
        client2, ran = self._run_deployment(
            "2.0.0", healthy=False, crash_instead_of_serve=True, deployment_id="dep-v2-bad",
        )
        self.assertTrue(ran)
        statuses = [s for s, _, _ in client2.reported_statuses]
        self.assertEqual(
            statuses,
            ["validating", "preparing", "installing", "restarting",
             "health_check", "rolling_back", "rolled_back"],
        )
        self.assertFalse(client2.reported_statuses[4][2])  # health_check for v2: passed=False
        # Local version tracking must reflect the ROLLED-BACK version, not
        # the failed v2 — this is what makes the next heartbeat honest.
        self.assertEqual(read_local_version(self.settings), "1.0.0")
        # And the process actually running right now must really be v1's
        # server, proven the same way Part 3 proved restarts: a real HTTP
        # 200 from the real restored process, not just "install succeeded".
        self.assertTrue(self.supervisor.is_running())
        import requests
        resp = requests.get(self.settings.kiosk_health_check_url, timeout=2)
        self.assertEqual(resp.status_code, 200)

    def test_upgrade_that_serves_500_instead_of_crashing_also_rolls_back(self):
        # A process that stays up but answers unhealthy is a different
        # failure mode than a crash — must be caught and rolled back too.
        self._run_deployment("1.0.0", healthy=True, deployment_id="dep-v1b")
        client2, ran = self._run_deployment(
            "2.0.0", healthy=False, crash_instead_of_serve=False, deployment_id="dep-v2-500",
        )
        statuses = [s for s, _, _ in client2.reported_statuses]
        self.assertIn("rolling_back", statuses)
        self.assertEqual(statuses[-1], "rolled_back")
        self.assertEqual(read_local_version(self.settings), "1.0.0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
