import random
import string
from app import create_app, db
from app.models.user import User
from werkzeug.security import generate_password_hash

def random_string(length=10):
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))

def random_password(length=14):
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(random.choices(chars, k=length))

app = create_app()

with app.app_context():
    username = f"admin_{random_string(6)}"
    password_plain = random_password()

    # avoid duplicates
    existing = User.query.filter_by(username=username).first()
    if existing:
        print("Username collision, run again.")
        exit()

    admin = User(
        username=username,
        password=generate_password_hash(password_plain),
        is_admin=True
    )

    db.session.add(admin)
    db.session.commit()

    print("\n=== NEW ADMIN CREATED ===")
    print(f"Username: {username}")
    print(f"Password: {password_plain}")
    print("=========================\n")
