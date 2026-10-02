"""GDPR data-subject tooling: export a user's data and erase an account.

Export covers everything we hold that is linked to the user. Erasure deletes the
user's personal data; content that belongs to other people (e.g. sightings the
user reported on someone else's stolen bike) is unlinked/anonymised rather than
destroyed, so it stays useful to the bike's owner without identifying the user.
"""
import os
from flask import current_app
from ..extensions import db
from ..models import (User, Vehicle, VehiclePhoto, Sighting, Conversation, Message,
                      Block, ForumPost, ForumComment, PostLike, Report, Notification,
                      PasswordReset)


def _iso(dt):
    return dt.isoformat() if dt else None


def export_user_data(user):
    """Return a JSON-serialisable dict of all data linked to the user."""
    vehicles = Vehicle.query.filter_by(owner_id=user.id).all()
    convo_ids = [c.id for c in Conversation.query.filter(
        (Conversation.user_a_id == user.id) | (Conversation.user_b_id == user.id)).all()]
    return {
        "account": {
            "username": user.username, "email": user.email,
            "created_at": _iso(user.created_at), "consented_at": _iso(user.consented_at),
            "city": user.city, "region": user.region, "country": user.country,
            "approx_lat": user.lat, "approx_lng": user.lng,
            "alerts_opt_in": user.alerts_opt_in, "alert_radius_miles": user.alert_radius_miles,
        },
        "vehicles": [{
            "make": v.make, "model": v.model, "year": v.year, "colour": v.color,
            "reg_number": v.reg_number, "vin": v.vin, "description": v.description,
            "status": v.status, "privacy": v.privacy,
            "last_location": v.public_location, "created_at": _iso(v.created_at),
            "photos": [p.filename for p in v.photos],
        } for v in vehicles],
        "sightings_reported": [{
            "vehicle_id": s.vehicle_id, "seen_city": s.seen_city, "seen_region": s.seen_region,
            "seen_at": _iso(s.seen_at), "notes": s.notes, "status": s.status,
            "created_at": _iso(s.created_at),
        } for s in Sighting.query.filter_by(reporter_id=user.id).all()],
        "messages_sent": [{
            "conversation_id": m.conversation_id, "body": m.body,
            "created_at": _iso(m.created_at),
        } for m in Message.query.filter_by(sender_id=user.id).all()],
        "conversations": convo_ids,
        "forum_posts": [{
            "title": p.title, "body": p.body, "created_at": _iso(p.created_at),
        } for p in ForumPost.query.filter_by(author_id=user.id).all()],
        "forum_comments": [{
            "post_id": c.post_id, "body": c.body, "created_at": _iso(c.created_at),
        } for c in ForumComment.query.filter_by(author_id=user.id).all()],
        "reports_filed": [{
            "target_type": r.target_type, "target_id": r.target_id, "reason": r.reason,
            "status": r.status, "created_at": _iso(r.created_at),
        } for r in Report.query.filter_by(reporter_id=user.id).all()],
        "notifications": [{
            "text": n.text, "created_at": _iso(n.created_at),
        } for n in Notification.query.filter_by(user_id=user.id).all()],
    }


def delete_user(user):
    """Erase a user and their personal data. Returns nothing; commits."""
    uid = user.id
    upload = current_app.config.get("UPLOAD_FOLDER", "")

    # 1) Remove the user's vehicles + photo files (cascade clears photos/sightings rows)
    vehicles = Vehicle.query.filter_by(owner_id=uid).all()
    vids = [v.id for v in vehicles]
    for v in vehicles:
        for p in v.photos:
            try:
                os.remove(os.path.join(upload, p.filename))
            except OSError:
                pass
    # Detach optional references to those vehicles so deletion doesn't break FKs
    if vids:
        for conv in Conversation.query.filter(Conversation.vehicle_id.in_(vids)).all():
            conv.vehicle_id = None
        for post in ForumPost.query.filter(ForumPost.vehicle_id.in_(vids)).all():
            post.vehicle_id = None
    for v in vehicles:
        db.session.delete(v)

    # 2) Anonymise sightings the user filed on OTHER people's bikes (keep for owners)
    for s in Sighting.query.filter_by(reporter_id=uid).all():
        s.reporter_id = None
        if s.contact_pref == "direct":
            s.contact_pref = "anonymous"

    # 3) Conversations the user is part of (cascade deletes their messages)
    for conv in Conversation.query.filter(
            (Conversation.user_a_id == uid) | (Conversation.user_b_id == uid)).all():
        db.session.delete(conv)
    # Any stray messages the user sent elsewhere
    for m in Message.query.filter_by(sender_id=uid).all():
        db.session.delete(m)

    # 4) Forum content authored by the user (cascade clears comments/likes on their posts)
    for c in ForumComment.query.filter_by(author_id=uid).all():
        db.session.delete(c)
    for p in ForumPost.query.filter_by(author_id=uid).all():
        db.session.delete(p)
    for lk in PostLike.query.filter_by(user_id=uid).all():
        db.session.delete(lk)

    # 5) Reports, notifications, blocks, password-reset tokens
    for r in Report.query.filter_by(reporter_id=uid).all():
        db.session.delete(r)
    for n in Notification.query.filter_by(user_id=uid).all():
        db.session.delete(n)
    for b in Block.query.filter(
            (Block.blocker_id == uid) | (Block.blocked_id == uid)).all():
        db.session.delete(b)
    for pr in PasswordReset.query.filter_by(user_id=uid).all():
        db.session.delete(pr)

    db.session.flush()
    db.session.delete(user)
    db.session.commit()
