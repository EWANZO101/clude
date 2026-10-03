from flask import Blueprint, render_template
from flask_login import login_required

# The loader looks for a blueprint named `bp` in this file.
bp = Blueprint("my_module", __name__, url_prefix="/my-module",
                template_folder="templates")


@bp.route("/")
@login_required
def index():
    return render_template("my_module/index.html")
