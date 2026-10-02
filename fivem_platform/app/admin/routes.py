from functools import wraps

from flask import render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user

from app.admin import admin_bp
from app.extensions import db
from app.models.user import User, SupportAuditLog, AdminActionLog
from app.models.developer import Product, License, TebexIntegration


def log_admin_action(action, target_label=None):
    db.session.add(AdminActionLog(admin_user_id=current_user.id, action=action, target_label=target_label))


def admin_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated or not current_user.is_admin:
            flash("Admin access required.", "error")
            return redirect(url_for("dashboard.index"))
        return f(*args, **kwargs)
    return wrapper


# ------------------------------------------------------------------ dashboard
@admin_bp.route("/admin")
@login_required
@admin_required
def dashboard():
    stats = {
        "total_users": User.query.count(),
        "total_developers": User.query.filter_by(is_developer=True).count(),
        "total_products": Product.query.count(),
        "total_licenses": License.query.count(),
        "active_licenses": License.query.filter_by(status="active").count(),
        "tebex_integrations": TebexIntegration.query.count(),
        "suspended_users": User.query.filter_by(is_suspended=True).count(),
    }
    recent_users = User.query.order_by(User.created_at.desc()).limit(5).all()
    return render_template("admin/dashboard.html", stats=stats, recent_users=recent_users)


# ---------------------------------------------------------------------- users
@admin_bp.route("/admin/users")
@login_required
@admin_required
def users():
    q = request.args.get("q", "").strip()
    query = User.query
    if q:
        like = f"%{q}%"
        query = query.filter(
            db.or_(
                User.username.ilike(like),
                User.email.ilike(like),
                User.user_id.ilike(like),
                User.support_id.ilike(like),
            )
        )
    items = query.order_by(User.created_at.desc()).limit(200).all()
    return render_template("admin/users.html", users=items, q=q)


@admin_bp.route("/admin/users/<int:user_id>")
@login_required
@admin_required
def user_detail(user_id):
    user = User.query.get_or_404(user_id)
    products = Product.query.filter_by(developer_id=user.id).all()
    licenses = License.query.filter_by(customer_user_id=user.id).all()
    audit_entries = (
        SupportAuditLog.query.filter_by(target_user_id=user.id)
        .order_by(SupportAuditLog.created_at.desc())
        .limit(20)
        .all()
    )
    return render_template(
        "admin/user_detail.html", user=user, products=products, licenses=licenses, audit_entries=audit_entries
    )


@admin_bp.route("/admin/users/<int:user_id>/toggle-suspend", methods=["POST"])
@login_required
@admin_required
def toggle_suspend(user_id):
    user = User.query.get_or_404(user_id)
    if user.id == current_user.id:
        flash("You can't suspend your own account.", "error")
        return redirect(url_for("admin.user_detail", user_id=user.id))

    user.is_suspended = not user.is_suspended
    log_admin_action('suspended_user' if user.is_suspended else 'unsuspended_user', target_label=user.username)
    db.session.commit()
    flash(f"{user.username} is now {'suspended' if user.is_suspended else 'active'}.", "info")
    return redirect(url_for("admin.user_detail", user_id=user.id))


@admin_bp.route("/admin/users/<int:user_id>/toggle-role/<role>", methods=["POST"])
@login_required
@admin_required
def toggle_role(user_id, role):
    if role not in ("is_admin", "is_support", "is_developer"):
        flash("Unknown role.", "error")
        return redirect(url_for("admin.user_detail", user_id=user_id))

    user = User.query.get_or_404(user_id)
    if role == "is_admin" and user.id == current_user.id:
        flash("You can't remove your own admin access.", "error")
        return redirect(url_for("admin.user_detail", user_id=user.id))

    setattr(user, role, not getattr(user, role))
    log_admin_action(f"toggled_{role}", target_label=f"{user.username} -> {getattr(user, role)}")
    db.session.commit()
    flash(f"Updated {user.username}'s {role.replace('is_', '')} status.", "info")
    return redirect(url_for("admin.user_detail", user_id=user.id))


# ------------------------------------------------------------------- products
@admin_bp.route("/admin/products")
@login_required
@admin_required
def products():
    q = request.args.get("q", "").strip()
    query = Product.query
    if q:
        like = f"%{q}%"
        query = query.filter(db.or_(Product.name.ilike(like), Product.product_id.ilike(like)))
    items = query.order_by(Product.created_at.desc()).limit(200).all()
    return render_template("admin/products.html", products=items, q=q)


@admin_bp.route("/admin/products/<int:product_id>/toggle-active", methods=["POST"])
@login_required
@admin_required
def toggle_product_active(product_id):
    product = Product.query.get_or_404(product_id)
    product.is_active = not product.is_active
    log_admin_action('disabled_product' if not product.is_active else 'enabled_product', target_label=product.name)
    db.session.commit()
    flash(f"{product.name} is now {'active' if product.is_active else 'disabled'}.", "info")
    return redirect(url_for("admin.products"))


# ------------------------------------------------------------------- licenses
@admin_bp.route("/admin/licenses")
@login_required
@admin_required
def licenses():
    q = request.args.get("q", "").strip()
    query = License.query
    if q:
        like = f"%{q}%"
        query = query.filter(db.or_(License.license_key.ilike(like), License.customer_email.ilike(like)))
    items = query.order_by(License.created_at.desc()).limit(200).all()
    return render_template("admin/licenses.html", licenses=items, q=q)


@admin_bp.route("/admin/licenses/<int:license_id>/revoke", methods=["POST"])
@login_required
@admin_required
def revoke_license(license_id):
    lic = License.query.get_or_404(license_id)
    lic.status = "revoked"
    log_admin_action('revoked_license', target_label=lic.license_key)
    db.session.commit()
    flash("License revoked.", "info")
    return redirect(url_for("admin.licenses"))


# ---------------------------------------------------------------------- logs
@admin_bp.route("/admin/logs")
@login_required
@admin_required
def logs():
    entries = SupportAuditLog.query.order_by(SupportAuditLog.created_at.desc()).limit(200).all()
    admin_entries = AdminActionLog.query.order_by(AdminActionLog.created_at.desc()).limit(200).all()
    return render_template("admin/logs.html", entries=entries, admin_entries=admin_entries)
