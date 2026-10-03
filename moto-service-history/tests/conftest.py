import os
import tempfile
import pytest

os.environ["SECRET_KEY"] = "test-secret"
os.environ["DEFAULT_ADMIN_PASSWORD"] = "changeme123"


@pytest.fixture
def app():
    db_fd, db_path = tempfile.mkstemp(suffix=".db")
    upload_dir = tempfile.mkdtemp()

    from app import create_app
    from app.config import Config

    class TestConfig(Config):
        SQLALCHEMY_DATABASE_URI = f"sqlite:///{db_path}"
        UPLOAD_FOLDER = upload_dir
        WTF_CSRF_ENABLED = False
        TESTING = True
        RATELIMIT_ENABLED = False

    application = create_app(TestConfig)
    yield application

    os.close(db_fd)
    os.unlink(db_path)


@pytest.fixture
def client(app):
    return app.test_client()


def register(client, username="rider", password="password123"):
    return client.post(
        "/auth/register",
        data={"username": username, "password": password, "confirm": password},
        follow_redirects=False,
    )


def login(client, username="rider", password="password123"):
    return client.post(
        "/auth/login",
        data={"username": username, "password": password},
        follow_redirects=False,
    )


def create_motorcycle(client, **overrides):
    data = {"make": "Triumph", "model": "Bonneville", "year": "2019", "mileage": "12000"}
    data.update(overrides)
    resp = client.post("/motorcycles/new", data=data, follow_redirects=False)
    moto_id = resp.headers["Location"].rstrip("/").split("/")[-1]
    return moto_id, resp
