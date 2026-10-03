"""One-off helper: creates all tables directly (dev convenience).
For real environments use `flask db migrate` / `flask db upgrade` instead."""
from app import create_app
from app.extensions import db

app = create_app("development")
with app.app_context():
    db.create_all()
    print("Database tables created.")
