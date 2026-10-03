from flask import Blueprint, render_template, redirect, url_for, flash, request, g
from adminapp.utils.api_client import api_get, api_post, api_put, api_delete, APIError
from adminapp.utils.decorators import login_required, admin_required
from adminapp.utils.formatting import hydrate_list

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")

_DATE_FIELDS = ["created_at", "last_login"]


class Role:
    ADMIN = "admin"
    STOCK_USER = "stock_user"
    ALL = [ADMIN, STOCK_USER]


@admin_bp.route("/")
@login_required
@admin_required
def index():
    try:
        users = api_get("/api/users/")
    except APIError as e:
        flash(e.message, "danger")
        users = []
    hydrate_list(users, _DATE_FIELDS)
    return render_template("admin/index.html", users=users)


@admin_bp.route("/users/add", methods=["GET", "POST"])
@login_required
@admin_required
def add_user():
    if request.method == "POST":
        badge_only = request.form.get("badge_only") == "on"
        try:
            user = api_post("/api/users/", {
                "username": request.form.get("username", "").strip(),
                "email": request.form.get("email", "").strip(),
                "password": request.form.get("password", ""),
                "role": request.form.get("role", Role.STOCK_USER),
                "force_password_change": request.form.get("force_password_change") == "on",
                "badge_only": badge_only,
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("admin/user_form.html", user=None, action="Add", Role=Role)

        flash(f"User '{user['username']}' created.", "success")
        return redirect(url_for("admin.index"))

    return render_template("admin/user_form.html", user=None, action="Add", Role=Role)


@admin_bp.route("/users/<int:user_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit_user(user_id):
    try:
        user = api_get(f"/api/users/{user_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("admin.index"))

    if request.method == "POST":
        badge_only = request.form.get("badge_only") == "on"
        payload = {
            "email": request.form.get("email", "").strip(),
            "role": request.form.get("role", user["role"]),
            "is_active": request.form.get("is_active") == "on",
            "force_password_change": request.form.get("force_password_change") == "on",
            "badge_only": badge_only,
        }
        new_password = request.form.get("new_password", "").strip()
        if new_password:
            payload["new_password"] = new_password

        try:
            user = api_put(f"/api/users/{user_id}", payload)
        except APIError as e:
            flash(e.message, "danger")
            return render_template("admin/user_form.html", user=user, action="Edit", Role=Role)

        flash(f"User '{user['username']}' updated.", "success")
        return redirect(url_for("admin.index"))

    return render_template("admin/user_form.html", user=user, action="Edit", Role=Role)


@admin_bp.route("/users/<int:user_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete_user(user_id):
    try:
        result = api_delete(f"/api/users/{user_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("admin.index"))
    flash(result.get("message", "User removed."), "info")
    return redirect(url_for("admin.index"))
