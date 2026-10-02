from flask import Blueprint, render_template, redirect, url_for, flash
from flask_login import current_user

from database import db
from models.user import User
from models.role import Role, ROLE_OWNER
from modules.users.forms import CreateUserForm, EditUserForm
from utils.permissions import require_permission

users_bp = Blueprint("users", __name__, template_folder="templates")


@users_bp.route("/users")
@require_permission("users.manage")
def index():
    all_users = User.query.order_by(User.created_at.asc()).all()
    return render_template("users_index.html", users=all_users)


@users_bp.route("/users/create", methods=["GET", "POST"])
@require_permission("users.manage")
def create():
    form = CreateUserForm()
    form.role_id.choices = [(r.id, r.name) for r in Role.query.order_by(Role.id).all()]

    if form.validate_on_submit():
        existing = User.query.filter(
            (User.username == form.username.data.strip()) | (User.email == form.email.data.strip().lower())
        ).first()
        if existing:
            flash("That username or email is already in use.", "error")
            return render_template("users_create.html", form=form)

        role = db.session.get(Role, form.role_id.data)
        user = User(
            username=form.username.data.strip(),
            email=form.email.data.strip().lower(),
            role=role,
            is_super_admin=(role.name == ROLE_OWNER),
        )
        user.set_password(form.password.data)
        db.session.add(user)
        db.session.commit()
        flash(f"Created user {user.username}.", "success")
        return redirect(url_for("users.index"))

    return render_template("users_create.html", form=form)


@users_bp.route("/users/<int:user_id>/edit", methods=["GET", "POST"])
@require_permission("users.manage")
def edit(user_id):
    user = db.get_or_404(User, user_id)
    form = EditUserForm(obj=user)
    form.role_id.choices = [(r.id, r.name) for r in Role.query.order_by(Role.id).all()]

    if form.validate_on_submit():
        is_last_owner = user.role and user.role.name == ROLE_OWNER and \
            User.query.join(Role).filter(Role.name == ROLE_OWNER).count() <= 1

        new_role = db.session.get(Role, form.role_id.data)
        if is_last_owner and new_role.name != ROLE_OWNER:
            flash("Can't change the role of the last Owner account.", "error")
            return render_template("users_edit.html", form=form, user=user)

        if is_last_owner and not form.is_active.data:
            flash("Can't deactivate the last Owner account.", "error")
            return render_template("users_edit.html", form=form, user=user)

        existing = User.query.filter(
            User.id != user.id,
            (User.username == form.username.data.strip()) | (User.email == form.email.data.strip().lower()),
        ).first()
        if existing:
            flash("That username or email is already in use.", "error")
            return render_template("users_edit.html", form=form, user=user)

        user.username = form.username.data.strip()
        user.email = form.email.data.strip().lower()
        user.role = new_role
        user.is_super_admin = (new_role.name == ROLE_OWNER)
        user.is_active_flag = form.is_active.data
        if form.new_password.data:
            user.set_password(form.new_password.data)
        db.session.commit()
        flash(f"Updated {user.username}.", "success")
        return redirect(url_for("users.index"))

    if form.role_id.data is None:
        form.role_id.data = user.role_id

    return render_template("users_edit.html", form=form, user=user)


@users_bp.route("/users/<int:user_id>/delete", methods=["POST"])
@require_permission("users.manage")
def delete(user_id):
    user = db.get_or_404(User, user_id)

    if user.id == current_user.id:
        flash("You can't delete your own account.", "error")
        return redirect(url_for("users.index"))

    if user.role and user.role.name == ROLE_OWNER:
        owner_count = User.query.join(Role).filter(Role.name == ROLE_OWNER).count()
        if owner_count <= 1:
            flash("Can't delete the last Owner account.", "error")
            return redirect(url_for("users.index"))

    db.session.delete(user)
    db.session.commit()
    flash(f"Deleted {user.username}.", "success")
    return redirect(url_for("users.index"))
