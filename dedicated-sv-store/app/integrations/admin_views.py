from flask import render_template, redirect, url_for, request, flash, abort

from app.extensions import db
from app.models.integrations import HardwareApiConnection, SellerApiConnection, ConnectionStatus
from app.models.seller import SellerProfile
from app.integrations.forms import HardwareApiConnectionForm, SellerApiConnectionForm
from app.integrations.adapters import get_adapter
from app.utils.helpers import log_audit
from app.utils.permissions import permission_required


def register_admin_integration_views(admin_bp):
    @admin_bp.route("/hardware-apis", methods=["GET", "POST"])
    @permission_required("api.manage")
    def hardware_apis():
        form = HardwareApiConnectionForm()
        if form.validate_on_submit():
            conn = HardwareApiConnection()
            form.populate_obj(conn)
            db.session.add(conn)
            db.session.flush()
            log_audit("hardware_api_connection.created", "HardwareApiConnection", conn.id, None, {"name": conn.name})
            db.session.commit()
            flash("Hardware API connection added.", "success")
            return redirect(url_for("admin.hardware_apis"))

        connections = HardwareApiConnection.query.order_by(HardwareApiConnection.created_at.desc()).all()
        return render_template("admin/integrations/hardware_apis.html", connections=connections, form=form)

    @admin_bp.route("/hardware-apis/<int:connection_id>/test", methods=["POST"])
    @permission_required("api.manage")
    def hardware_api_test(connection_id):
        from app.models.base import utcnow

        conn = db.session.get(HardwareApiConnection, connection_id) or abort(404)
        adapter = get_adapter(conn.provider_type, conn.base_url, conn.api_key)
        result = adapter.test_connection()

        conn.status = ConnectionStatus.CONNECTED if result.success else ConnectionStatus.FAILED
        conn.last_checked_at = utcnow()
        conn.last_error = None if result.success else result.message
        log_audit("hardware_api_connection.tested", "HardwareApiConnection", conn.id, None, {"success": result.success})
        db.session.commit()
        flash(result.message, "success" if result.success else "error")
        return redirect(url_for("admin.hardware_apis"))

    @admin_bp.route("/hardware-apis/<int:connection_id>/toggle", methods=["POST"])
    @permission_required("api.manage")
    def hardware_api_toggle(connection_id):
        conn = db.session.get(HardwareApiConnection, connection_id) or abort(404)
        conn.is_active = not conn.is_active
        log_audit("hardware_api_connection.toggled", "HardwareApiConnection", conn.id, None, {"is_active": conn.is_active})
        db.session.commit()
        flash("Connection updated.", "success")
        return redirect(url_for("admin.hardware_apis"))

    @admin_bp.route("/hardware-apis/<int:connection_id>/delete", methods=["POST"])
    @permission_required("api.manage")
    def hardware_api_delete(connection_id):
        conn = db.session.get(HardwareApiConnection, connection_id) or abort(404)
        db.session.delete(conn)
        log_audit("hardware_api_connection.deleted", "HardwareApiConnection", connection_id)
        db.session.commit()
        flash("Connection removed.", "success")
        return redirect(url_for("admin.hardware_apis"))

    @admin_bp.route("/providers", methods=["GET", "POST"])
    @permission_required("api.manage")
    def providers():
        form = SellerApiConnectionForm()
        form.seller_id.choices = [(s.id, s.business_name) for s in SellerProfile.query.order_by(SellerProfile.business_name)]

        if form.validate_on_submit():
            conn = SellerApiConnection()
            form.populate_obj(conn)
            db.session.add(conn)
            db.session.flush()
            log_audit("seller_api_connection.created", "SellerApiConnection", conn.id, None, {"name": conn.name})
            db.session.commit()
            flash("Seller API connection added.", "success")
            return redirect(url_for("admin.providers"))

        connections = SellerApiConnection.query.order_by(SellerApiConnection.created_at.desc()).all()
        return render_template("admin/integrations/providers.html", connections=connections, form=form)

    @admin_bp.route("/providers/<int:connection_id>/test", methods=["POST"])
    @permission_required("api.manage")
    def provider_test(connection_id):
        from app.models.base import utcnow

        conn = db.session.get(SellerApiConnection, connection_id) or abort(404)
        adapter = get_adapter(conn.provider_type, conn.base_url, conn.api_key)
        result = adapter.test_connection()

        conn.status = ConnectionStatus.CONNECTED if result.success else ConnectionStatus.FAILED
        conn.last_checked_at = utcnow()
        conn.last_error = None if result.success else result.message
        log_audit("seller_api_connection.tested", "SellerApiConnection", conn.id, None, {"success": result.success})
        db.session.commit()
        flash(result.message, "success" if result.success else "error")
        return redirect(url_for("admin.providers"))

    @admin_bp.route("/providers/<int:connection_id>/toggle", methods=["POST"])
    @permission_required("api.manage")
    def provider_toggle(connection_id):
        conn = db.session.get(SellerApiConnection, connection_id) or abort(404)
        conn.is_active = not conn.is_active
        log_audit("seller_api_connection.toggled", "SellerApiConnection", conn.id, None, {"is_active": conn.is_active})
        db.session.commit()
        flash("Connection updated.", "success")
        return redirect(url_for("admin.providers"))

    @admin_bp.route("/providers/<int:connection_id>/delete", methods=["POST"])
    @permission_required("api.manage")
    def provider_delete(connection_id):
        conn = db.session.get(SellerApiConnection, connection_id) or abort(404)
        db.session.delete(conn)
        log_audit("seller_api_connection.deleted", "SellerApiConnection", connection_id)
        db.session.commit()
        flash("Connection removed.", "success")
        return redirect(url_for("admin.providers"))
