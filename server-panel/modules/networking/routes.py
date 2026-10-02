from flask import Blueprint, render_template, redirect, url_for, flash

from services import networking_service as net
from modules.networking.forms import HostnameForm, StaticIpForm
from utils.permissions import require_permission

networking_bp = Blueprint("networking", __name__, template_folder="templates")


@networking_bp.route("/networking")
@require_permission("networking.manage")
def index():
    interfaces = net.list_interfaces()
    return render_template(
        "networking_index.html",
        interfaces=interfaces,
        gateway=net.get_default_gateway(),
        dns_servers=net.get_dns_servers(),
        hostname=net.get_hostname(),
        netplan_available=net.netplan_available(),
        hostname_form=HostnameForm(),
        static_ip_form=StaticIpForm(),
    )


@networking_bp.route("/networking/hostname", methods=["POST"])
@require_permission("networking.manage")
def change_hostname():
    form = HostnameForm()
    if form.validate_on_submit():
        try:
            net.set_hostname(form.hostname.data)
            flash(f"Hostname changed to {form.hostname.data}.", "success")
        except net.NetworkingError as exc:
            flash(str(exc), "error")
    return redirect(url_for("networking.index"))


@networking_bp.route("/networking/static-ip", methods=["POST"])
@require_permission("networking.manage")
def static_ip():
    form = StaticIpForm()
    if form.validate_on_submit():
        dns_list = [d.strip() for d in form.dns_servers.data.split(",") if d.strip()]
        try:
            net.write_static_ip(form.interface.data.strip(), form.address_cidr.data.strip(),
                                 form.gateway.data.strip(), dns_list)
            net.apply_netplan()
            flash(f"Static IP applied to {form.interface.data}.", "success")
        except net.NetworkingError as exc:
            flash(str(exc), "error")
    return redirect(url_for("networking.index"))
