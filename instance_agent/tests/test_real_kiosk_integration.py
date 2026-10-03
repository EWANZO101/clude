"""
Proves agent/process_supervisor.py, agent/health_check.py,
agent/update_manager.py, and agent/config_manager.py against the ACTUAL
Kiosk Application (see tests/fixtures/real_kiosk_app/), not a synthetic
test double. Every other test in this project that needed "a Kiosk
Application" honestly used a generic stand-in, because no real one existed
yet — see PROGRESS.txt. This is the first test in the whole Instance Agent
project that doesn't need that caveat.

REAL for real: package building from actual application source, checksum
verification, recovery point creation/restore, real installation, a real
ProcessSupervisor managing the real Kiosk Application as a real subprocess,
real HTTP health checks against its real /health endpoint, and — closing a
gap open since Part 1 — a real config file written by
agent/config_manager.py's apply_config() actually being read and reflected
by the real Kiosk Application's own home page, with no synthetic
middleman.

STUBBED, honestly, same as tests/test_rollback_integration.py: the Admin
Panel itself (see that file's docstring for why).

The "bad" deployment isn't a synthetic toggle — it's the real fixture's
main.py with one line changed to introduce an actual startup regression,
the same way a real bad deploy would happen.

Run directly:
    python3 -m unittest tests.test_real_kiosk_integration -v
"""
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import requests

from agent.config import AgentSettings
from agent.config_manager import apply_config
from agent.update_manager import run_update_cycle, read_local_version
from agent.process_supervisor import ProcessSupervisor

FIXTURE_KIOSK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "real_kiosk_app", "kiosk")


class _FakeAdminPanelClient:
    """Same role as tests/test_rollback_integration.py's version — see that
    file's docstring for why the Admin Panel itself is stubbed here."""

    def __init__(self, deployment_id, version, checksum, download_src_path):
        self._deployment_id = deployment_id
        self._version = version
        self._checksum = checksum
        self._download_src_path = download_src_path
        self.reported_statuses = []
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


def _sha256(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _build_real_package(zip_path: str, version: str, kiosk_src_dir: str) -> None:
    """Builds a real, validation-passing update package from actual Kiosk
    Application source (not a synthetic stand-in)."""
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("update.json", json.dumps({"version": version}))
        zf.writestr("rescue/rescue.sh", "#!/bin/sh\necho rescue\n")
        for root, _dirs, files in os.walk(kiosk_src_dir):
            for name in files:
                if name.endswith(".pyc") or "__pycache__" in root:
                    continue
                full = os.path.join(root, name)
                arcname = os.path.join("kiosk", os.path.relpath(full, kiosk_src_dir))
                zf.write(full, arcname)


def _make_broken_variant(dest_dir: str) -> None:
    """Copies the real fixture and introduces one real regression into
    main.py's startup path — an actual bug, not a toggle — the same kind
    of mistake a real bad deploy would ship."""
    shutil.copytree(FIXTURE_KIOSK_DIR, dest_dir)
    main_path = os.path.join(dest_dir, "main.py")
    with open(main_path, "r", encoding="utf-8") as f:
        content = f.read()

    marker = "def run(port: int, config_path: str, stop_event: threading.Event = None) -> None:"
    assert marker in content, "fixture main.py shape changed — update this test's injection point"
    content = content.replace(
        marker,
        marker + "\n    raise RuntimeError(\"simulated real regression introduced in this deploy\")",
    )
    with open(main_path, "w", encoding="utf-8") as f:
        f.write(content)


class TestRealKioskIntegration(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="opslab-real-kiosk-test-")
        self.port = self._free_port()
        self.settings = AgentSettings(
            app_install_dir=os.path.join(self.tmpdir, "app"),
            download_dir=os.path.join(self.tmpdir, "downloads"),
            recovery_dir=os.path.join(self.tmpdir, "recovery"),
            kiosk_config_path=os.path.join(self.tmpdir, "kiosk_config.json"),
            kiosk_health_check_url=f"http://127.0.0.1:{self.port}/health",
            kiosk_working_dir=os.path.join(self.tmpdir, "app"),
            kiosk_start_command=(
                f"{sys.executable} -m kiosk.main --port {self.port} "
                f"--config {os.path.join(self.tmpdir, 'kiosk_config.json')}"
            ),
            health_check_grace_period_seconds=0.8,
            health_check_retries=5,
            health_check_retry_delay_seconds=0.4,
        )
        self.supervisor = None

    def tearDown(self):
        if self.supervisor is not None:
            self.supervisor.stop()
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    @staticmethod
    def _free_port() -> int:
        import socket
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def _supervisor(self):
        if self.supervisor is None:
            self.supervisor = ProcessSupervisor(
                self.settings.kiosk_start_command,
                working_dir=self.settings.kiosk_working_dir,
                name="real-kiosk-app",
            )
        return self.supervisor

    def test_real_kiosk_app_deploys_and_serves_real_health_and_config(self):
        pkg_path = os.path.join(self.tmpdir, "v1.zip")
        _build_real_package(pkg_path, "1.0.0", FIXTURE_KIOSK_DIR)
        client = _FakeAdminPanelClient("dep-real-v1", "1.0.0", _sha256(pkg_path), pkg_path)

        ran = run_update_cycle(client, self.settings, self._supervisor())

        self.assertTrue(ran)
        statuses = [s for s, _, _ in client.reported_statuses]
        self.assertEqual(
            statuses,
            ["validating", "preparing", "installing", "restarting", "health_check", "successful"],
        )
        self.assertEqual(read_local_version(self.settings), "1.0.0")

        # Prove it's the REAL application answering, not a stand-in — hit
        # its actual endpoints over real HTTP.
        health = requests.get(self.settings.kiosk_health_check_url, timeout=2).json()
        self.assertEqual(health["status"], "healthy")
        self.assertEqual(health["version"], "1.0.0")

        home = requests.get(f"http://127.0.0.1:{self.port}/", timeout=2)
        self.assertIn("OpsLab Kiosk", home.text)  # the fixture's default store_name

    def test_config_sync_write_is_actually_read_by_the_real_kiosk_app(self):
        # Closes the gap Part 1's README stated explicitly:
        # "kiosk_config_path has no reader" — this is that reader, real,
        # actually running, actually picking up a real config write.
        pkg_path = os.path.join(self.tmpdir, "v1.zip")
        _build_real_package(pkg_path, "1.0.0", FIXTURE_KIOSK_DIR)
        client = _FakeAdminPanelClient("dep-config-test", "1.0.0", _sha256(pkg_path), pkg_path)
        run_update_cycle(client, self.settings, self._supervisor())

        # Simulate exactly what agent/config_manager.py does when the
        # Admin Panel pushes a new config: write it to kiosk_config_path.
        apply_config(
            {"store_name": "Integration Test Storefront", "display_message": "Live from a real config push"},
            self.settings.kiosk_config_path,
        )

        # The real Kiosk Application polls its config file every 5s by
        # default in production; give the test a moment, matching that
        # real behavior rather than mocking it away.
        import time
        deadline = time.monotonic() + 8.0
        seen = ""
        while time.monotonic() < deadline:
            resp = requests.get(f"http://127.0.0.1:{self.port}/", timeout=2)
            seen = resp.text
            if "Integration Test Storefront" in seen:
                break
            time.sleep(0.3)

        self.assertIn("Integration Test Storefront", seen)
        self.assertIn("Live from a real config push", seen)

    def test_a_real_regression_in_the_next_deploy_triggers_real_automatic_rollback(self):
        v1_path = os.path.join(self.tmpdir, "v1.zip")
        _build_real_package(v1_path, "1.0.0", FIXTURE_KIOSK_DIR)
        client1 = _FakeAdminPanelClient("dep-real-v1b", "1.0.0", _sha256(v1_path), v1_path)
        run_update_cycle(client1, self.settings, self._supervisor())
        self.assertEqual(read_local_version(self.settings), "1.0.0")

        broken_src = os.path.join(self.tmpdir, "kiosk_broken_src", "kiosk")
        _make_broken_variant(broken_src)
        v2_path = os.path.join(self.tmpdir, "v2.zip")
        _build_real_package(v2_path, "1.1.0", broken_src)
        client2 = _FakeAdminPanelClient("dep-real-v2-broken", "1.1.0", _sha256(v2_path), v2_path)

        ran = run_update_cycle(client2, self.settings, self._supervisor())

        self.assertTrue(ran)
        statuses = [s for s, _, _ in client2.reported_statuses]
        self.assertEqual(
            statuses,
            ["validating", "preparing", "installing", "restarting",
             "health_check", "rolling_back", "rolled_back"],
        )
        # Local version tracking reflects the real rollback, not the broken deploy.
        self.assertEqual(read_local_version(self.settings), "1.0.0")

        # And the actual process answering health checks right now is
        # genuinely the restored v1.0.0 — a real HTTP round trip, not an
        # assumption based on the reported status alone.
        health = requests.get(self.settings.kiosk_health_check_url, timeout=2).json()
        self.assertEqual(health["version"], "1.0.0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
