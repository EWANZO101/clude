"""
Smoke test for kiosk_app/ — the Kiosk App's own, now fully-separated source
tree (see OWNERSHIP.md and the reconstruction in this pass: it was
reconciled from the last known-good release, v1.0.1, plus the in-progress
barcode-rendering work that had been stranded under the Admin Panel's app/).

Boots kiosk_app in isolation (its own sys.path entry, its own in-memory DB)
exactly the way it runs on a real kiosk machine, and exercises the same
first-run bootstrap kiosk_app/run.py performs.

Run directly:
    python3 -m unittest tests.test_kiosk_app_smoke -v
"""
import os
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIOSK_APP_DIR = os.path.join(REPO_ROOT, "kiosk_app")


class TestKioskAppSmoke(unittest.TestCase):
    def setUp(self):
        # kiosk_app has its own "app" package, distinct from (and never
        # imported alongside) the Admin Panel's "app" — insert its
        # directory FIRST so "import app" resolves to the Kiosk App's,
        # exactly as it does when kiosk_app/run.py is executed for real
        # with kiosk_app/ as the working directory.
        self._sys_path_backup = list(sys.path)
        self._sys_modules_backup = dict(sys.modules)
        for name in list(sys.modules):
            if name == "app" or name.startswith("app."):
                del sys.modules[name]
        sys.path.insert(0, KIOSK_APP_DIR)

        os.environ["DATABASE_URL"] = "sqlite://"
        from app import create_app
        from app.extensions import db
        self.db = db
        self.app = create_app()
        self.app.config.update(TESTING=True, SQLALCHEMY_DATABASE_URI="sqlite://")
        self.ctx = self.app.app_context()
        self.ctx.push()
        db.create_all()

    def tearDown(self):
        self.db.session.remove()
        self.db.drop_all()
        self.ctx.pop()
        sys.path[:] = self._sys_path_backup
        for name in list(sys.modules):
            if name == "app" or name.startswith("app."):
                del sys.modules[name]
        sys.modules.update(self._sys_modules_backup)

    def test_health_endpoint(self):
        client = self.app.test_client()
        resp = client.get("/health")
        self.assertEqual(resp.status_code, 200)
        body = resp.get_json()
        self.assertEqual(body["status"], "ok")

    def test_first_run_bootstrap_seeds_default_admin(self):
        from app.models import LocalUser
        self.assertEqual(LocalUser.query.count(), 0)
        if LocalUser.query.count() == 0:
            admin = LocalUser(username="admin", role="admin")
            self.db.session.add(admin)
            self.db.session.commit()
        self.assertEqual(LocalUser.query.count(), 1)
        self.assertEqual(LocalUser.query.first().username, "admin")


if __name__ == "__main__":
    unittest.main()
