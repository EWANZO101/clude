"""Public reviews / testimonials: submission, listing, homepage slider, moderation."""
from flask import Blueprint

reviews_bp = Blueprint("reviews", __name__)

from . import routes  # noqa: E402,F401
