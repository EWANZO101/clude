from flask import Blueprint, render_template, request, redirect, url_for, flash
from adminapp.utils.api_client import api_post, api_get, APIError
from adminapp.utils.decorators import login_required
from adminapp.utils.formatting import hydrate

barcode_bp = Blueprint("barcode", __name__, url_prefix="/barcode")


@barcode_bp.route("/scan", methods=["GET", "POST"])
@login_required
def scan():
    """
    Lookup page for barcode scanners. A USB/Bluetooth barcode scanner acts
    as a keyboard, typing the scanned code into the input box below
    (followed by Enter), which submits this form and jumps straight to the
    matching tool, item, project, or badge.
    """
    if request.method == "POST":
        code = request.form.get("code", "").strip().upper()
        try:
            result = api_post("/api/barcodes/lookup", {"code": code})
        except APIError as e:
            flash(e.message, "danger")
            return render_template("barcode/scan.html")

        entity_type = result["entity_type"]
        entity = result["entity"] or {}
        if entity_type == "tool":
            return redirect(url_for("tools.view", tool_id=entity["id"]))
        if entity_type == "item":
            return redirect(url_for("items.view", item_id=entity["id"]))
        if entity_type == "project":
            return redirect(url_for("projects.view", project_id=entity["id"]))
        if entity_type == "user":
            return redirect(url_for("barcode.view", code=result["code"]))
        flash("Barcode is not linked to anything.", "warning")

    return render_template("barcode/scan.html")


@barcode_bp.route("/view/<code>")
@login_required
def view(code):
    try:
        bc = api_get(f"/api/barcodes/{code}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("dashboard.index"))
    hydrate(bc, ["created_at"])
    return render_template("barcode/view.html", barcode=bc)
