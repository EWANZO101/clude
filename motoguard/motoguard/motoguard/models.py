"""Database models for the recovery platform."""
from datetime import datetime
from werkzeug.security import generate_password_hash, check_password_hash
from flask_login import UserMixin
from .extensions import db


def utcnow():
    return datetime.utcnow()


class User(UserMixin, db.Model):
    __tablename__ = "users"
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    username = db.Column(db.String(64), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    is_admin = db.Column(db.Boolean, default=False)
    is_banned = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=utcnow)
    consented_at = db.Column(db.DateTime)  # when Terms & Privacy were accepted

    # Location (precise lat/lng used only for radius maths, never shown publicly)
    city = db.Column(db.String(120))
    region = db.Column(db.String(120))
    country = db.Column(db.String(120))
    lat = db.Column(db.Float)
    lng = db.Column(db.Float)

    # Alert preferences (strict opt-in)
    alerts_opt_in = db.Column(db.Boolean, default=False)
    alert_radius_miles = db.Column(db.Float)  # per-user override; None -> system default

    reputation = db.Column(db.Integer, default=0)

    vehicles = db.relationship("Vehicle", backref="owner", lazy="dynamic",
                               cascade="all, delete-orphan")

    def set_password(self, pw):
        self.password_hash = generate_password_hash(pw)

    def check_password(self, pw):
        return check_password_hash(self.password_hash, pw)

    @property
    def location_label(self):
        return ", ".join([p for p in (self.city, self.region, self.country) if p]) or "Unknown"


class Vehicle(db.Model):
    __tablename__ = "vehicles"
    id = db.Column(db.Integer, primary_key=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    make = db.Column(db.String(80))
    model = db.Column(db.String(80))
    year = db.Column(db.Integer)
    color = db.Column(db.String(40))
    reg_number = db.Column(db.String(40), index=True)
    vin = db.Column(db.String(64))
    description = db.Column(db.Text)

    # status: active | stolen | recovered
    status = db.Column(db.String(20), default="active", index=True)
    # privacy: private | public | public_when_stolen
    privacy = db.Column(db.String(24), default="public_when_stolen")

    last_city = db.Column(db.String(120))
    last_region = db.Column(db.String(120))
    last_country = db.Column(db.String(120))
    last_lat = db.Column(db.Float)
    last_lng = db.Column(db.Float)

    stolen_at = db.Column(db.DateTime)
    recovered_at = db.Column(db.DateTime)
    alerts_sent = db.Column(db.Integer, default=0)  # per current stolen event

    created_at = db.Column(db.DateTime, default=utcnow)

    photos = db.relationship("VehiclePhoto", backref="vehicle", lazy="select",
                             cascade="all, delete-orphan")
    sightings = db.relationship("Sighting", backref="vehicle", lazy="dynamic",
                                cascade="all, delete-orphan")

    @property
    def title(self):
        bits = [str(self.year or "").strip(), self.make or "", self.model or ""]
        return " ".join(b for b in bits if b) or "Motorcycle"

    @property
    def is_visible_public(self):
        if self.privacy == "public":
            return True
        if self.privacy == "public_when_stolen":
            return self.status == "stolen"
        return False

    @property
    def public_location(self):
        return ", ".join([p for p in (self.last_city, self.last_region) if p]) or "Unknown"


class VehiclePhoto(db.Model):
    __tablename__ = "vehicle_photos"
    id = db.Column(db.Integer, primary_key=True)
    vehicle_id = db.Column(db.Integer, db.ForeignKey("vehicles.id"), nullable=False)
    filename = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, default=utcnow)


# --------------------------------------------------------------------------- #
# Sightings
# --------------------------------------------------------------------------- #
class Sighting(db.Model):
    __tablename__ = "sightings"
    id = db.Column(db.Integer, primary_key=True)
    vehicle_id = db.Column(db.Integer, db.ForeignKey("vehicles.id"), nullable=False, index=True)
    reporter_id = db.Column(db.Integer, db.ForeignKey("users.id"))  # nullable -> anonymous

    seen_city = db.Column(db.String(120))
    seen_region = db.Column(db.String(120))
    seen_at = db.Column(db.DateTime)
    notes = db.Column(db.Text)
    photo = db.Column(db.String(255))
    contact_pref = db.Column(db.String(20), default="anonymous")  # anonymous | direct

    # status: pending | verified | dismissed
    status = db.Column(db.String(20), default="pending", index=True)
    created_at = db.Column(db.DateTime, default=utcnow)

    reporter = db.relationship("User")


# --------------------------------------------------------------------------- #
# Messaging
# --------------------------------------------------------------------------- #
class Conversation(db.Model):
    __tablename__ = "conversations"
    id = db.Column(db.Integer, primary_key=True)
    user_a_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    user_b_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    vehicle_id = db.Column(db.Integer, db.ForeignKey("vehicles.id"))  # optional context
    created_at = db.Column(db.DateTime, default=utcnow)
    last_at = db.Column(db.DateTime, default=utcnow, index=True)

    user_a = db.relationship("User", foreign_keys=[user_a_id])
    user_b = db.relationship("User", foreign_keys=[user_b_id])
    messages = db.relationship("Message", backref="conversation", lazy="dynamic",
                               cascade="all, delete-orphan")

    def other(self, uid):
        return self.user_b if self.user_a_id == uid else self.user_a


class Message(db.Model):
    __tablename__ = "messages"
    id = db.Column(db.Integer, primary_key=True)
    conversation_id = db.Column(db.Integer, db.ForeignKey("conversations.id"),
                                nullable=False, index=True)
    sender_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    body = db.Column(db.Text)
    attachment = db.Column(db.String(255))
    is_read = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=utcnow, index=True)


class Block(db.Model):
    __tablename__ = "blocks"
    id = db.Column(db.Integer, primary_key=True)
    blocker_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    blocked_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    created_at = db.Column(db.DateTime, default=utcnow)


# --------------------------------------------------------------------------- #
# Forum
# --------------------------------------------------------------------------- #
class ForumCategory(db.Model):
    __tablename__ = "forum_categories"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    slug = db.Column(db.String(120), unique=True, nullable=False, index=True)
    description = db.Column(db.String(255))
    sort = db.Column(db.Integer, default=0)

    posts = db.relationship("ForumPost", backref="category", lazy="dynamic")


class ForumPost(db.Model):
    __tablename__ = "forum_posts"
    id = db.Column(db.Integer, primary_key=True)
    category_id = db.Column(db.Integer, db.ForeignKey("forum_categories.id"),
                            nullable=False, index=True)
    author_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    vehicle_id = db.Column(db.Integer, db.ForeignKey("vehicles.id"))  # optional bike link
    title = db.Column(db.String(255), nullable=False)
    body = db.Column(db.Text)
    is_hidden = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=utcnow, index=True)

    author = db.relationship("User")
    vehicle = db.relationship("Vehicle")
    comments = db.relationship("ForumComment", backref="post", lazy="dynamic",
                               cascade="all, delete-orphan")
    likes = db.relationship("PostLike", backref="post", lazy="dynamic",
                            cascade="all, delete-orphan")

    @property
    def like_count(self):
        return self.likes.count()


class ForumComment(db.Model):
    __tablename__ = "forum_comments"
    id = db.Column(db.Integer, primary_key=True)
    post_id = db.Column(db.Integer, db.ForeignKey("forum_posts.id"), nullable=False, index=True)
    author_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    body = db.Column(db.Text, nullable=False)
    is_hidden = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=utcnow)

    author = db.relationship("User")


class PostLike(db.Model):
    __tablename__ = "post_likes"
    id = db.Column(db.Integer, primary_key=True)
    post_id = db.Column(db.Integer, db.ForeignKey("forum_posts.id"), nullable=False, index=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    __table_args__ = (db.UniqueConstraint("post_id", "user_id", name="uq_post_like"),)


# --------------------------------------------------------------------------- #
# Reports (forum + messages) and Notifications
# --------------------------------------------------------------------------- #
class Report(db.Model):
    __tablename__ = "reports"
    id = db.Column(db.Integer, primary_key=True)
    reporter_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    target_type = db.Column(db.String(30), nullable=False)  # post|comment|conversation|message
    target_id = db.Column(db.Integer, nullable=False)
    reason = db.Column(db.String(500))
    status = db.Column(db.String(20), default="open", index=True)  # open|resolved
    created_at = db.Column(db.DateTime, default=utcnow)

    reporter = db.relationship("User")


class Notification(db.Model):
    __tablename__ = "notifications"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    text = db.Column(db.String(500), nullable=False)
    url = db.Column(db.String(500))
    is_read = db.Column(db.Boolean, default=False, index=True)
    created_at = db.Column(db.DateTime, default=utcnow, index=True)


class PasswordReset(db.Model):
    __tablename__ = "password_resets"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    token = db.Column(db.String(128), unique=True, nullable=False, index=True)
    expires_at = db.Column(db.DateTime, nullable=False)
    used = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=utcnow)

    user = db.relationship("User")

    def is_valid(self):
        return (not self.used) and self.expires_at >= utcnow()
