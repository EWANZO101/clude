from flask import render_template, redirect, url_for, request, flash, abort
from flask_login import current_user

from app.extensions import db
from app.models.server import (
    Server,
    ServerLocation,
    ServerComponent,
    ServerImage,
    Category,
    ServerStatus,
    InventoryStatus,
    ComponentType,
)
from app.hardware.registry import HARDWARE_REGISTRY
from app.marketplace.forms import ServerForm, ServerComponentForm, ServerImageForm
from app.utils.helpers import generate_unique_slug, log_audit, paginate_query
from app.utils.uploads import save_public_image


def _active_seller_or_redirect():
    profile = current_user.seller_profile
    if profile is None or profile.status.value not in ("approved", "active"):
        return None
    return profile


def _owned_server_or_404(server_id, seller_id):
    server = db.session.get(Server, server_id)
    if server is None or server.seller_id != seller_id:
        abort(404)
    return server


def _apply_form_to_server(form, server):
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
    if server.status == ServerStatus.PUBLISHED and server.published_at is None:
        from app.models.base import utcnow

        server.published_at = utcnow()


def _apply_form_to_location(form, server):
    if server.location is None:
        server.location = ServerLocation(server_id=server.id)
    loc = server.location
    loc.country = form.country.data
    loc.region = form.region.data
    loc.city = form.city.data
    loc.datacenter_name = form.datacenter_name.data
    loc.datacenter_code = form.datacenter_code.data


def register_seller_server_views(seller_bp):
    @seller_bp.route("/servers")
    def servers():
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        page = request.args.get("page", 1, type=int)
        query = Server.query.filter_by(seller_id=profile.id).order_by(Server.created_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("seller/servers/list.html", pagination=pagination)

    @seller_bp.route("/servers/new", methods=["GET", "POST"])
    def server_new():
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))

        form = ServerForm()
        form.category_id.choices = [(0, "— None —")] + [
            (c.id, c.name) for c in Category.query.filter_by(is_active=True).order_by(Category.name)
        ]

        if form.validate_on_submit():
            server = Server(seller_id=profile.id, slug=generate_unique_slug(Server, form.title.data))
            _apply_form_to_server(form, server)
            db.session.add(server)
            db.session.flush()
            _apply_form_to_location(form, server)
            log_audit("server.created", "Server", server.id, None, {"title": server.title})
            db.session.commit()
            flash("Server listing created.", "success")
            return redirect(url_for("seller.server_edit", server_id=server.id))

        return render_template("seller/servers/form.html", form=form, is_new=True)

    @seller_bp.route("/servers/<int:server_id>", methods=["GET", "POST"])
    def server_edit(server_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        server = _owned_server_or_404(server_id, profile.id)

        form = ServerForm(obj=server)
        form.category_id.choices = [(0, "— None —")] + [
            (c.id, c.name) for c in Category.query.filter_by(is_active=True).order_by(Category.name)
        ]
        if request.method == "GET" and server.location:
            form.country.data = server.location.country
            form.region.data = server.location.region
            form.city.data = server.location.city
            form.datacenter_name.data = server.location.datacenter_name
            form.datacenter_code.data = server.location.datacenter_code

        if form.validate_on_submit():
            _apply_form_to_server(form, server)
            _apply_form_to_location(form, server)
            log_audit("server.updated", "Server", server.id, None, {"title": server.title})
            db.session.commit()
            flash("Changes saved.", "success")
            return redirect(url_for("seller.server_edit", server_id=server.id))

        return render_template(
            "seller/servers/form.html", form=form, is_new=False, server=server
        )

    @seller_bp.route("/servers/<int:server_id>/toggle", methods=["POST"])
    def server_toggle(server_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        server = _owned_server_or_404(server_id, profile.id)
        server.is_active = not server.is_active
        log_audit("server.toggled", "Server", server.id, None, {"is_active": server.is_active})
        db.session.commit()
        flash(f"Server {'activated' if server.is_active else 'deactivated'}.", "success")
        return redirect(url_for("seller.servers"))

    @seller_bp.route("/servers/<int:server_id>/components", methods=["GET", "POST"])
    def server_components(server_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        server = _owned_server_or_404(server_id, profile.id)

        form = ServerComponentForm()
        form.component_type.choices = [(ct.value, entry["label"]) for ct, entry in
                                        ((ct, HARDWARE_REGISTRY[ct.value]) for ct in ComponentType)]
        selected_type = request.values.get("component_type") or form.component_type.data or ComponentType.CPU.value
        hw_model = HARDWARE_REGISTRY[selected_type]["model"]
        form.hardware_id.choices = [
            (h.id, h.model_name) for h in hw_model.query.filter_by(is_active=True).order_by(hw_model.model_name)
        ]

        if form.validate_on_submit():
            component = ServerComponent(
                server_id=server.id,
                component_type=ComponentType(form.component_type.data),
                hardware_id=form.hardware_id.data,
                quantity=form.quantity.data,
                label_override=form.label_override.data,
            )
            db.session.add(component)
            log_audit("server.component_added", "Server", server.id, None, {"component_type": selected_type})
            db.session.commit()
            flash("Component added.", "success")
            return redirect(url_for("seller.server_components", server_id=server.id))

        return render_template(
            "seller/servers/components.html", server=server, form=form, selected_type=selected_type
        )

    @seller_bp.route("/servers/<int:server_id>/components/<int:component_id>/delete", methods=["POST"])
    def server_component_delete(server_id, component_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        server = _owned_server_or_404(server_id, profile.id)
        component = db.session.get(ServerComponent, component_id)
        if component is None or component.server_id != server.id:
            abort(404)
        db.session.delete(component)
        log_audit("server.component_removed", "Server", server.id, None, None)
        db.session.commit()
        flash("Component removed.", "success")
        return redirect(url_for("seller.server_components", server_id=server.id))

    @seller_bp.route("/servers/<int:server_id>/images", methods=["GET", "POST"])
    def server_images(server_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        server = _owned_server_or_404(server_id, profile.id)

        form = ServerImageForm()
        if form.validate_on_submit():
            path, error = save_public_image(form.image.data, f"servers/{server.id}")
            if error:
                flash(error, "error")
            else:
                is_first = len(server.images) == 0
                db.session.add(
                    ServerImage(
                        server_id=server.id,
                        image_path=path,
                        alt_text=form.alt_text.data,
                        is_primary=is_first,
                        sort_order=len(server.images),
                    )
                )
                log_audit("server.image_added", "Server", server.id, None, None)
                db.session.commit()
                flash("Image uploaded.", "success")
            return redirect(url_for("seller.server_images", server_id=server.id))

        return render_template("seller/servers/images.html", server=server, form=form)

    @seller_bp.route("/servers/<int:server_id>/images/<int:image_id>/delete", methods=["POST"])
    def server_image_delete(server_id, image_id):
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))
        server = _owned_server_or_404(server_id, profile.id)
        image = db.session.get(ServerImage, image_id)
        if image is None or image.server_id != server.id:
            abort(404)
        db.session.delete(image)
        log_audit("server.image_removed", "Server", server.id, None, None)
        db.session.commit()
        flash("Image removed.", "success")
        return redirect(url_for("seller.server_images", server_id=server.id))

    @seller_bp.route("/inventory", methods=["GET", "POST"])
    def inventory():
        profile = _active_seller_or_redirect()
        if profile is None:
            return redirect(url_for("seller.dashboard"))

        if request.method == "POST":
            server = _owned_server_or_404(request.form.get("server_id", type=int), profile.id)
            new_status = request.form.get("inventory_status")
            if new_status in InventoryStatus._value2member_map_:
                server.set_inventory_status(InventoryStatus(new_status), changed_by_id=current_user.id)
                log_audit("server.inventory_status_changed", "Server", server.id, None, {"status": new_status})
                db.session.commit()
                flash("Inventory status updated.", "success")
            return redirect(url_for("seller.inventory"))

        servers = Server.query.filter_by(seller_id=profile.id).order_by(Server.title).all()
        return render_template(
            "seller/servers/inventory.html", servers=servers, statuses=list(InventoryStatus)
        )
