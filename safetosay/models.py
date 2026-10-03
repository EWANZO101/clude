from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from datetime import datetime
import uuid

db = SQLAlchemy()

def gen_post_id():
    return 'FA-' + str(uuid.uuid4()).replace('-','')[:8].upper()

def gen_report_id():
    return 'RP-' + str(uuid.uuid4()).replace('-','')[:8].upper()

def gen_advice_id():
    return 'ADV-' + str(uuid.uuid4()).replace('-','')[:8].upper()


class User(UserMixin, db.Model):
    __tablename__ = 'users'
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    pin = db.Column(db.String(10), nullable=False)
    proof_file = db.Column(db.String(255), nullable=True)
    proof_type = db.Column(db.String(10), nullable=True)  # 'image' or 'document'
    is_admin = db.Column(db.Boolean, default=False)
    is_banned = db.Column(db.Boolean, default=False)
    ban_reason = db.Column(db.String(500), nullable=True)
    ip_address = db.Column(db.String(45), nullable=True)
    advice_media_approved = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    posts = db.relationship('Post', backref='author', lazy=True)
    comments = db.relationship('Comment', backref='author', lazy=True)


class Post(db.Model):
    __tablename__ = 'posts'
    id = db.Column(db.Integer, primary_key=True)
    post_id = db.Column(db.String(20), unique=True, nullable=False, default=gen_post_id)
    title = db.Column(db.String(200), nullable=False)
    content = db.Column(db.Text, nullable=False)
    forum_type = db.Column(db.String(10), default='main')  # 'main' or 'advice'
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    status = db.Column(db.String(20), default='active')  # active, hidden, removed, verified_true, pending_review
    tag = db.Column(db.String(50), nullable=True)
    edited_at = db.Column(db.DateTime, nullable=True)
    media = db.relationship('PostMedia', backref='post', lazy=True, cascade='all, delete-orphan')
    comments = db.relationship('Comment', backref='post', lazy=True, cascade='all, delete-orphan')
    reports = db.relationship('Report', backref='reported_post', lazy=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class PostMedia(db.Model):
    __tablename__ = 'post_media'
    id = db.Column(db.Integer, primary_key=True)
    post_id = db.Column(db.Integer, db.ForeignKey('posts.id'), nullable=False)
    filename = db.Column(db.String(255), nullable=False)
    media_type = db.Column(db.String(10))  # 'image' or 'document'
    approved = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class Comment(db.Model):
    __tablename__ = 'comments'
    id = db.Column(db.Integer, primary_key=True)
    content = db.Column(db.Text, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    post_id = db.Column(db.Integer, db.ForeignKey('posts.id'), nullable=False)
    is_hidden = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class Report(db.Model):
    __tablename__ = 'reports'
    id = db.Column(db.Integer, primary_key=True)
    report_id = db.Column(db.String(20), unique=True, nullable=False, default=gen_report_id)
    post_id = db.Column(db.Integer, db.ForeignKey('posts.id', ondelete='SET NULL'), nullable=True)
    post_ref_id = db.Column(db.String(20))
    portal_user_id = db.Column(db.Integer, db.ForeignKey('report_portal_users.id'), nullable=True)
    reporter_display_name = db.Column(db.String(100), nullable=True)
    is_anonymous = db.Column(db.Boolean, default=False)
    description = db.Column(db.Text, nullable=False)
    links = db.Column(db.Text, nullable=True)
    other_info = db.Column(db.Text, nullable=True)
    evidence_files = db.relationship('ReportMedia', backref='report', lazy=True, cascade='all, delete-orphan')
    status = db.Column(db.String(20), default='pending')  # pending, seen, resolved, dismissed
    admin_reply = db.Column(db.Text, nullable=True)
    admin_seen = db.Column(db.Boolean, default=False)
    ip_address = db.Column(db.String(45), nullable=True)
    claim_token = db.Column(db.String(64), nullable=True, unique=True)  # for unclaimed reports
    messages = db.relationship('ReportMessage', backref='report', lazy=True, cascade='all, delete-orphan', order_by='ReportMessage.created_at')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class ReportMedia(db.Model):
    __tablename__ = 'report_media'
    id = db.Column(db.Integer, primary_key=True)
    report_id = db.Column(db.Integer, db.ForeignKey('reports.id'), nullable=False)
    filename = db.Column(db.String(255), nullable=False)
    media_type = db.Column(db.String(10))


class ReportMessage(db.Model):
    """Private ticket messages between reporter and admin on a report."""
    __tablename__ = 'report_messages'
    id = db.Column(db.Integer, primary_key=True)
    report_id = db.Column(db.Integer, db.ForeignKey('reports.id'), nullable=False)
    sender = db.Column(db.String(10), nullable=False)   # 'reporter' or 'admin'
    sender_label = db.Column(db.String(80), nullable=True)  # display name
    content = db.Column(db.Text, nullable=False)
    is_read = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class ReportPortalUser(db.Model):
    __tablename__ = 'report_portal_users'
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    reports = db.relationship('Report', backref='portal_user', lazy=True)


class SiteText(db.Model):
    __tablename__ = 'site_text'
    id = db.Column(db.Integer, primary_key=True)
    page = db.Column(db.String(50), nullable=False)
    key = db.Column(db.String(100), nullable=False)
    value = db.Column(db.Text, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow)
    __table_args__ = (db.UniqueConstraint('page', 'key'),)


class Announcement(db.Model):
    __tablename__ = 'announcements'
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    content = db.Column(db.Text, nullable=False)
    target_page = db.Column(db.String(50), default='all')
    ann_type = db.Column(db.String(20), default='info')  # info, warning, danger, success
    is_active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class BannedIP(db.Model):
    __tablename__ = 'banned_ips'
    id = db.Column(db.Integer, primary_key=True)
    ip_address = db.Column(db.String(45), unique=True, nullable=False)
    reason = db.Column(db.String(500))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
