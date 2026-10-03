from flask import render_template

from app.docs import docs_bp


@docs_bp.route("/docs/api")
def api_reference():
    return render_template("docs/api_reference.html")
