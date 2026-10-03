"""
Reviews / testimonials.

Public (no auth):
  GET  /reviews              all approved reviews
  GET  /reviews/new          submission form
  POST /reviews/new          create (shows immediately unless moderation is on)

Admin (staff+):
  GET  /admin/reviews                 moderate
  POST /admin/reviews/<id>/approve    toggle approved
  POST /admin/reviews/<id>/delete     remove
"""
import os
import json
import urllib.request
from datetime import datetime, timezone

from flask import render_template, request, redirect, url_for, flash, current_app
from flask_login import current_user

from . import reviews_bp
from .. import db
from ..models_business import Testimonial, TestimonialReply, Notification, AuditLog
from ..models_admin import Setting
from ..rbac import require_role, STAFF

WEBHOOK_SETTING = "reviews_discord_webhook"

_RATING_COLOR = {5: 0xFFD700, 4: 0x4ADE80, 3: 0x60A5FA, 2: 0xF59E0B, 1: 0xEF4444}


def _webhook_url():
    return (Setting.get(WEBHOOK_SETTING) or os.environ.get("REVIEWS_DISCORD_WEBHOOK") or "").strip()


def _post_discord(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json", "User-Agent": "OpsLab-Reviews/1.0"},
    )
    with urllib.request.urlopen(req, timeout=6) as resp:  # noqa: S310 (trusted admin URL)
        return resp.status


def _review_embed(t, reviews_url):
    r = max(1, min(5, int(t.rating or 5)))
    stars = "★" * r + "☆" * (5 - r)
    body = (t.body or "").strip()
    if len(body) > 1500:
        body = body[:1497] + "…"
    fields = []
    if t.organisation:
        fields.append({"name": "Business / community", "value": t.organisation[:256], "inline": True})
    if t.country:
        fields.append({"name": "Country", "value": t.country[:256], "inline": True})
    return {
        "title": f"{stars}  New {r}-star review",
        "description": f">>> {body}" if body else "",
        "url": reviews_url,
        "color": _RATING_COLOR.get(r, 0x2196F3),
        "author": {"name": t.name[:256]},
        "fields": fields,
        "footer": {"text": "OpsLab Systems · Reviews"},
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def notify_review(t):
    """Post a new review to Discord if a webhook is configured. Never raises."""
    url = _webhook_url()
    if not url:
        return False
    try:
        reviews_url = url_for("reviews.index", _external=True)
    except Exception:
        reviews_url = "https://web.opslabsystems.cloud/reviews"
    payload = {
        "username": "OpsLab Reviews",
        "embeds": [_review_embed(t, reviews_url)],
    }
    try:
        _post_discord(url, payload)
        try:
            t.posted_to_discord = True
            db.session.commit()
        except Exception:
            db.session.rollback()
        return True
    except Exception as e:
        try:
            current_app.logger.warning("Discord review webhook failed: %s", e)
        except Exception:
            pass
        return False


def _is_staff_user():
    return current_user.is_authenticated and (
        getattr(current_user, "is_staff", False) or getattr(current_user, "is_admin", False))


def _clamp_rating(raw, default=5):
    try:
        return max(1, min(5, int(float(raw))))
    except (TypeError, ValueError):
        return default


# ════════════════════════════════════════════════ PUBLIC ═══════════════════
@reviews_bp.route("/reviews")
def index():
    items = (Testimonial.query.filter_by(approved=True)
             .order_by(Testimonial.created_at.desc()).all())
    avg = round(sum(t.rating_clamped for t in items) / len(items), 1) if items else None
    return render_template("reviews/index.html", reviews=items, avg=avg, count=len(items))


@reviews_bp.route("/reviews/new", methods=["GET", "POST"])
def new():
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        body = (request.form.get("body") or "").strip()
        rating = _clamp_rating(request.form.get("rating"))
        if not name or not body:
            flash("Please add your name and a short review.", "error")
            return render_template("reviews/new.html", form=request.form)
        t = Testimonial(
            name=name[:120],
            organisation=(request.form.get("organisation") or "").strip()[:160] or None,
            country=(request.form.get("country") or "").strip()[:80] or None,
            rating=rating,
            body=body[:2000],
            approved=True,   # show immediately; flip to False here to moderate first
        )
        db.session.add(t)
        db.session.flush()
        # notify the default admin (id is not known here; notify all staff via audit)
        AuditLog.log("review.create", target_type="testimonial", target_id=t.id,
                     meta={"name": name, "rating": rating}, ip=request.remote_addr)
        db.session.commit()
        if t.approved:
            notify_review(t)
        flash("Thank you! Your review has been posted.", "success")
        return redirect(url_for("reviews.index"))
    return render_template("reviews/new.html", form={})


@reviews_bp.route("/reviews/<int:rid>/reply", methods=["POST"])
def reply(rid):
    t = Testimonial.query.get_or_404(rid)
    body = (request.form.get("body") or "").strip()
    staff = _is_staff_user()
    name = (current_user.username if staff else (request.form.get("name") or "").strip())
    if not body or not name:
        flash("Please add your name and a message.", "error")
        return redirect(url_for("reviews.index") + f"#review-{t.id}")
    db.session.add(TestimonialReply(testimonial_id=t.id, name=name[:120],
                                    body=body[:2000], is_staff=staff))
    AuditLog.log("review.reply", target_type="testimonial", target_id=t.id,
                 meta={"staff": staff}, ip=request.remote_addr)
    db.session.commit()
    flash("Reply posted.", "success")
    return redirect(url_for("reviews.index") + f"#review-{t.id}")


@reviews_bp.route("/reviews/reply/<int:reply_id>/delete", methods=["POST"])
@require_role(STAFF)
def delete_reply(reply_id):
    rep = TestimonialReply.query.get_or_404(reply_id)
    tid = rep.testimonial_id
    db.session.delete(rep)
    AuditLog.log("review.reply_delete", actor=current_user, target_type="testimonial",
                 target_id=tid, ip=request.remote_addr)
    db.session.commit()
    flash("Reply deleted.", "success")
    return redirect(url_for("reviews.index") + f"#review-{tid}")


# ════════════════════════════════════════════════ ADMIN ════════════════════
@reviews_bp.route("/admin/reviews")
@require_role(STAFF)
def admin_list():
    show = request.args.get("show", "all")
    q = Testimonial.query
    if show == "pending":
        q = q.filter_by(approved=False)
    elif show == "approved":
        q = q.filter_by(approved=True)
    items = q.order_by(Testimonial.created_at.desc()).all()
    return render_template("admin/reviews/list.html", reviews=items, show=show,
                           webhook_set=bool(_webhook_url()))


@reviews_bp.route("/admin/reviews/<int:rid>/approve", methods=["POST"])
@require_role(STAFF)
def admin_approve(rid):
    t = Testimonial.query.get_or_404(rid)
    t.approved = not t.approved
    AuditLog.log("review.approve" if t.approved else "review.hide",
                 actor=current_user, target_type="testimonial", target_id=t.id,
                 ip=request.remote_addr)
    db.session.commit()
    if t.approved:
        notify_review(t)
    flash("Review shown." if t.approved else "Review hidden.", "success")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))


@reviews_bp.route("/admin/reviews/<int:rid>/post", methods=["POST"])
@require_role(STAFF)
def admin_post(rid):
    t = Testimonial.query.get_or_404(rid)
    if not _webhook_url():
        flash("Set a Discord webhook URL first.", "error")
    elif t.posted_to_discord:
        flash("That review has already been posted.", "success")
    elif notify_review(t):
        flash("Review posted to Discord.", "success")
    else:
        flash("Couldn't reach Discord. Check the webhook URL.", "error")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))


@reviews_bp.route("/admin/reviews/webhook", methods=["POST"])
@require_role(STAFF)
def admin_webhook():
    action = request.form.get("action")
    if action == "save":
        url = (request.form.get("webhook_url") or "").strip()
        Setting.set(WEBHOOK_SETTING, url, kind="string", category="reviews")
        AuditLog.log("review.webhook_set", actor=current_user, ip=request.remote_addr)
        flash("Discord webhook saved." if url else "Discord webhook cleared.", "success")
    elif action == "test":
        url = _webhook_url()
        if not url:
            flash("Save a webhook URL first.", "error")
        else:
            ok = False
            try:
                ok = _post_discord(url, {
                    "username": "OpsLab Reviews",
                    "embeds": [{
                        "title": "✅ Test message",
                        "description": "Your reviews webhook is connected. New reviews will appear here.",
                        "color": 0x2196F3,
                        "footer": {"text": "OpsLab Systems · Reviews"},
                    }],
                }) in (200, 204)
            except Exception:
                ok = False
            flash("Test sent — check your Discord channel." if ok else
                  "Couldn't reach Discord. Check the webhook URL.", "success" if ok else "error")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))


@reviews_bp.route("/admin/reviews/<int:rid>/delete", methods=["POST"])
@require_role(STAFF)
def admin_delete(rid):
    t = Testimonial.query.get_or_404(rid)
    db.session.delete(t)
    AuditLog.log("review.delete", actor=current_user, target_type="testimonial",
                 target_id=rid, ip=request.remote_addr)
    db.session.commit()
    flash("Review deleted.", "success")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))
