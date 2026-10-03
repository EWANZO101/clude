from flask import Blueprint, render_template, redirect, url_for, flash, request
from adminapp.utils.api_client import api_get, api_put, APIError
from adminapp.utils.decorators import login_required, admin_required

settings_bp = Blueprint("settings", __name__, url_prefix="/settings")


@settings_bp.route("/", methods=["GET", "POST"])
@login_required
@admin_required
def index():
    if request.method == "POST":
        try:
            api_put("/api/settings/", {
                "app_name": request.form.get("app_name", "").strip(),
                "default_low_stock_threshold": request.form.get("default_low_stock_threshold", 5),
                "kiosk_idle_timeout_seconds": request.form.get("kiosk_idle_timeout_seconds", 60),
                "kiosk_token_expires_minutes": request.form.get("kiosk_token_expires_minutes", 15),
                "max_checkout_hours": request.form.get("max_checkout_hours", 24),
                "kiosk_home_screen": request.form.get("kiosk_home_screen", "scan"),
            })
        except APIError as e:
            flash(e.message, "danger")
            return redirect(url_for("settings.index"))
        flash("Settings updated.", "success")
        return redirect(url_for("settings.index"))

    try:
        settings = api_get("/api/settings/")
    except APIError as e:
        flash(e.message, "danger")
        settings = {}
    return render_template("settings/index.html", settings=settings)
