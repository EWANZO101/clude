import os
from dotenv import load_dotenv

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
load_dotenv(os.path.join(BASE_DIR, ".env"))


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-key-change-me")
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{BASE_DIR}/instance/claude_manager.db"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
    ADMIN_PASS = os.environ.get("ADMIN_PASS", "admin")
    CLAUDE_HOMES_DIR = os.environ.get(
        "CLAUDE_HOMES_DIR", os.path.join(BASE_DIR, "claude_homes")
    )
    LOG_DIR = os.environ.get("LOG_DIR", os.path.join(BASE_DIR, "logs"))
    PORT = int(os.environ.get("PORT", 5057))
    # Linux usernames a session is allowed to run as via the scoped sudo rule
    # (comma-separated). Empty by default — no cross-user execution unless
    # explicitly enabled.
    ALLOWED_OS_USERS = [
        u.strip() for u in os.environ.get("ALLOWED_OS_USERS", "").split(",") if u.strip()
    ]
