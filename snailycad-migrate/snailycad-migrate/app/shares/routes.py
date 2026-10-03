import os
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash, send_file, abort
from flask_login import login_required, current_user

from app.extensions import db, limiter
from app.models import ExportShareLink
from app.shares.forms import PinEntryForm
from app.auth.routes import log_action

shares_bp = Blueprint("shares", __name__)


@shares_bp.route("/share/<token>", methods=["GET", "POST"])
@limiter.limit("15 per minute")
def access(token):
    link = ExportShareLink.query.filter_by(token=token).first_or_404()
    form = PinEntryForm()

    if link.revoked:
        return render_template("shares/access.html", link=None, form=form,
                                error="This link has been turned off by whoever shared it.")
    if not link.approved:
        return render_template("shares/access.html", link=None, form=form,
                                error="This link is waiting on approval and isn't active yet.")
    if link.is_expired:
        return render_template("shares/access.html", link=None, form=form,
                                error="This link has expired.")
    if link.is_locked:
        return render_template("shares/access.html", link=None, form=form,
                                error="Too many wrong PIN attempts — this link has been locked for safety.")

    if form.validate_on_submit():
        if link.check_pin(form.pin.data.strip()):
            link.failed_pin_attempts = 0
            link.download_count += 1
            link.last_accessed_at = datetime.utcnow()
            db.session.commit()
            log_action(link.created_by, "share_link_downloaded", detail=link.id)

            export = link.export
            if not export.file_path or not os.path.exists(export.file_path):
                return render_template("shares/access.html", link=None, form=form,
                                        error="The file behind this link is missing. Contact whoever shared it.")

            return send_file(
                export.file_path, as_attachment=True,
                download_name=f"snailycad-export-{export.id[:8]}.zip",
            )
        else:
            link.failed_pin_attempts += 1
            db.session.commit()
            flash("That PIN isn't right. Try again.", "danger")

    return render_template("shares/access.html", link=link, form=form, error=None)


@shares_bp.route("/share/link/<link_id>/revoke", methods=["POST"])
@login_required
def revoke(link_id):
    link = ExportShareLink.query.get_or_404(link_id)
    if link.created_by != current_user.id and not current_user.is_admin():
        abort(404)

    link.revoked = True
    db.session.commit()
    log_action(current_user.id, "share_link_revoked", detail=link_id)
    flash("Share link turned off.", "info")
    return redirect(url_for("exports.detail", export_id=link.export_id))
