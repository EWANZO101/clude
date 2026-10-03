from flask import Blueprint, render_template, request, redirect, url_for, flash, abort
from flask_login import login_required
from app.models.barcode import Barcode

barcode_bp = Blueprint("barcode", __name__, url_prefix="/barcode")


@barcode_bp.route("/scan", methods=["GET", "POST"])
@login_required
def scan():
    """
    Lookup page for barcode scanners. A USB/Bluetooth barcode scanner acts
    as a keyboard, typing the scanned code into the input box below
    (followed by Enter), which submits this form and jumps straight to the
    matching tool or item.
    """
    if request.method == "POST":
        code = request.form.get("code", "").strip().upper()
        bc = Barcode.query.filter_by(code=code).first()
        if not bc:
            flash(f"No item or tool found for code '{code}'.", "danger")
            return render_template("barcode/scan.html")
        if bc.tool_id:
            return redirect(url_for("tools.view", tool_id=bc.tool_id))
        if bc.item_id:
            return redirect(url_for("items.view", item_id=bc.item_id))
        if bc.project_id:
            return redirect(url_for("projects.view", project_id=bc.project_id))
        if bc.user_id:
            return redirect(url_for("barcode.view", code=bc.code))
        flash("Barcode is not linked to an item or tool.", "warning")

    return render_template("barcode/scan.html")


@barcode_bp.route("/view/<code>")
@login_required
def view(code):
    """Show the barcode image + entity info."""
    bc = Barcode.query.filter_by(code=code).first_or_404()
    return render_template("barcode/view.html", barcode=bc)
