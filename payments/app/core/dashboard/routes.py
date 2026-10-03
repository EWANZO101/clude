from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user

from app.extensions import db
from app.core.database.models import DashboardWidget, NavItem
from app.core.dashboard.widget_data import resolve_widget

dashboard_bp = Blueprint("dashboard", __name__, template_folder="../../templates/dashboard")

DEFAULT_WIDGETS = [
    "current_balance", "available_money", "monthly_income", "monthly_spending",
    "upcoming_bills", "budgets", "recent_transactions", "checklist_progress",
    "notifications", "spending_chart",
]

SETUP_STEPS = ["welcome", "profile", "modules", "finance", "done"]


@dashboard_bp.route("/")
@login_required
def index():
    if not current_user.setup_complete:
        return redirect(url_for("dashboard.setup_wizard"))

    widgets = DashboardWidget.query.filter_by(user_id=current_user.id, enabled=True).order_by(
        DashboardWidget.position
    ).all()
    if not widgets:
        widgets = _create_default_widgets()

    widget_data = {}
    for w in widgets:
        data = resolve_widget(w.widget_key, current_user.id)
        if data:
            widget_data[w.id] = data

    return render_template("dashboard/index.html", widgets=widgets, widget_data=widget_data)


def _create_default_widgets():
    created = []
    for i, key in enumerate(DEFAULT_WIDGETS):
        w = DashboardWidget(user_id=current_user.id, widget_key=key, position=i)
        db.session.add(w)
        created.append(w)
    db.session.commit()
    return created


@dashboard_bp.route("/widgets/<int:widget_id>/toggle", methods=["POST"])
@login_required
def toggle_widget(widget_id):
    widget = DashboardWidget.query.filter_by(id=widget_id, user_id=current_user.id).first_or_404()
    widget.enabled = not widget.enabled
    db.session.commit()
    return redirect(url_for("dashboard.index"))


@dashboard_bp.route("/widgets/reorder", methods=["POST"])
@login_required
def reorder_widgets():
    order = request.json.get("order", []) if request.is_json else []
    for position, widget_id in enumerate(order):
        DashboardWidget.query.filter_by(id=widget_id, user_id=current_user.id).update({"position": position})
    db.session.commit()
    return {"status": "ok"}


@dashboard_bp.route("/setup", methods=["GET", "POST"])
@login_required
def setup_wizard():
    step = request.args.get("step", "welcome")
    if step not in SETUP_STEPS:
        step = "welcome"

    if request.method == "POST":
        if step == "profile":
            current_user.country = request.form.get("country", "").strip() or current_user.country
            current_user.currency = request.form.get("currency", "GBP")
            current_user.timezone = request.form.get("timezone", "Europe/London")
            db.session.commit()
        elif step == "done":
            current_user.setup_complete = True
            db.session.commit()
            _create_default_widgets()
            flash("Setup complete. Welcome aboard.", "success")
            return redirect(url_for("dashboard.index"))

        next_index = min(SETUP_STEPS.index(step) + 1, len(SETUP_STEPS) - 1)
        return redirect(url_for("dashboard.setup_wizard", step=SETUP_STEPS[next_index]))

    return render_template("dashboard/setup_wizard.html", step=step, steps=SETUP_STEPS)


@dashboard_bp.route("/setup/skip")
@login_required
def setup_skip():
    current_user.setup_complete = True
    db.session.commit()
    _create_default_widgets()
    return redirect(url_for("dashboard.index"))


# ---- Settings ----

@dashboard_bp.route("/settings")
@login_required
def settings_index():
    return redirect(url_for("dashboard.settings_general"))


@dashboard_bp.route("/settings/general", methods=["GET", "POST"])
@login_required
def settings_general():
    if request.method == "POST":
        current_user.name = request.form.get("name", current_user.name)
        current_user.country = request.form.get("country", current_user.country)
        current_user.currency = request.form.get("currency", current_user.currency)
        current_user.timezone = request.form.get("timezone", current_user.timezone)
        current_user.date_format = request.form.get("date_format", current_user.date_format)
        current_user.number_format = request.form.get("number_format", current_user.number_format)
        current_user.first_day_of_week = request.form.get("first_day_of_week", current_user.first_day_of_week)
        db.session.commit()
        flash("General settings saved.", "success")
        return redirect(url_for("dashboard.settings_general"))
    return render_template("dashboard/settings_general.html")


@dashboard_bp.route("/settings/appearance", methods=["GET", "POST"])
@login_required
def settings_appearance():
    if request.method == "POST":
        current_user.theme = request.form.get("theme", current_user.theme)
        current_user.accent_colour = request.form.get("accent_colour", current_user.accent_colour)
        current_user.dashboard_density = request.form.get("dashboard_density", current_user.dashboard_density)
        db.session.commit()
        flash("Appearance settings saved.", "success")
        return redirect(url_for("dashboard.settings_appearance"))
    return render_template("dashboard/settings_appearance.html")


@dashboard_bp.route("/settings/notifications", methods=["GET", "POST"])
@login_required
def settings_notifications():
    # Full notification preference wiring lands with the notifications core system.
    if request.method == "POST":
        flash("Notification settings saved.", "success")
        return redirect(url_for("dashboard.settings_notifications"))
    return render_template("dashboard/settings_notifications.html")


@dashboard_bp.route("/settings/security")
@login_required
def settings_security():
    return render_template("dashboard/settings_security.html")


@dashboard_bp.route("/settings/finance", methods=["GET", "POST"])
@login_required
def settings_finance():
    # Full finance preferences land with the finance module.
    if request.method == "POST":
        flash("Finance settings saved.", "success")
        return redirect(url_for("dashboard.settings_finance"))
    return render_template("dashboard/settings_finance.html")
