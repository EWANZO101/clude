"""Create tables and seed initial data. Idempotent."""
import os
from .extensions import db
from .models import ForumCategory, User

CATEGORIES = [
    ("General Discussion", "general", "Anything bike-related."),
    ("Stolen Bikes Reports", "stolen-bikes", "Active stolen reports & appeals."),
    ("Sightings & Tips", "sightings-tips", "Possible sightings and recovery tips."),
    ("Recovery Success Stories", "success", "Bikes that made it home."),
    ("Security Advice", "security", "Locks, trackers, storage, deterrents."),
    ("Regional", "regional", "Country / region specific threads."),
]


def seed(app):
    with app.app_context():
        db.create_all()
        for i, (name, slug, desc) in enumerate(CATEGORIES):
            if not ForumCategory.query.filter_by(slug=slug).first():
                db.session.add(ForumCategory(name=name, slug=slug, description=desc, sort=i))
        db.session.commit()

        admin_email = os.environ.get("ADMIN_EMAIL")
        admin_pass = os.environ.get("ADMIN_PASSWORD")
        if admin_email and admin_pass:
            existing = User.query.filter_by(email=admin_email.lower()).first()
            if not existing:
                u = User(email=admin_email.lower(),
                         username=os.environ.get("ADMIN_USERNAME", "admin"),
                         is_admin=True, alerts_opt_in=False)
                u.set_password(admin_pass)
                db.session.add(u)
                db.session.commit()
                print(f"[seed] created admin user {admin_email}")
            elif not existing.is_admin:
                existing.is_admin = True
                db.session.commit()
                print(f"[seed] promoted {admin_email} to admin")
        print("[seed] database ready")
