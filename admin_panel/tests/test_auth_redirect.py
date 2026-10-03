"""
Regression test for an open-redirect found in app/blueprints/auth.py:
login() and pin_setup() did `redirect(request.args.get("next") or ...)`
with no validation, so `/auth/login?next=https://evil.example` would send
a just-authenticated user off-site — a classic post-login phishing vector.
Fixed with app/blueprints/auth.py::_safe_next_url, which only allows a
same-site relative path through.

Uses tests/_db_test_helpers.py::make_test_app — see that module's docstring
for why (an earlier version of this exact test used
`app.config.update(SQLALCHEMY_DATABASE_URI=...)` after create_app(), which
silently had no effect and caused this test to drop every table in the
real production database).

Run directly:
    python3 -m unittest tests.test_auth_redirect -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests._db_test_helpers import make_test_app
from app.models import User


class TestAuthRedirect(unittest.TestCase):
    def setUp(self):
        self.app, db = make_test_app()
        self.db = db
        self.ctx = self.app.app_context()
        self.ctx.push()
        db.create_all()

        self.user = User(email="tester@example.com", full_name="Tester", email_verified=True)
        self.user.set_password("correct horse battery staple")
        db.session.add(self.user)
        db.session.commit()

        self.client = self.app.test_client()

    def tearDown(self):
        self.db.session.remove()
        self.db.drop_all()
        self.ctx.pop()

    def _login(self, next_url):
        return self.client.post(
            f"/auth/login?next={next_url}",
            data={"email": "tester@example.com", "password": "correct horse battery staple"},
            follow_redirects=False,
        )

    def test_offsite_next_is_ignored(self):
        resp = self._login("https://evil.example/steal-session")
        self.assertEqual(resp.status_code, 302)
        self.assertNotIn("evil.example", resp.headers["Location"])

    def test_protocol_relative_next_is_ignored(self):
        resp = self._login("//evil.example/steal-session")
        self.assertEqual(resp.status_code, 302)
        self.assertNotIn("evil.example", resp.headers["Location"])

    def test_relative_next_still_works(self):
        resp = self._login("/companies/")
        self.assertEqual(resp.status_code, 302)
        self.assertTrue(resp.headers["Location"].endswith("/companies/"))


if __name__ == "__main__":
    unittest.main()
