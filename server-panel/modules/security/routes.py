from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_socketio import emit

from extensions import socketio
from services import security_service as sec
from services import ddos_service as ddos
from services import firewall_service as fw
from services import system_service
from modules.security.forms import BlockIpForm
from utils.permissions import require_permission

security_bp = Blueprint("security", __name__, template_folder="templates")


def _page_context():
    snapshot = system_service.get_full_snapshot()
    ddos_status = ddos.get_status()
    return {
        "ssh_sessions": sec.get_ssh_sessions(),
        "session_activity": sec.get_session_activity(),
        "blocked_ips": sec.get_blocked_ips(),
        "top_connections": sec.get_top_connections(),
        "connection_count": sec.get_connection_count(),
        "ddos_status": ddos_status,
        "ddos_events": ddos.recent_events(30),
        "health": sec.compute_health(snapshot, ddos_status),
        "firewall_installed": fw.is_installed(),
        "block_form": BlockIpForm(),
    }


@security_bp.route("/security")
@require_permission("security.view")
def index():
    return render_template("security_index.html", **_page_context())


@security_bp.route("/security/block-ip", methods=["POST"])
@require_permission("security.manage")
def block_ip():
    form = BlockIpForm()
    if form.validate_on_submit():
        ip = form.ip.data.strip()
        try:
            fw.block_ip(ip)
            ddos.unblock_suspect(ip)  # clears local suspect bookkeeping; rule itself now reflects "blocked"
            flash(f"Blocked {ip}.", "success")
        except fw.FirewallError as exc:
            flash(str(exc), "error")
    else:
        flash("Invalid IP.", "error")
    return redirect(url_for("security.index"))


@security_bp.route("/security/unblock-ip", methods=["POST"])
@require_permission("security.manage")
def unblock_ip():
    ip = request.form.get("ip", "").strip()
    try:
        fw.remove_ip_rule(ip, action="deny")
        ddos.unblock_suspect(ip)
        flash(f"Unblocked {ip}.", "success")
    except fw.FirewallError as exc:
        flash(str(exc), "error")
    return redirect(url_for("security.index"))


@security_bp.route("/security/ddos/auto-mitigation", methods=["POST"])
@require_permission("security.manage")
def toggle_auto_mitigation():
    enabled = request.form.get("enabled") == "1"
    ddos.set_auto_mitigation(enabled)
    flash(f"DDoS auto-mitigation {'enabled' if enabled else 'disabled'}.", "success")
    return redirect(url_for("security.index"))


@security_bp.route("/security/ddos/reset-baseline", methods=["POST"])
@require_permission("security.manage")
def reset_baseline():
    ddos.reset_baseline()
    flash("Traffic baseline reset — the detector is relearning normal traffic.", "success")
    return redirect(url_for("security.index"))


# ---------------------------------------------------------------------------
# Live updates for the Security page. Kept on a separate namespace/loop from
# the main dashboard emitter since this data (ss/who process spawns) is
# heavier per-sample than the psutil-only dashboard stats.
# ---------------------------------------------------------------------------

@socketio.on("connect", namespace="/security")
def handle_connect():
    emit("ddos_update", ddos.get_status())
    emit("sessions_update", {
        "ssh_sessions": sec.get_ssh_sessions(),
        "session_activity": sec.get_session_activity(),
        "blocked_ips": sec.get_blocked_ips(),
        "top_connections": sec.get_top_connections(),
        "connection_count": sec.get_connection_count(),
    })


_sessions_loop_started = False


def start_sessions_emitter(app):
    """Separate, slower-interval loop for the SSH-session / blocked-IP /
    top-connections panels, which shell out to `who`/`ss` and are more
    expensive than the psutil-only dashboard loop."""
    global _sessions_loop_started
    if _sessions_loop_started:
        return
    _sessions_loop_started = True

    def _loop():
        with app.app_context():
            while True:
                try:
                    socketio.emit("sessions_update", {
                        "ssh_sessions": sec.get_ssh_sessions(),
                        "session_activity": sec.get_session_activity(),
                        "blocked_ips": sec.get_blocked_ips(),
                        "top_connections": sec.get_top_connections(),
                        "connection_count": sec.get_connection_count(),
                    }, namespace="/security")
                except Exception as exc:  # noqa: BLE001
                    app.logger.warning("Security sessions emitter error: %s", exc)
                socketio.sleep(4)

    socketio.start_background_task(_loop)
