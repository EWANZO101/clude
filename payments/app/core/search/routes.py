from flask import Blueprint, render_template, request
from flask_login import login_required, current_user

from app.core.search.registry import search

search_bp = Blueprint("search", __name__, url_prefix="/search", template_folder="../../templates/search")


@search_bp.route("/")
@login_required
def index():
    query = request.args.get("q", "").strip()
    results = search(query, current_user)
    return render_template("search/index.html", query=query, results=results)
