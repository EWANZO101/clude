from flask import Blueprint, render_template, redirect, url_for, request, flash, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models.user import User, AccountType, Role, Permission, UserRole, RolePermission
from app.models.customer import CustomerProfile
from app.models.seller import SellerProfile, SellerStatus
from app.models.audit import AuditLog
from app.models.settings import SystemSetting, EmailTemplate
from app.utils.permissions import permission_required
from app.utils.helpers import log_audit, paginate_query
from app.auth.forms import AdminSetPasswordForm

admin_bp = Blueprint("admin", __name__, template_folder="../templates/admin")


@admin_bp.before_request
@login_required
def require_staff():
    if current_user.account_type not in (AccountType.ADMIN, AccountType.STAFF):
        abort(403)


@admin_bp.route("/")
def dashboard():
    from app.models.order import Order, OrderStatus
    from app.models.equipment import CustomerEquipmentRequest, RequestStatus
    from datetime import datetime, timezone

    today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)

    stats = {
        "customers": CustomerProfile.query.count(),
        "sellers": SellerProfile.query.filter(
            SellerProfile.status.in_([SellerStatus.APPROVED, SellerStatus.ACTIVE])
        ).count(),
        "seller_applications": SellerProfile.query.filter_by(
            status=SellerStatus.APPLICATION
        ).count(),
        "staff_users": User.query.filter_by(account_type=AccountType.STAFF).count(),
        "orders_today": Order.query.filter(Order.created_at >= today_start).count(),
        "pending_orders": Order.query.filter(
            Order.status.in_([OrderStatus.PENDING, OrderStatus.AWAITING_PAYMENT])
        ).count(),
        "pending_requests": CustomerEquipmentRequest.query.filter(
            CustomerEquipmentRequest.status.in_(
                [RequestStatus.SUBMITTED, RequestStatus.UNDER_REVIEW, RequestStatus.TECHNICAL_REVIEW]
            )
        ).count(),
        "recent_audit": AuditLog.query.order_by(AuditLog.created_at.desc()).limit(10).all(),
    }
    return render_template("admin/dashboard.html", stats=stats)


def _placeholder(section_title):
    return render_template("admin/placeholder.html", section_title=section_title)


PLACEHOLDER_SECTIONS = {}

for _slug, _title in PLACEHOLDER_SECTIONS.items():
    admin_bp.add_url_rule(
        f"/{_slug.replace('_', '-')}",
        endpoint=_slug,
        view_func=lambda _title=_title: _placeholder(_title),
    )


# ---- Users / Roles / Permissions ----

@admin_bp.route("/users")
@permission_required("users.view")
def users():
    page = request.args.get("page", 1, type=int)
    q = request.args.get("q", "").strip()
    query = User.query.order_by(User.created_at.desc())
    if q:
        query = query.filter(User.email.ilike(f"%{q}%"))
    pagination = paginate_query(query, page, 25)
    return render_template("admin/users/list.html", pagination=pagination, q=q)


@admin_bp.route("/users/<int:user_id>", methods=["GET", "POST"])
@permission_required("users.edit")
def user_detail(user_id):
    user = db.session.get(User, user_id) or abort(404)
    all_roles = Role.query.order_by(Role.name).all()
    password_form = AdminSetPasswordForm()

    if request.method == "POST":
        action = request.form.get("action")
        if action == "toggle_active":
            old = user.is_active
            user.is_active = not user.is_active
            log_audit("user.active_toggled", "User", user.id, {"is_active": old}, {"is_active": user.is_active})
            db.session.commit()
            flash(f"User {'activated' if user.is_active else 'deactivated'}.", "success")
        elif action == "set_roles":
            role_ids = {int(rid) for rid in request.form.getlist("role_ids")}
            current_ids = {ur.role_id for ur in user.user_roles}
            for ur in list(user.user_roles):
                if ur.role_id not in role_ids:
                    db.session.delete(ur)
            for rid in role_ids - current_ids:
                db.session.add(UserRole(user_id=user.id, role_id=rid, granted_by_id=current_user.id))
            log_audit("user.roles_updated", "User", user.id, {"role_ids": list(current_ids)}, {"role_ids": list(role_ids)})
            db.session.commit()
            flash("Roles updated.", "success")
        elif action == "set_password":
            if password_form.validate_on_submit():
                user.set_password(password_form.new_password.data)
                user.failed_login_attempts = 0
                user.locked_until = None
                log_audit("user.password_reset_by_admin", "User", user.id)
                db.session.commit()
                flash(f"Password reset for {user.email}.", "success")
                return redirect(url_for("admin.user_detail", user_id=user.id))
            return render_template(
                "admin/users/detail.html", user=user, all_roles=all_roles, password_form=password_form
            )
        return redirect(url_for("admin.user_detail", user_id=user.id))

    return render_template("admin/users/detail.html", user=user, all_roles=all_roles, password_form=password_form)


@admin_bp.route("/roles")
@permission_required("users.edit")
def roles():
    all_roles = Role.query.order_by(Role.name).all()
    return render_template("admin/roles/list.html", roles=all_roles)


@admin_bp.route("/roles/<int:role_id>", methods=["GET", "POST"])
@permission_required("users.edit")
def role_detail(role_id):
    role = db.session.get(Role, role_id) or abort(404)
    all_permissions = Permission.query.order_by(Permission.category, Permission.code).all()

    if request.method == "POST":
        if role.is_system:
            flash("System roles cannot be modified.", "error")
            return redirect(url_for("admin.role_detail", role_id=role.id))
        perm_ids = {int(pid) for pid in request.form.getlist("permission_ids")}
        current_ids = {rp.permission_id for rp in role.permissions}
        for rp in list(role.permissions):
            if rp.permission_id not in perm_ids:
                db.session.delete(rp)
        for pid in perm_ids - current_ids:
            db.session.add(RolePermission(role_id=role.id, permission_id=pid))
        log_audit("role.permissions_updated", "Role", role.id, {"permission_ids": list(current_ids)}, {"permission_ids": list(perm_ids)})
        db.session.commit()
        flash("Permissions updated.", "success")
        return redirect(url_for("admin.role_detail", role_id=role.id))

    return render_template("admin/roles/detail.html", role=role, all_permissions=all_permissions)


@admin_bp.route("/settings", methods=["GET", "POST"])
@permission_required("settings.edit")
def settings():
    if request.method == "POST":
        maintenance = request.form.get("maintenance_mode") == "on"
        SystemSetting.set("maintenance_mode", maintenance, "Show maintenance page to non-staff visitors")

        builder_base_price = request.form.get("builder_base_price", type=float)
        builder_setup_fee = request.form.get("builder_setup_fee", type=float)
        builder_included_ips = request.form.get("builder_included_ips", type=int)
        price_per_extra_ip = request.form.get("price_per_extra_ip", type=float)
        if builder_base_price is not None:
            SystemSetting.set("builder_base_price", builder_base_price, "Base monthly price for a custom build")
        if builder_setup_fee is not None:
            SystemSetting.set("builder_setup_fee", builder_setup_fee, "One-time setup fee for a custom build")
        if builder_included_ips is not None:
            SystemSetting.set("builder_included_ips", builder_included_ips, "IP addresses included free with a custom build")
        if price_per_extra_ip is not None:
            SystemSetting.set("price_per_extra_ip", price_per_extra_ip, "Monthly price per additional IP address")

        log_audit("settings.updated", "SystemSetting", "builder_pricing", None, {"maintenance_mode": maintenance})
        db.session.commit()
        flash("Settings saved.", "success")
        return redirect(url_for("admin.settings"))

    maintenance_mode = SystemSetting.get("maintenance_mode", False)
    builder_settings = {
        "base_price": SystemSetting.get("builder_base_price", 20),
        "setup_fee": SystemSetting.get("builder_setup_fee", 0),
        "included_ips": SystemSetting.get("builder_included_ips", 1),
        "price_per_extra_ip": SystemSetting.get("price_per_extra_ip", 2),
    }
    return render_template(
        "admin/settings.html", maintenance_mode=maintenance_mode, builder_settings=builder_settings
    )


@admin_bp.route("/audit-logs")
@permission_required("audit.view")
def audit_logs():
    page = request.args.get("page", 1, type=int)
    query = AuditLog.query.order_by(AuditLog.created_at.desc())
    pagination = paginate_query(query, page, 50)
    return render_template("admin/audit_logs.html", pagination=pagination)


from app.hardware.admin_views import register_hardware_admin  # noqa: E402

register_hardware_admin(admin_bp)


# ---- Categories ----

@admin_bp.route("/categories", methods=["GET", "POST"])
@permission_required("servers.edit")
def categories():
    from app.models.server import Category
    from app.marketplace.forms import CategoryForm

    form = CategoryForm()
    if form.validate_on_submit():
        from app.utils.helpers import generate_unique_slug

        category = Category(
            name=form.name.data,
            slug=generate_unique_slug(Category, form.name.data),
            description=form.description.data,
            sort_order=form.sort_order.data or 0,
        )
        db.session.add(category)
        db.session.flush()
        log_audit("category.created", "Category", category.id, None, {"name": category.name})
        db.session.commit()
        flash("Category added.", "success")
        return redirect(url_for("admin.categories"))

    all_categories = Category.query.order_by(Category.sort_order, Category.name).all()
    return render_template("admin/categories/list.html", categories=all_categories, form=form)


@admin_bp.route("/categories/<int:category_id>/toggle", methods=["POST"])
@permission_required("servers.edit")
def category_toggle(category_id):
    from app.models.server import Category

    category = db.session.get(Category, category_id) or abort(404)
    category.is_active = not category.is_active
    log_audit("category.toggled", "Category", category.id, None, {"is_active": category.is_active})
    db.session.commit()
    flash("Category updated.", "success")
    return redirect(url_for("admin.categories"))


# ---- Servers (oversight, add/edit/delete/stock) ----

@admin_bp.route("/servers")
@permission_required("servers.view")
def servers():
    from app.models.server import Server

    page = request.args.get("page", 1, type=int)
    q = request.args.get("q", "").strip()
    query = Server.query.order_by(Server.created_at.desc())
    if q:
        query = query.filter(Server.title.ilike(f"%{q}%"))
    pagination = paginate_query(query, page, 25)
    return render_template("admin/servers/list.html", pagination=pagination, q=q)


def _seller_choices():
    return [(0, "— Platform (no seller) —")] + [
        (s.id, s.business_name) for s in SellerProfile.query.order_by(SellerProfile.business_name)
    ]


def _category_choices():
    from app.models.server import Category

    return [(0, "— None —")] + [
        (c.id, c.name) for c in Category.query.filter_by(is_active=True).order_by(Category.name)
    ]


@admin_bp.route("/servers/new", methods=["GET", "POST"])
@permission_required("servers.create")
def server_new():
    from app.models.server import Server, ServerLocation, ServerStatus
    from app.marketplace.forms import AdminServerForm
    from app.utils.helpers import generate_unique_slug

    form = AdminServerForm()
    form.seller_id.choices = _seller_choices()
    form.category_id.choices = _category_choices()

    if form.validate_on_submit():
        server = Server(slug=generate_unique_slug(Server, form.title.data))
        for field_name in (
            "title", "description", "manufacturer", "model", "sku", "serial_number", "asset_number",
            "cpu_summary", "cpu_count", "cpu_cores", "cpu_threads",
            "ram_summary", "ram_capacity_gb", "ram_slots",
            "storage_summary", "storage_type", "storage_capacity_gb", "drive_count",
            "gpu_summary", "gpu_count",
            "network_summary", "network_ports", "bandwidth_mbps", "ip_addresses_included",
            "raid_summary", "psu_count", "psu_wattage",
            "chassis_summary", "rack_units", "operating_system",
            "monthly_price", "one_time_price", "setup_fee",
        ):
            setattr(server, field_name, getattr(form, field_name).data)
        server.status = ServerStatus(form.status.data)
        server.category_id = form.category_id.data or None
        server.seller_id = form.seller_id.data or None
        if server.status == ServerStatus.PUBLISHED:
            from app.models.base import utcnow

            server.published_at = utcnow()

        db.session.add(server)
        db.session.flush()
        server.location = ServerLocation(
            server_id=server.id, country=form.country.data, region=form.region.data, city=form.city.data,
            datacenter_name=form.datacenter_name.data, datacenter_code=form.datacenter_code.data,
        )
        log_audit("server.created_by_admin", "Server", server.id, None, {"title": server.title})
        db.session.commit()
        flash("Server created.", "success")
        return redirect(url_for("admin.server_detail", server_id=server.id))

    return render_template("admin/servers/form.html", form=form, is_new=True)


@admin_bp.route("/servers/<int:server_id>/edit", methods=["GET", "POST"])
@permission_required("servers.edit")
def server_edit(server_id):
    from app.models.server import Server, ServerLocation, ServerStatus
    from app.marketplace.forms import AdminServerForm

    server = db.session.get(Server, server_id) or abort(404)
    form = AdminServerForm(obj=server)
    form.seller_id.choices = _seller_choices()
    form.category_id.choices = _category_choices()

    if request.method == "GET":
        form.seller_id.data = server.seller_id or 0
        form.category_id.data = server.category_id or 0
        if server.location:
            form.country.data = server.location.country
            form.region.data = server.location.region
            form.city.data = server.location.city
            form.datacenter_name.data = server.location.datacenter_name
            form.datacenter_code.data = server.location.datacenter_code

    if form.validate_on_submit():
        for field_name in (
            "title", "description", "manufacturer", "model", "sku", "serial_number", "asset_number",
            "cpu_summary", "cpu_count", "cpu_cores", "cpu_threads",
            "ram_summary", "ram_capacity_gb", "ram_slots",
            "storage_summary", "storage_type", "storage_capacity_gb", "drive_count",
            "gpu_summary", "gpu_count",
            "network_summary", "network_ports", "bandwidth_mbps", "ip_addresses_included",
            "raid_summary", "psu_count", "psu_wattage",
            "chassis_summary", "rack_units", "operating_system",
            "monthly_price", "one_time_price", "setup_fee",
        ):
            setattr(server, field_name, getattr(form, field_name).data)
        server.status = ServerStatus(form.status.data)
        server.category_id = form.category_id.data or None
        server.seller_id = form.seller_id.data or None

        if server.location is None:
            server.location = ServerLocation(server_id=server.id)
        server.location.country = form.country.data
        server.location.region = form.region.data
        server.location.city = form.city.data
        server.location.datacenter_name = form.datacenter_name.data
        server.location.datacenter_code = form.datacenter_code.data

        log_audit("server.updated_by_admin", "Server", server.id, None, {"title": server.title})
        db.session.commit()
        flash("Server updated.", "success")
        return redirect(url_for("admin.server_detail", server_id=server.id))

    return render_template("admin/servers/form.html", form=form, is_new=False, server=server)


@admin_bp.route("/servers/<int:server_id>/delete", methods=["POST"])
@permission_required("servers.delete")
def server_delete(server_id):
    from app.models.server import Server
    from app.models.order import OrderItem
    from app.models.configuration import ConfigurationComponent  # noqa: F401 (not related; kept for clarity)

    server = db.session.get(Server, server_id) or abort(404)

    if OrderItem.query.filter_by(server_id=server.id).first():
        flash("This server has order history and can't be deleted — deactivate it instead.", "error")
        return redirect(url_for("admin.server_detail", server_id=server.id))

    from app.models.server import Favourite
    from app.models.order import CartItem

    CartItem.query.filter_by(server_id=server.id).delete()
    Favourite.query.filter_by(server_id=server.id).delete()

    title = server.title
    db.session.delete(server)
    log_audit("server.deleted", "Server", server_id, None, {"title": title})
    db.session.commit()
    flash(f'"{title}" was deleted.', "success")
    return redirect(url_for("admin.servers"))


@admin_bp.route("/servers/<int:server_id>", methods=["GET", "POST"])
@permission_required("servers.edit")
def server_detail(server_id):
    from app.models.server import Server, ServerStatus, InventoryStatus

    server = db.session.get(Server, server_id) or abort(404)
    if request.method == "POST":
        action = request.form.get("action")
        if action == "set_status":
            new_status = request.form.get("status")
            if new_status in ServerStatus._value2member_map_:
                old = server.status
                server.status = ServerStatus(new_status)
                log_audit("server.status_changed", "Server", server.id, {"status": old.value}, {"status": new_status})
                db.session.commit()
                flash("Server status updated.", "success")
        elif action == "toggle_active":
            server.is_active = not server.is_active
            log_audit("server.toggled", "Server", server.id, None, {"is_active": server.is_active})
            db.session.commit()
            flash("Server updated.", "success")
        elif action == "set_inventory_status":
            new_status = request.form.get("inventory_status")
            if new_status in InventoryStatus._value2member_map_:
                server.set_inventory_status(InventoryStatus(new_status), changed_by_id=current_user.id, reason="Updated by admin")
                log_audit("server.inventory_status_changed", "Server", server.id, None, {"status": new_status})
                db.session.commit()
                flash("Stock status updated.", "success")
        return redirect(url_for("admin.server_detail", server_id=server.id))

    return render_template("admin/servers/detail.html", server=server, inventory_statuses=list(InventoryStatus))


@admin_bp.route("/inventory")
@permission_required("servers.view")
def seller_inventory():
    from app.models.server import Server, InventoryStatus

    page = request.args.get("page", 1, type=int)
    q = request.args.get("q", "").strip()
    query = Server.query.filter_by(is_active=True).order_by(Server.created_at.desc())
    if q:
        query = query.filter(Server.title.ilike(f"%{q}%"))
    pagination = paginate_query(query, page, 25)
    return render_template(
        "admin/servers/inventory.html", pagination=pagination, q=q, inventory_statuses=list(InventoryStatus)
    )


@admin_bp.route("/customer-servers")
@permission_required("servers.view")
def customer_servers():
    from app.models.order import OrderItem, Order, OrderItemType, OrderStatus

    page = request.args.get("page", 1, type=int)
    query = (
        OrderItem.query.join(Order)
        .filter(
            OrderItem.item_type == OrderItemType.SERVER,
            Order.status.notin_([OrderStatus.CANCELLED, OrderStatus.REFUNDED]),
        )
        .order_by(OrderItem.created_at.desc())
    )
    pagination = paginate_query(query, page, 25)
    return render_template("admin/customer_servers.html", pagination=pagination)


@admin_bp.route("/seller-orders")
@permission_required("orders.view")
def seller_orders():
    from app.models.order import Order

    rows = (
        db.session.query(
            SellerProfile,
            db.func.count(Order.id).label("order_count"),
            db.func.coalesce(db.func.sum(Order.total), 0).label("total_revenue"),
        )
        .join(Order, Order.seller_id == SellerProfile.id)
        .group_by(SellerProfile.id)
        .order_by(db.func.sum(Order.total).desc())
        .all()
    )
    return render_template("admin/seller_orders.html", rows=rows)


# ---- Seller applications ----

@admin_bp.route("/sellers")
@permission_required("sellers.view")
def seller_applications():
    page = request.args.get("page", 1, type=int)
    query = SellerProfile.query.order_by(SellerProfile.created_at.desc())
    pagination = paginate_query(query, page, 25)
    return render_template("admin/sellers/list.html", pagination=pagination)


@admin_bp.route("/sellers/<int:seller_id>", methods=["GET", "POST"])
@permission_required("sellers.approve")
def seller_detail(seller_id):
    seller = db.session.get(SellerProfile, seller_id) or abort(404)
    if request.method == "POST":
        action = request.form.get("action")
        old_status = seller.status
        if action == "approve":
            from app.models.base import utcnow

            seller.status = SellerStatus.ACTIVE
            seller.verified_at = utcnow()
        elif action == "reject":
            seller.status = SellerStatus.REJECTED
            seller.rejection_reason = request.form.get("reason", "")
        elif action == "request_info":
            seller.status = SellerStatus.INFORMATION_REQUIRED
            seller.information_requested = request.form.get("reason", "")
        elif action == "suspend":
            seller.status = SellerStatus.SUSPENDED
        log_audit("seller.status_changed", "SellerProfile", seller.id, {"status": old_status.value}, {"status": seller.status.value})
        db.session.commit()
        flash("Seller updated.", "success")
        return redirect(url_for("admin.seller_detail", seller_id=seller.id))

    return render_template("admin/sellers/detail.html", seller=seller)


# ---- Custom configurations (oversight) ----

@admin_bp.route("/configurations")
@permission_required("servers.view")
def configurations():
    from app.models.configuration import ServerConfiguration

    page = request.args.get("page", 1, type=int)
    query = ServerConfiguration.query.order_by(ServerConfiguration.created_at.desc())
    pagination = paginate_query(query, page, 25)
    return render_template("admin/configurations/list.html", pagination=pagination)


# ---- Compatibility rules ----

@admin_bp.route("/compatibility-rules", methods=["GET", "POST"])
@permission_required("servers.edit")
def compatibility_rules():
    from app.models.configuration import CompatibilityRule
    from app.marketplace.forms import CompatibilityRuleForm

    form = CompatibilityRuleForm()
    if form.validate_on_submit():
        rule = CompatibilityRule(
            name=form.name.data,
            description=form.description.data,
            rule_type=form.rule_type.data,
            is_active=form.is_active.data,
        )
        db.session.add(rule)
        db.session.flush()
        log_audit("compatibility_rule.created", "CompatibilityRule", rule.id, None, {"name": rule.name})
        db.session.commit()
        flash("Rule added.", "success")
        return redirect(url_for("admin.compatibility_rules"))

    rules = CompatibilityRule.query.order_by(CompatibilityRule.name).all()
    return render_template("admin/rules/compatibility_list.html", rules=rules, form=form)


@admin_bp.route("/compatibility-rules/<int:rule_id>/toggle", methods=["POST"])
@permission_required("servers.edit")
def compatibility_rule_toggle(rule_id):
    from app.models.configuration import CompatibilityRule

    rule = db.session.get(CompatibilityRule, rule_id) or abort(404)
    rule.is_active = not rule.is_active
    log_audit("compatibility_rule.toggled", "CompatibilityRule", rule.id, None, {"is_active": rule.is_active})
    db.session.commit()
    flash("Rule updated.", "success")
    return redirect(url_for("admin.compatibility_rules"))


# ---- Pricing rules ----

@admin_bp.route("/pricing-rules", methods=["GET", "POST"])
@permission_required("servers.edit")
def pricing_rules():
    from app.models.configuration import PricingRule

    from app.marketplace.forms import PricingRuleForm

    form = PricingRuleForm()
    if form.validate_on_submit():
        rule = PricingRule(
            name=form.name.data,
            component_type=form.component_type.data or None,
            method=form.method.data,
            value=form.value.data or 0,
            is_active=form.is_active.data,
        )
        db.session.add(rule)
        db.session.flush()
        log_audit("pricing_rule.created", "PricingRule", rule.id, None, {"name": rule.name})
        db.session.commit()
        flash("Pricing rule added.", "success")
        return redirect(url_for("admin.pricing_rules"))

    rules = PricingRule.query.order_by(PricingRule.name).all()
    return render_template("admin/rules/pricing_list.html", rules=rules, form=form)


@admin_bp.route("/pricing-rules/<int:rule_id>/toggle", methods=["POST"])
@permission_required("servers.edit")
def pricing_rule_toggle(rule_id):
    from app.models.configuration import PricingRule

    rule = db.session.get(PricingRule, rule_id) or abort(404)
    rule.is_active = not rule.is_active
    log_audit("pricing_rule.toggled", "PricingRule", rule.id, None, {"is_active": rule.is_active})
    db.session.commit()
    flash("Pricing rule updated.", "success")
    return redirect(url_for("admin.pricing_rules"))


# ---- Orders (oversight) ----

@admin_bp.route("/orders")
@permission_required("orders.view")
def orders():
    from app.models.order import Order, OrderStatus

    page = request.args.get("page", 1, type=int)
    status_filter = request.args.get("status", "")
    seller_filter = request.args.get("seller", type=int)
    query = Order.query.order_by(Order.created_at.desc())
    if status_filter and status_filter in OrderStatus._value2member_map_:
        query = query.filter_by(status=OrderStatus(status_filter))
    if seller_filter:
        query = query.filter_by(seller_id=seller_filter)
    pagination = paginate_query(query, page, 25)
    return render_template(
        "admin/orders/list.html", pagination=pagination, status_filter=status_filter, statuses=list(OrderStatus),
        seller_filter=seller_filter,
    )


@admin_bp.route("/orders/<int:order_id>", methods=["GET", "POST"])
@permission_required("orders.edit")
def order_detail(order_id):
    from app.models.order import Order, OrderStatus, OrderPaymentStatus

    order = db.session.get(Order, order_id) or abort(404)

    if request.method == "POST":
        action = request.form.get("action")
        if action == "set_status":
            new_status = request.form.get("status")
            if new_status in OrderStatus._value2member_map_:
                order.set_status(OrderStatus(new_status), changed_by_id=current_user.id, note="Updated by admin")
                log_audit("order.status_changed", "Order", order.id, None, {"status": new_status})
        elif action == "set_payment_status":
            new_status = request.form.get("payment_status")
            if new_status in OrderPaymentStatus._value2member_map_:
                old = order.payment_status
                order.payment_status = OrderPaymentStatus(new_status)
                log_audit("order.payment_status_changed", "Order", order.id, {"payment_status": old.value}, {"payment_status": new_status})
        db.session.commit()
        flash("Order updated.", "success")
        return redirect(url_for("admin.order_detail", order_id=order.id))

    return render_template(
        "admin/orders/detail.html", order=order, statuses=list(OrderStatus), payment_statuses=list(OrderPaymentStatus)
    )


# ---- Invoices ----

@admin_bp.route("/invoices")
@permission_required("invoices.view")
def invoices():
    from app.models.finance import Invoice

    page = request.args.get("page", 1, type=int)
    query = Invoice.query.order_by(Invoice.created_at.desc())
    pagination = paginate_query(query, page, 25)
    return render_template("admin/invoices/list.html", pagination=pagination)


@admin_bp.route("/invoices/<int:invoice_id>")
@permission_required("invoices.view")
def invoice_detail(invoice_id):
    from app.models.finance import Invoice

    invoice = db.session.get(Invoice, invoice_id) or abort(404)
    return render_template("admin/invoices/detail.html", invoice=invoice)


# ---- Payments / Transactions ----

@admin_bp.route("/payments")
@permission_required("payments.view")
def payments():
    from app.models.finance import Payment

    page = request.args.get("page", 1, type=int)
    query = Payment.query.order_by(Payment.created_at.desc())
    pagination = paginate_query(query, page, 25)
    return render_template("admin/payments/list.html", pagination=pagination)


@admin_bp.route("/payments/<int:payment_id>/refund", methods=["POST"])
@permission_required("payments.refund")
def payment_refund(payment_id):
    from app.models.finance import Payment, PaymentStatus
    from app.payments.service import refund_payment

    payment = db.session.get(Payment, payment_id) or abort(404)
    if payment.status != PaymentStatus.COMPLETED:
        flash("Only completed payments can be refunded.", "error")
        return redirect(url_for("admin.payments"))

    success = refund_payment(payment, current_user)
    flash("Payment refunded." if success else "Refund failed.", "success" if success else "error")
    return redirect(url_for("admin.payments"))


@admin_bp.route("/transactions")
@permission_required("payments.view")
def transactions():
    from app.models.finance import PaymentTransaction

    page = request.args.get("page", 1, type=int)
    query = PaymentTransaction.query.order_by(PaymentTransaction.created_at.desc())
    pagination = paginate_query(query, page, 50)
    return render_template("admin/payments/transactions.html", pagination=pagination)


# ---- Seller payouts ----

@admin_bp.route("/payouts")
@permission_required("payments.view")
def payouts():
    from app.models.finance import SellerPayout

    page = request.args.get("page", 1, type=int)
    query = SellerPayout.query.order_by(SellerPayout.created_at.desc())
    pagination = paginate_query(query, page, 25)
    return render_template("admin/payouts/list.html", pagination=pagination)


@admin_bp.route("/payouts/<int:payout_id>/mark-paid", methods=["POST"])
@permission_required("payments.refund")
def payout_mark_paid(payout_id):
    from app.models.finance import SellerPayout
    from app.models.base import utcnow

    payout = db.session.get(SellerPayout, payout_id) or abort(404)
    payout.status = "paid"
    payout.paid_at = utcnow()
    log_audit("payout.marked_paid", "SellerPayout", payout.id, None, {"net_amount": str(payout.net_amount)})
    db.session.commit()
    flash("Payout marked as paid.", "success")
    return redirect(url_for("admin.payouts"))


# ---- Coupons ----

@admin_bp.route("/coupons", methods=["GET", "POST"])
@permission_required("settings.edit")
def coupons():
    from app.models.finance import Coupon
    from app.finance.forms import CouponForm

    form = CouponForm()
    if form.validate_on_submit():
        coupon = Coupon(
            code=form.code.data.strip().upper(),
            description=form.description.data,
            discount_type=form.discount_type.data,
            value=form.value.data,
            max_uses=form.max_uses.data or None,
            is_active=form.is_active.data,
        )
        db.session.add(coupon)
        db.session.flush()
        log_audit("coupon.created", "Coupon", coupon.id, None, {"code": coupon.code})
        db.session.commit()
        flash("Coupon added.", "success")
        return redirect(url_for("admin.coupons"))

    all_coupons = Coupon.query.order_by(Coupon.created_at.desc()).all()
    return render_template("admin/coupons/list.html", coupons=all_coupons, form=form)


@admin_bp.route("/coupons/<int:coupon_id>/toggle", methods=["POST"])
@permission_required("settings.edit")
def coupon_toggle(coupon_id):
    from app.models.finance import Coupon

    coupon = db.session.get(Coupon, coupon_id) or abort(404)
    coupon.is_active = not coupon.is_active
    log_audit("coupon.toggled", "Coupon", coupon.id, None, {"is_active": coupon.is_active})
    db.session.commit()
    flash("Coupon updated.", "success")
    return redirect(url_for("admin.coupons"))


@admin_bp.route("/email-templates")
@permission_required("settings.view")
def email_templates():
    templates = EmailTemplate.query.order_by(EmailTemplate.code).all()
    return render_template("admin/email_templates/list.html", templates=templates)


@admin_bp.route("/email-templates/<int:template_id>", methods=["GET", "POST"])
@permission_required("settings.edit")
def email_template_detail(template_id):
    tmpl = db.session.get(EmailTemplate, template_id) or abort(404)
    if request.method == "POST":
        tmpl.subject = request.form.get("subject", tmpl.subject)
        tmpl.body_html = request.form.get("body_html", tmpl.body_html)
        tmpl.is_active = request.form.get("is_active") == "on"
        log_audit("email_template.updated", "EmailTemplate", tmpl.id, None, {"code": tmpl.code})
        db.session.commit()
        flash("Email template saved.", "success")
        return redirect(url_for("admin.email_template_detail", template_id=tmpl.id))
    return render_template("admin/email_templates/detail.html", tmpl=tmpl)


@admin_bp.route("/api-keys", methods=["GET", "POST"])
@permission_required("api.manage")
def api_keys():
    from app.models.api import ApiKey
    from app.models.seller import SellerProfile

    new_raw_key = None
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        name = request.form.get("name", "API Key")
        scopes_raw = request.form.get("scopes", "")
        scopes = [s.strip() for s in scopes_raw.split(",") if s.strip()]

        user = User.query.filter_by(email=email).first()
        if not user:
            flash("No user found with that email.", "error")
        else:
            seller = SellerProfile.query.filter_by(user_id=user.id).first()
            api_key, new_raw_key = ApiKey.generate(
                user_id=user.id, name=name, scopes=scopes, seller_id=seller.id if seller else None
            )
            db.session.add(api_key)
            log_audit("api_key.created", "ApiKey", None, None, {"user_id": user.id})
            db.session.commit()
            flash("API key created. Copy it now — it will not be shown again.", "success")

    keys = ApiKey.query.order_by(ApiKey.created_at.desc()).all()
    return render_template("admin/api/keys.html", keys=keys, new_raw_key=new_raw_key)


@admin_bp.route("/api-keys/<int:key_id>/revoke", methods=["POST"])
@permission_required("api.manage")
def api_key_revoke(key_id):
    from app.models.api import ApiKey
    from app.models.base import utcnow

    api_key = db.session.get(ApiKey, key_id) or abort(404)
    api_key.is_active = False
    api_key.revoked_at = utcnow()
    log_audit("api_key.revoked", "ApiKey", api_key.id)
    db.session.commit()
    flash("API key revoked.", "success")
    return redirect(url_for("admin.api_keys"))


@admin_bp.route("/webhooks")
@permission_required("api.manage")
def webhooks():
    from app.models.api import Webhook

    all_webhooks = Webhook.query.order_by(Webhook.created_at.desc()).all()
    return render_template("admin/api/webhooks.html", webhooks=all_webhooks)


@admin_bp.route("/api-logs")
@permission_required("api.manage")
def api_logs():
    from app.models.api import ApiLog

    page = request.args.get("page", 1, type=int)
    query = ApiLog.query.order_by(ApiLog.created_at.desc())
    pagination = paginate_query(query, page, 50)
    return render_template("admin/api/logs.html", pagination=pagination)


@admin_bp.route("/notifications")
@permission_required("settings.view")
def notifications():
    from app.models.notification import Notification

    page = request.args.get("page", 1, type=int)
    query = Notification.query.order_by(Notification.created_at.desc())
    pagination = paginate_query(query, page, 50)
    return render_template("admin/notifications/list.html", pagination=pagination)


from app.equipment.admin_views import register_admin_equipment_views  # noqa: E402
from app.shipping.admin_views import register_admin_shipping_views  # noqa: E402
from app.infrastructure.admin_views import register_admin_infrastructure_views  # noqa: E402
from app.chat.admin_views import register_admin_chat_views  # noqa: E402
from app.support.admin_views import register_admin_support_views  # noqa: E402
from app.integrations.admin_views import register_admin_integration_views  # noqa: E402

register_admin_equipment_views(admin_bp)
register_admin_shipping_views(admin_bp)
register_admin_infrastructure_views(admin_bp)
register_admin_chat_views(admin_bp)
register_admin_support_views(admin_bp)
register_admin_integration_views(admin_bp)
