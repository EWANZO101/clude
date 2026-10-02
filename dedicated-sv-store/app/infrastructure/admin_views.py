from flask import render_template, redirect, url_for, request, flash, abort

from app.extensions import db
from app.models.infrastructure import Datacenter, Rack, RackAssignment, PowerAssignment, NetworkAssignment
from app.models.equipment import CustomerEquipmentItem, CustomerEquipmentRequest
from app.infrastructure.forms import (
    DatacenterForm,
    RackForm,
    RackAssignmentForm,
    PowerAssignmentForm,
    NetworkAssignmentForm,
)
from app.utils.helpers import log_audit, paginate_query
from app.utils.permissions import permission_required
from flask_login import current_user


def register_admin_infrastructure_views(admin_bp):
    @admin_bp.route("/datacenters", methods=["GET", "POST"])
    @permission_required("infrastructure.edit")
    def datacenters():
        form = DatacenterForm()
        if form.validate_on_submit():
            dc = Datacenter()
            form.populate_obj(dc)
            db.session.add(dc)
            db.session.flush()
            log_audit("datacenter.created", "Datacenter", dc.id, None, {"code": dc.code})
            db.session.commit()
            flash("Datacenter added.", "success")
            return redirect(url_for("admin.datacenters"))

        all_dcs = Datacenter.query.order_by(Datacenter.name).all()
        return render_template("admin/infrastructure/datacenters.html", datacenters=all_dcs, form=form)

    @admin_bp.route("/datacenters/<int:datacenter_id>/edit", methods=["GET", "POST"])
    @permission_required("infrastructure.edit")
    def datacenter_edit(datacenter_id):
        dc = db.session.get(Datacenter, datacenter_id) or abort(404)
        form = DatacenterForm(obj=dc)
        if form.validate_on_submit():
            before = {"name": dc.name, "code": dc.code, "is_active": dc.is_active}
            form.populate_obj(dc)
            log_audit("datacenter.updated", "Datacenter", dc.id, before, {"code": dc.code})
            db.session.commit()
            flash("Datacenter updated.", "success")
            return redirect(url_for("admin.datacenters"))

        return render_template("admin/infrastructure/datacenter_form.html", form=form, dc=dc)

    @admin_bp.route("/datacenters/<int:datacenter_id>/toggle-active", methods=["POST"])
    @permission_required("infrastructure.edit")
    def datacenter_toggle_active(datacenter_id):
        dc = db.session.get(Datacenter, datacenter_id) or abort(404)
        dc.is_active = not dc.is_active
        log_audit("datacenter.toggled_active", "Datacenter", dc.id, None, {"is_active": dc.is_active})
        db.session.commit()
        flash("Datacenter disabled." if not dc.is_active else "Datacenter enabled.", "success")
        return redirect(url_for("admin.datacenters"))

    @admin_bp.route("/datacenters/<int:datacenter_id>/delete", methods=["POST"])
    @permission_required("infrastructure.edit")
    def datacenter_delete(datacenter_id):
        dc = db.session.get(Datacenter, datacenter_id) or abort(404)

        if dc.racks:
            flash("This datacenter has racks assigned — remove or reassign them first, or disable it instead.", "error")
            return redirect(url_for("admin.datacenters"))

        log_audit("datacenter.deleted", "Datacenter", dc.id, {"code": dc.code}, None)
        db.session.delete(dc)
        db.session.commit()
        flash("Datacenter deleted.", "success")
        return redirect(url_for("admin.datacenters"))

    @admin_bp.route("/racks", methods=["GET", "POST"])
    @permission_required("infrastructure.edit")
    def racks():
        form = RackForm()
        form.datacenter_id.choices = [(d.id, d.name) for d in Datacenter.query.filter_by(is_active=True).order_by(Datacenter.name)]
        if form.validate_on_submit():
            rack = Rack()
            form.populate_obj(rack)
            db.session.add(rack)
            db.session.flush()
            log_audit("rack.created", "Rack", rack.id, None, {"name": rack.name})
            db.session.commit()
            flash("Rack added.", "success")
            return redirect(url_for("admin.racks"))

        all_racks = Rack.query.order_by(Rack.datacenter_id, Rack.name).all()
        return render_template("admin/infrastructure/racks.html", racks=all_racks, form=form)

    @admin_bp.route("/networks")
    @permission_required("infrastructure.view")
    def networks():
        page = request.args.get("page", 1, type=int)
        query = NetworkAssignment.query.order_by(NetworkAssignment.assigned_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("admin/infrastructure/networks.html", pagination=pagination)

    @admin_bp.route("/power")
    @permission_required("infrastructure.view")
    def power():
        page = request.args.get("page", 1, type=int)
        query = PowerAssignment.query.order_by(PowerAssignment.assigned_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("admin/infrastructure/power.html", pagination=pagination)

    @admin_bp.route("/ip-addresses")
    @permission_required("infrastructure.view")
    def ip_addresses():
        page = request.args.get("page", 1, type=int)
        query = NetworkAssignment.query.filter(
            db.or_(NetworkAssignment.public_ipv4.isnot(None), NetworkAssignment.public_ipv6.isnot(None))
        ).order_by(NetworkAssignment.assigned_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("admin/infrastructure/ip_addresses.html", pagination=pagination)

    @admin_bp.route("/requests/<int:request_id>/items/<int:item_id>/deploy", methods=["GET", "POST"])
    @permission_required("infrastructure.edit")
    def item_deploy(request_id, item_id):
        req = db.session.get(CustomerEquipmentRequest, request_id) or abort(404)
        item = db.session.get(CustomerEquipmentItem, item_id)
        if item is None or item.request_id != req.id:
            abort(404)

        rack_assignment = RackAssignment.query.filter_by(equipment_item_id=item.id).first()
        power_assignment = PowerAssignment.query.filter_by(equipment_item_id=item.id).first()
        network_assignment = NetworkAssignment.query.filter_by(equipment_item_id=item.id).first()

        rack_form = RackAssignmentForm(obj=rack_assignment, prefix="rack")
        rack_form.rack_id.choices = [
            (r.id, f"{r.datacenter.code}/{r.name}") for r in Rack.query.filter_by(is_active=True).order_by(Rack.name)
        ]
        power_form = PowerAssignmentForm(obj=power_assignment, prefix="power")
        network_form = NetworkAssignmentForm(obj=network_assignment, prefix="network")

        if request.method == "POST":
            action = request.form.get("action")
            if action == "assign_rack" and rack_form.validate_on_submit():
                if rack_assignment is None:
                    rack_assignment = RackAssignment(equipment_item_id=item.id)
                    db.session.add(rack_assignment)
                rack_form.populate_obj(rack_assignment)
                rack_assignment.assigned_by_id = current_user.id
                log_audit("equipment_item.rack_assigned", "CustomerEquipmentItem", item.id)
            elif action == "assign_power" and power_form.validate_on_submit():
                if power_assignment is None:
                    power_assignment = PowerAssignment(equipment_item_id=item.id)
                    db.session.add(power_assignment)
                power_form.populate_obj(power_assignment)
                power_assignment.assigned_by_id = current_user.id
                log_audit("equipment_item.power_assigned", "CustomerEquipmentItem", item.id)
            elif action == "assign_network" and network_form.validate_on_submit():
                if network_assignment is None:
                    network_assignment = NetworkAssignment(equipment_item_id=item.id)
                    db.session.add(network_assignment)
                network_form.populate_obj(network_assignment)
                network_assignment.assigned_by_id = current_user.id
                log_audit("equipment_item.network_assigned", "CustomerEquipmentItem", item.id)
            db.session.commit()
            flash("Assignment saved.", "success")
            return redirect(url_for("admin.item_deploy", request_id=req.id, item_id=item.id))

        return render_template(
            "admin/infrastructure/deploy_form.html", req=req, item=item,
            rack_form=rack_form, power_form=power_form, network_form=network_form,
            rack_assignment=rack_assignment, power_assignment=power_assignment, network_assignment=network_assignment,
        )
