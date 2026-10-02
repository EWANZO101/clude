"""Community forum: categories, posts, threaded comments, likes, search."""
from flask import (Blueprint, render_template, redirect, url_for, request,
                   flash, abort)
from flask_login import login_required, current_user
from sqlalchemy import or_
from ..extensions import db
from ..models import (ForumCategory, ForumPost, ForumComment, PostLike, Report,
                      Vehicle)

bp = Blueprint("forum", __name__)


@bp.route("/")
def index():
    cats = ForumCategory.query.order_by(ForumCategory.sort, ForumCategory.name).all()
    counts = {c.id: c.posts.filter_by(is_hidden=False).count() for c in cats}
    return render_template("forum/index.html", cats=cats, counts=counts)


@bp.route("/c/<slug>")
def category(slug):
    cat = ForumCategory.query.filter_by(slug=slug).first() or abort(404)
    posts = (cat.posts.filter_by(is_hidden=False)
             .order_by(ForumPost.created_at.desc()).all())
    return render_template("forum/category.html", cat=cat, posts=posts)


@bp.route("/search")
def search():
    q = (request.args.get("q") or "").strip()
    posts = []
    if q:
        like = f"%{q}%"
        posts = (ForumPost.query.filter(ForumPost.is_hidden.is_(False))
                 .filter(or_(ForumPost.title.ilike(like), ForumPost.body.ilike(like)))
                 .order_by(ForumPost.created_at.desc()).limit(50).all())
    return render_template("forum/search.html", q=q, posts=posts)


@bp.route("/new", methods=["GET", "POST"])
@login_required
def new_post():
    cats = ForumCategory.query.order_by(ForumCategory.sort).all()
    if request.method == "POST":
        if request.form.get("website"):
            abort(400)
        title = (request.form.get("title") or "").strip()
        body = (request.form.get("body") or "").strip()
        cat_id = request.form.get("category_id", type=int)
        if not (title and cat_id):
            flash("Title and category are required.", "error")
            return render_template("forum/new.html", cats=cats)
        vehicle_id = request.form.get("vehicle_id", type=int)
        if vehicle_id:
            v = db.session.get(Vehicle, vehicle_id)
            if not v or v.owner_id != current_user.id:
                vehicle_id = None
        p = ForumPost(category_id=cat_id, author_id=current_user.id, title=title,
                      body=body, vehicle_id=vehicle_id)
        db.session.add(p)
        db.session.commit()
        return redirect(url_for("forum.post", post_id=p.id))
    my_bikes = current_user.vehicles.all()
    return render_template("forum/new.html", cats=cats, my_bikes=my_bikes)


@bp.route("/p/<int:post_id>", methods=["GET", "POST"])
def post(post_id):
    p = db.session.get(ForumPost, post_id) or abort(404)
    if p.is_hidden and not (current_user.is_authenticated and current_user.is_admin):
        abort(404)
    if request.method == "POST":
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login", next=request.path))
        body = (request.form.get("body") or "").strip()
        if body:
            db.session.add(ForumComment(post_id=p.id, author_id=current_user.id, body=body))
            db.session.commit()
        return redirect(url_for("forum.post", post_id=p.id))
    comments = p.comments.filter_by(is_hidden=False).order_by(
        ForumComment.created_at.asc()).all()
    liked = False
    if current_user.is_authenticated:
        liked = PostLike.query.filter_by(post_id=p.id, user_id=current_user.id).first() \
            is not None
    return render_template("forum/post.html", p=p, comments=comments, liked=liked)


@bp.route("/p/<int:post_id>/like", methods=["POST"])
@login_required
def like(post_id):
    p = db.session.get(ForumPost, post_id) or abort(404)
    existing = PostLike.query.filter_by(post_id=p.id, user_id=current_user.id).first()
    if existing:
        db.session.delete(existing)
    else:
        db.session.add(PostLike(post_id=p.id, user_id=current_user.id))
    db.session.commit()
    return redirect(url_for("forum.post", post_id=p.id))


@bp.route("/p/<int:post_id>/report", methods=["POST"])
@login_required
def report(post_id):
    db.session.add(Report(reporter_id=current_user.id, target_type="post",
                          target_id=post_id, reason=request.form.get("reason", "")))
    db.session.commit()
    flash("Post reported.", "success")
    return redirect(url_for("forum.post", post_id=post_id))
