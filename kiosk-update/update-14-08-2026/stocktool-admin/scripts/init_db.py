"""
init_db.py — run once to create all tables and set up the first admin user.
    python scripts/init_db.py
"""
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app import create_app
from app.extensions import db
from app.models import User, Role, AuditLog, AuditAction, Settings
from app.utils.barcode_helper import generate_barcode


def create_admin(username: str, email: str, password: str) -> User:
    user = User(
        username=username, email=email, role=Role.ADMIN,
        is_active=True, force_password_change=False,
    )
    user.set_password(password)
    db.session.add(user)
    db.session.flush()

    generate_barcode("user", user.id)

    log = AuditLog(
        user_id=user.id, action=AuditAction.SYSTEM_INIT,
        entity_type="user", entity_id=user.id, entity_name=user.username,
        detail="Initial admin account created by installer.",
    )
    db.session.add(log)
    db.session.commit()
    return user


def main():
    app = create_app()

    with app.app_context():
        print("Creating database tables...")
        db.create_all()
        Settings.get()
        print("Tables created.")

        existing_admin = User.query.filter_by(role=Role.ADMIN).first()
        if existing_admin:
            print(f"Admin user already exists: {existing_admin.username}")
            print("Skipping admin creation. Use the admin website to manage users.")
            return

        print("\n=== First-run Admin Setup ===")
        username = input("Admin username [admin]: ").strip() or "admin"
        email = input("Admin email: ").strip()
        if not email:
            email = f"{username}@localhost"

        import getpass
        while True:
            password = getpass.getpass("Admin password: ")
            if len(password) < 6:
                print("Password must be at least 6 characters.")
                continue
            confirm = getpass.getpass("Confirm password: ")
            if password != confirm:
                print("Passwords do not match. Try again.")
                continue
            break

        user = create_admin(username, email, password)
        print(f"\nAdmin created: {user.username} ({user.email})")
        print("Point the admin frontend's API_BASE_URL at this app and log in there.")


if __name__ == "__main__":
    main()
