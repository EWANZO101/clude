"""
Regression test for the v1.0.2 incident (2026-09-08): a Kiosk App release
was uploaded that was actually a snapshot of the Admin Panel's own source
tree (admin_panel.db, migrations/, app/blueprints/agent_api.py and friends,
`class User` instead of `class LocalUser` in app/models.py). It passed
validate_update_zip's pre-existing checks (valid zip, update.json present
and version-matching, rescue/ present) and got pushed to two real
instances, breaking their Kiosk App until an automatic rollback recovered
them.

This test builds a minimal synthetic zip shaped exactly like that incident
and asserts app/update_validation.py::validate_update_zip now rejects it —
then builds a minimal *correctly*-shaped Kiosk package and asserts it's
still accepted, so the new content-firewall checks don't just reject
everything.

Run directly:
    python3 -m unittest tests.test_release_validation -v
"""
import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.update_validation import validate_update_zip


def _write_zip(path, files: dict):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, content in files.items():
            zf.writestr(name, content)


class TestReleaseValidationFirewall(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="release-validation-test-")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_admin_panel_snapshot_is_rejected(self):
        """Reproduces the actual v1.0.2 payload shape."""
        path = os.path.join(self.tmpdir, "bad.zip")
        _write_zip(path, {
            "update.json": '{"version": "1.0.2", "supported_os": ["windows"]}',
            "rescue/verify_install.py": "# rescue stub\n",
            "run.py": "from app import create_app\napp = create_app()\n",
            "admin_panel.db": "not really a sqlite file, doesn't matter",
            "migrations/env.py": "# alembic env\n",
            "app/models.py": "class User:\n    pass\n",
            "app/blueprints/agent_api.py": "# admin-only blueprint\n",
        })

        ok, errors, _ = validate_update_zip(path, expected_version="1.0.2")

        self.assertFalse(ok, "the Admin-Panel-shaped package must be rejected")
        joined = "\n".join(errors)
        self.assertIn("Admin Panel", joined)

    def test_minimal_real_kiosk_shape_is_accepted(self):
        path = os.path.join(self.tmpdir, "good.zip")
        _write_zip(path, {
            "update.json": '{"version": "1.0.3", "supported_os": ["windows"]}',
            "rescue/verify_install.py": "# rescue stub\n",
            "run.py": "from app import create_app\napp = create_app()\n",
            "requirements.txt": "Flask==3.0.3\n",
            "app/models.py": "class LocalUser:\n    pass\n",
            "app/__init__.py": "def create_app():\n    pass\n",
        })

        ok, errors, metadata = validate_update_zip(path, expected_version="1.0.3")

        self.assertTrue(ok, f"a real Kiosk-shaped package must validate cleanly, got: {errors}")
        self.assertEqual(metadata["version"], "1.0.3")
        self.assertTrue(metadata["has_rescue"])

    def test_wrong_top_level_entry_is_rejected(self):
        """Even without any Admin-Panel fingerprint, an unexpected top-level
        entry (something that isn't part of the Kiosk App's shape) is
        rejected — the allowlist, not just the denylist, does real work."""
        path = os.path.join(self.tmpdir, "extra.zip")
        _write_zip(path, {
            "update.json": '{"version": "1.0.3", "supported_os": ["windows"]}',
            "rescue/verify_install.py": "# rescue stub\n",
            "run.py": "from app import create_app\napp = create_app()\n",
            "app/models.py": "class LocalUser:\n    pass\n",
            "some_unrelated_top_level_dir/whatever.txt": "surprise",
        })

        ok, errors, _ = validate_update_zip(path, expected_version="1.0.3")

        self.assertFalse(ok)
        self.assertTrue(any("unexpected top-level" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
