"""
Regression test for tests/_db_test_helpers.py itself — the safety net added
after a test dropped every table in the real production database (see that
module's docstring for the incident). Asserts the guard actually fires
instead of silently passing.

Run directly:
    python3 -m unittest tests.test_db_test_helpers -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests._db_test_helpers import make_test_app, TestConfig, REAL_DB_PATH


class RealDbConfig(TestConfig):
    """Deliberately reproduces the exact mistake this helper exists to
    catch: a config that resolves to the real database file."""
    SQLALCHEMY_DATABASE_URI = f"sqlite:///{REAL_DB_PATH}"


class TestDbTestHelperSafety(unittest.TestCase):
    def test_default_config_is_in_memory_not_real_file(self):
        app, db = make_test_app()
        with app.app_context():
            self.assertIsNone(db.engine.url.database)  # in-memory sqlite has no file

    def test_pointing_at_the_real_db_raises_instead_of_proceeding(self):
        with self.assertRaises(RuntimeError):
            make_test_app(config_class=RealDbConfig)


if __name__ == "__main__":
    unittest.main()
