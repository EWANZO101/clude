import random
import string
from app import create_app, db
from app.models import User
from werkzeug.security import generate_password_hash

def rand(n=6):
    return ''.join(random.choices(string.ascii_letters + string.digits, k=n))

def randpass(n=14):
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(random.choices(chars, k=n))

app = create_app()

with app.app_context():
    username = f"admin_{rand()}"
    password = randpass()

    admin = User.query.filter_by(username=username).first()
    if admin:
        print("Collision, rerun script")
        exit()

    admin = User(
        username=username,
        password=generate_password_hash(password),
        is_admin=True
    )

    db.session.add(admin)
    db.session.commit()

    print("\n=== ADMIN CREATED ===")
    print("Username:", username)
    print("Password:", password)
    print("=====================\n")
