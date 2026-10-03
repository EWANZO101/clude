from flask import Blueprint, render_template, redirect, url_for, flash, request, current_app

from services import firewall_service as fw
from modules.firewall.forms import OpenPortForm, IpRuleForm, SshWhitelistForm
from utils.permissions import require_permission
from config import persist_ssh_whitelist

firewall_bp = Blueprint("firewall", __name__, template_folder="templates")


@firewall_bp.route("/firewall")
@require_permission("firewall.manage")
def index():
    installed = fw.is_installed()
    status = None
    ssh_whitelist = []
    categorized = {"port_rules": [], "ip_rules": [], "other_rules": [], "ssh_catchall_active": False}
    error = None
    if installed:
        try:
            status = fw.get_status()
            numbered_rules = fw.get_numbered_rules()
            ssh_whitelist = fw.list_ssh_whitelist()
            categorized = fw.categorize_rules(numbered_rules)
        except fw.FirewallError as exc:
            error = str(exc)

    return render_template(
        "firewall_index.html",
        installed=installed,
        status=status,
        ssh_whitelist=ssh_whitelist,
        port_rules=categorized["port_rules"],
        ip_rules=categorized["ip_rules"],
        other_rules=categorized["other_rules"],
        ssh_catchall_active=categorized["ssh_catchall_active"],
        error=error,
        open_port_form=OpenPortForm(),
        ip_form=IpRuleForm(),
        ssh_form=SshWhitelistForm(),
    )


@firewall_bp.route("/firewall/enable", methods=["POST"])
@require_permission("firewall.manage")
def enable():
    try:
        fw.enable()
        flash("Firewall enabled.", "success")
    except fw.FirewallError as exc:
        flash(str(exc), "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/disable", methods=["POST"])
@require_permission("firewall.manage")
def disable():
    try:
        fw.disable()
        flash("Firewall disabled.", "success")
    except fw.FirewallError as exc:
        flash(str(exc), "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/open-port", methods=["POST"])
@require_permission("firewall.manage")
def open_port():
    form = OpenPortForm()
    if form.validate_on_submit():
        try:
            fw.open_port(form.port.data, form.protocol.data, form.description.data)
            flash(f"Opened {form.port.data}/{form.protocol.data}.", "success")
        except fw.FirewallError as exc:
            flash(str(exc), "error")
    else:
        flash("Invalid port submission.", "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/close-port", methods=["POST"])
@require_permission("firewall.manage")
def close_port():
    port = request.form.get("port", "")
    protocol = request.form.get("protocol", "tcp")
    try:
        fw.close_port(port, protocol)
        flash(f"Closed {port}/{protocol}.", "success")
    except fw.FirewallError as exc:
        flash(str(exc), "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/allow-ip", methods=["POST"])
@require_permission("firewall.manage")
def allow_ip():
    form = IpRuleForm()
    if form.validate_on_submit():
        try:
            fw.allow_ip(form.ip.data)
            flash(f"Allowed {form.ip.data}.", "success")
        except fw.FirewallError as exc:
            flash(str(exc), "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/block-ip", methods=["POST"])
@require_permission("firewall.manage")
def block_ip():
    form = IpRuleForm()
    if form.validate_on_submit():
        try:
            fw.block_ip(form.ip.data)
            flash(f"Blocked {form.ip.data}.", "success")
        except fw.FirewallError as exc:
            flash(str(exc), "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/rule/<int:number>/delete", methods=["POST"])
@require_permission("firewall.manage")
def delete_rule(number):
    try:
        fw.delete_rule_by_number(number)
        flash(f"Deleted rule #{number}.", "success")
    except fw.FirewallError as exc:
        flash(str(exc), "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/rule/<int:number>/switch", methods=["POST"])
@require_permission("firewall.manage")
def switch_rule(number):
    ip = request.form.get("ip", "").strip()
    target = request.form.get("target", "")
    try:
        fw.switch_ip_rule(number, ip, target)
        flash(f"{ip} set to {target}.", "success")
    except fw.FirewallError as exc:
        flash(str(exc), "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/ssh-whitelist/add", methods=["POST"])
@require_permission("firewall.manage")
def ssh_whitelist_add():
    form = SshWhitelistForm()
    if form.validate_on_submit():
        ip = form.ip.data.strip()
        try:
            fw.add_ssh_whitelist_ip(ip)
            existing_ips = list(current_app.config.get("SSH_WHITELIST_IPS", []))
            if ip not in existing_ips:
                existing_ips.append(ip)
            persist_ssh_whitelist(existing_ips)
            current_app.config["SSH_WHITELIST_IPS"] = existing_ips
            flash(f"{ip} whitelisted for SSH.", "success")
        except fw.FirewallError as exc:
            flash(str(exc), "error")
    else:
        flash("Invalid IP.", "error")
    return redirect(url_for("firewall.index"))


@firewall_bp.route("/firewall/ssh-whitelist/remove", methods=["POST"])
@require_permission("firewall.manage")
def ssh_whitelist_remove():
    ip = request.form.get("ip", "").strip()
    try:
        fw.remove_ssh_whitelist_ip(ip)
        existing_ips = [i for i in current_app.config.get("SSH_WHITELIST_IPS", []) if i != ip]
        persist_ssh_whitelist(existing_ips)
        current_app.config["SSH_WHITELIST_IPS"] = existing_ips
        flash(f"Removed {ip} from the SSH whitelist.", "success")
    except fw.FirewallError as exc:
        flash(str(exc), "error")
    return redirect(url_for("firewall.index"))
