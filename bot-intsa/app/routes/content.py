from flask import Blueprint, redirect, render_template, request, url_for

from ..extensions import db
from ..models import Brand, ContentPost
from ..services.ai import generate_content_plan

bp = Blueprint("content", __name__, url_prefix="/content")


@bp.route("/")
def index():
    brand = Brand.query.order_by(Brand.id.desc()).first()
    posts = ContentPost.query.filter_by(brand_id=brand.id).all() if brand else []
    return render_template("content.html", brand=brand, posts=posts)


@bp.route("/generate", methods=["POST"])
def generate():
    brand = Brand.query.order_by(Brand.id.desc()).first()
    if not brand:
        return redirect(url_for("onboarding.start"))

    plan = generate_content_plan(brand)
    for item in plan:
        db.session.add(
            ContentPost(
                brand_id=brand.id,
                kind=item.get("kind", "educational"),
                caption=item.get("caption", ""),
                image_prompt=item.get("image_prompt", ""),
                script=item.get("script", ""),
                status="ai_review",
            )
        )
    db.session.commit()
    return redirect(url_for("content.index"))


@bp.route("/<int:post_id>")
def detail(post_id):
    post = ContentPost.query.get_or_404(post_id)
    return render_template("content_detail.html", post=post)


@bp.route("/<int:post_id>/status", methods=["POST"])
def set_status(post_id):
    post = ContentPost.query.get_or_404(post_id)
    post.status = request.form.get("status", post.status)
    db.session.commit()
    return redirect(url_for("content.detail", post_id=post.id))


@bp.route("/<int:post_id>/edit", methods=["POST"])
def edit(post_id):
    post = ContentPost.query.get_or_404(post_id)
    post.caption = request.form.get("caption", post.caption)
    post.script = request.form.get("script", post.script)
    db.session.commit()
    return redirect(url_for("content.detail", post_id=post.id))
