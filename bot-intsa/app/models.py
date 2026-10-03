import json
from datetime import datetime

from .extensions import db


class Brand(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120))
    niche = db.Column(db.String(200))
    location = db.Column(db.String(120))
    audience = db.Column(db.String(300))
    goal = db.Column(db.String(120))
    style = db.Column(db.String(120))

    display_name = db.Column(db.String(120))
    username_suggestions = db.Column(db.Text, default="[]")
    bio = db.Column(db.Text)
    voice = db.Column(db.Text)
    colors = db.Column(db.Text, default="[]")
    fonts = db.Column(db.Text, default="[]")
    content_pillars = db.Column(db.Text, default="[]")
    highlight_categories = db.Column(db.Text, default="[]")
    cta = db.Column(db.String(200))

    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def as_list(self, field):
        try:
            return json.loads(getattr(self, field) or "[]")
        except ValueError:
            return []


class ContentPost(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    brand_id = db.Column(db.Integer, db.ForeignKey("brand.id"))
    kind = db.Column(db.String(30))  # educational, personal, promotional, engagement, reel
    caption = db.Column(db.Text)
    image_prompt = db.Column(db.Text)
    script = db.Column(db.Text)
    status = db.Column(db.String(30), default="draft")  # draft, ai_review, approved, ready, published
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    brand = db.relationship("Brand", backref="posts")


class SocialAccount(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    platform = db.Column(db.String(30))  # instagram, facebook, whatsapp, discord
    username = db.Column(db.String(200))
    encrypted_password = db.Column(db.Text)
    encrypted_totp_secret = db.Column(db.Text)
    connected = db.Column(db.Boolean, default=False)
    last_login_at = db.Column(db.DateTime)
    last_login_status = db.Column(db.String(200))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
