from flask import Blueprint, render_template, redirect, url_for, flash, request

from services import nginx_service as nx
from modules.nginx.forms import CreateSiteForm, IssueCertForm
from utils.permissions import require_permission

nginx_bp = Blueprint("nginx", __name__, template_folder="templates")


@nginx_bp.route("/nginx")
@require_permission("nginx.manage")
def index():
    installed = nx.is_installed()
    sites = nx.list_sites() if installed else []
    return render_template("nginx_index.html", installed=installed, sites=sites,
                            certbot_installed=nx.certbot_installed() if installed else False)


@nginx_bp.route("/nginx/install", methods=["POST"])
@require_permission("nginx.manage")
def install():
    try:
        nx.install_nginx()
        flash("nginx installed successfully.", "success")
    except nx.NginxError as exc:
        flash(str(exc), "error")
    return redirect(url_for("nginx.index"))


@nginx_bp.route("/nginx/create", methods=["GET", "POST"])
@require_permission("nginx.manage")
def create():
    form = CreateSiteForm()
    if form.validate_on_submit():
        try:
            domain, config_text = nx.build_site_config(
                form.domain.data, form.port.data, form.extra_directives.data
            )
            nx.write_site(domain, config_text)
            ok, output = nx.test_config()
            if not ok:
                flash(f"Config written but nginx -t failed: {output}", "error")
                return render_template("nginx_create.html", form=form)
            nx.reload_nginx()
            flash(f"Site {domain} created and nginx reloaded.", "success")
            return redirect(url_for("nginx.index"))
        except nx.NginxError as exc:
            flash(str(exc), "error")

    return render_template("nginx_create.html", form=form)


@nginx_bp.route("/nginx/<path:filename>/delete", methods=["POST"])
@require_permission("nginx.manage")
def delete_site(filename):
    try:
        nx.remove_site(filename)
        nx.reload_nginx()
        flash(f"Removed {filename}.", "success")
    except nx.NginxError as exc:
        flash(str(exc), "error")
    return redirect(url_for("nginx.index"))


@nginx_bp.route("/nginx/ssl", methods=["GET", "POST"])
@require_permission("nginx.manage")
def ssl():
    form = IssueCertForm()
    if form.validate_on_submit():
        try:
            if not nx.certbot_installed():
                nx.install_certbot()
            output = nx.issue_certificate(form.domain.data, form.email.data, form.force_https.data)
            flash(f"Certificate issued for {form.domain.data}.", "success")
        except nx.NginxError as exc:
            flash(str(exc), "error")
        return redirect(url_for("nginx.index"))

    return render_template("nginx_ssl.html", form=form)


@nginx_bp.route("/nginx/ssl/renew", methods=["POST"])
@require_permission("nginx.manage")
def renew_ssl():
    try:
        nx.renew_certificates()
        flash("Certificate renewal check completed.", "success")
    except nx.NginxError as exc:
        flash(str(exc), "error")
    return redirect(url_for("nginx.index"))


@nginx_bp.route("/nginx/repair", methods=["POST"])
@require_permission("nginx.manage")
def repair():
    ok, message = nx.repair()
    flash(message, "success" if ok else "error")
    return redirect(url_for("nginx.index"))


@nginx_bp.route("/nginx/<path:filename>/backups")
@require_permission("nginx.manage")
def site_backups(filename):
    backups = nx.list_site_backups(filename)
    return render_template("nginx_backups.html", filename=filename, backups=backups)


@nginx_bp.route("/nginx/<path:filename>/restore", methods=["POST"])
@require_permission("nginx.manage")
def restore_site(filename):
    backup_path = request.form.get("backup_path", "")
    try:
        nx.restore_site_backup(filename, backup_path)
        flash(f"Restored {filename} from backup and reloaded nginx.", "success")
        return redirect(url_for("nginx.index"))
    except nx.NginxError as exc:
        flash(str(exc), "error")
        return redirect(url_for("nginx.site_backups", filename=filename))
