from flask import Blueprint, render_template

from ..models import Brand, ContentPost, SocialAccount

bp = Blueprint("dashboard", __name__)


@bp.route("/")
def index():
    brand = Brand.query.order_by(Brand.id.desc()).first()
    posts = ContentPost.query.filter_by(brand_id=brand.id).all() if brand else []
    total_posts = len(posts)
    published = len([p for p in posts if p.status == "published"])
    ig = SocialAccount.query.filter_by(platform="instagram").first()

    next_actions = []
    if not brand:
        next_actions.append(("Build your brand kit", "onboarding.start"))
    else:
        review_needed = len([p for p in posts if p.status in ("draft", "ai_review")])
        if review_needed:
            next_actions.append((f"Review {review_needed} posts", "content.index"))
        if not posts:
            next_actions.append(("Generate your first 30 posts", "content.index"))
        if not ig or not ig.connected:
            next_actions.append(("Connect Instagram", "accounts.index"))

    return render_template(
        "dashboard.html",
        brand=brand,
        total_posts=total_posts,
        published=published,
        next_actions=next_actions,
    )
