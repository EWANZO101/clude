import os

os.environ.setdefault(
    "TEST_DATABASE_URL",
    "postgresql://dedicated_sv:devpassword@localhost:5432/dedicated_sv_store_test",
)
os.environ["FLASK_ENV"] = "testing"

import pytest

from app import create_app
from app.extensions import db as _db
from app.utils.permissions import seed_roles_and_permissions
from app.models.user import User, AccountType, UserRole, Role
from app.models.customer import CustomerProfile


@pytest.fixture(scope="session")
def app():
    application = create_app("testing")
    with application.app_context():
        _db.create_all()
        seed_roles_and_permissions()
        yield application
        _db.session.remove()
        _db.drop_all()


SEED_TABLES = {"roles", "permissions", "role_permissions"}


@pytest.fixture(autouse=True)
def _session_rollback(app):
    with app.app_context():
        yield
        _db.session.rollback()
        for table in reversed(_db.metadata.sorted_tables):
            if table.name not in SEED_TABLES:
                _db.session.execute(table.delete())
        _db.session.commit()


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def make_user(app):
    def _make(email="user@example.com", password="Password123", account_type=AccountType.CUSTOMER, roles=None):
        user = User(email=email, account_type=account_type, is_active=True, is_email_verified=True)
        user.set_password(password)
        _db.session.add(user)
        _db.session.flush()
        if account_type == AccountType.CUSTOMER:
            _db.session.add(CustomerProfile(user_id=user.id))
        for role_name in roles or []:
            role = Role.query.filter_by(name=role_name).first()
            _db.session.add(UserRole(user_id=user.id, role_id=role.id))
        _db.session.commit()
        return user

    return _make


def login(client, email, password):
    return client.post(
        "/auth/login",
        data={"email": email, "password": password},
        follow_redirects=False,
    )
