from flask import render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user

from app.portal import portal_bp
from app.extensions import db
from app.models.developer import License
from app.models.portal import FivemServer, ServerLicense
from app.utils import generate_server_token


@portal_bp.route("/portal")
@login_required
def my_licenses():
    licenses = (
        License.query.filter_by(customer_user_id=current_user.id)
        .order_by(License.created_at.desc())
        .all()
    )
    servers = FivemServer.query.filter_by(owner_id=current_user.id).all()

    # Which licenses are already attached to which servers, for quick lookup.
    attached_license_ids = {
        sl.license_id
        for server in servers
        for sl in server.attachments
    }

    return render_template(
        "portal/my_licenses.html",
        licenses=licenses,
        servers=servers,
        attached_license_ids=attached_license_ids,
    )


@portal_bp.route("/portal/servers")
@login_required
def servers():
    from app.utils import is_server_online, humanize_relative_time

    items = FivemServer.query.filter_by(owner_id=current_user.id).order_by(FivemServer.created_at.desc()).all()
    server_status = {
        s.id: {"online": is_server_online(s.last_seen_at), "last_seen_text": humanize_relative_time(s.last_seen_at)}
        for s in items
    }
    return render_template("portal/servers.html", servers=items, server_status=server_status)


@portal_bp.route("/portal/servers/new", methods=["POST"])
@login_required
def new_server():
    name = request.form.get("name", "").strip() or "My Server"
    raw_token, prefix, lookup_hash = generate_server_token()

    server = FivemServer(owner_id=current_user.id, name=name, token_hash=lookup_hash, token_prefix=prefix)
    db.session.add(server)
    db.session.commit()

    return render_template("portal/token_shown.html", server=server, token=raw_token, regenerated=False)


@portal_bp.route("/portal/servers/<int:server_id>")
@login_required
def server_detail(server_id):
    from app.utils import is_server_online, humanize_relative_time

    server = FivemServer.query.filter_by(id=server_id, owner_id=current_user.id).first_or_404()
    attached_ids = {sl.license_id for sl in server.attachments}

    query = License.query.filter_by(customer_user_id=current_user.id)
    if attached_ids:
        query = query.filter(~License.id.in_(attached_ids))
    available_licenses = query.all()
    return render_template(
        "portal/server_detail.html",
        server=server,
        attached=server.attachments,
        available_licenses=available_licenses,
        online=is_server_online(server.last_seen_at),
        last_seen_text=humanize_relative_time(server.last_seen_at),
    )


@portal_bp.route("/portal/servers/<int:server_id>/regenerate-token", methods=["POST"])
@login_required
def regenerate_token(server_id):
    server = FivemServer.query.filter_by(id=server_id, owner_id=current_user.id).first_or_404()
    raw_token, prefix, lookup_hash = generate_server_token()
    server.token_hash = lookup_hash
    server.token_prefix = prefix
    db.session.commit()
    return render_template("portal/token_shown.html", server=server, token=raw_token, regenerated=True)


@portal_bp.route("/portal/servers/<int:server_id>/delete", methods=["POST"])
@login_required
def delete_server(server_id):
    server = FivemServer.query.filter_by(id=server_id, owner_id=current_user.id).first_or_404()
    db.session.delete(server)
    db.session.commit()
    flash(f"{server.name} removed.", "info")
    return redirect(url_for("portal.servers"))


@portal_bp.route("/portal/servers/<int:server_id>/attach", methods=["POST"])
@login_required
def attach_license(server_id):
    server = FivemServer.query.filter_by(id=server_id, owner_id=current_user.id).first_or_404()
    license_id = request.form.get("license_id", type=int)

    license_obj = License.query.filter_by(id=license_id, customer_user_id=current_user.id).first()
    if not license_obj:
        flash("License not found.", "error")
        return redirect(url_for("portal.server_detail", server_id=server.id))

    existing = ServerLicense.query.filter_by(server_id=server.id, license_id=license_obj.id).first()
    if not existing:
        db.session.add(ServerLicense(server_id=server.id, license_id=license_obj.id))
        db.session.commit()
        flash("Added to server.", "success")

    return redirect(url_for("portal.server_detail", server_id=server.id))


@portal_bp.route("/portal/servers/<int:server_id>/detach/<int:license_id>", methods=["POST"])
@login_required
def detach_license(server_id, license_id):
    server = FivemServer.query.filter_by(id=server_id, owner_id=current_user.id).first_or_404()
    ServerLicense.query.filter_by(server_id=server.id, license_id=license_id).delete()
    db.session.commit()
    flash("Removed from server.", "info")
    return redirect(url_for("portal.server_detail", server_id=server.id))


@portal_bp.route("/portal/servers/<int:server_id>/channel/<int:license_id>", methods=["POST"])
@login_required
def set_channel(server_id, license_id):
    server = FivemServer.query.filter_by(id=server_id, owner_id=current_user.id).first_or_404()
    attachment = ServerLicense.query.filter_by(server_id=server.id, license_id=license_id).first_or_404()

    channel = request.form.get("channel", "stable")
    if channel not in ("stable", "beta"):
        channel = "stable"

    attachment.channel = channel
    db.session.commit()
    flash(f"Switched to {channel}. Takes effect on the next check-in (or restart CloudLoader now).", "success")
    return redirect(url_for("portal.server_detail", server_id=server.id))
