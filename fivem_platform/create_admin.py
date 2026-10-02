"""
One-off script: creates all tables (if not already migrated) and
promotes/creates an admin+support user for first login.

Usage:
    python create_admin.py
"""
import os
import getpass
from dotenv import load_dotenv

_ENV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
load_dotenv(_ENV_PATH)

from app import create_app  # noqa: E402
from app.extensions import db  # noqa: E402
from app.models.user import User  # noqa: E402
from app.utils import (  # noqa: E402
    generate_user_id,
    generate_support_id,
    generate_api_identifier,
    generate_recovery_pin,
    hash_secret,
)

app = create_app(os.environ.get("FLASK_ENV", "development"))

with app.app_context():
    db.create_all()

    email = input("Admin email: ").strip().lower()
    existing = User.query.filter_by(email=email).first()

    if existing:
        existing.is_admin = True
        existing.is_support = True
        db.session.commit()
        print(f"Existing user {existing.username} promoted to admin/support.")
        print("Log in and visit /admin to manage the platform.")
    else:
        username = input("Admin username: ").strip()
        password = getpass.getpass("Admin password (min 10 chars): ")
        recovery_pin_raw = generate_recovery_pin()

        user = User(
            user_id=generate_user_id(),
            support_id=generate_support_id(),
            api_identifier=generate_api_identifier(),
            username=username,
            email=email,
            password_hash=hash_secret(password),
            recovery_pin_hash=hash_secret(recovery_pin_raw),
            is_admin=True,
            is_support=True,
        )
        db.session.add(user)
        db.session.commit()

        print("\nAdmin account created.")
        print(f"  User ID:      {user.user_id}")
        print(f"  Support ID:   {user.support_id}")
        print(f"  Recovery PIN: {recovery_pin_raw}  (shown once - save it)")
        print("\nLog in and visit /admin to manage the platform.")
