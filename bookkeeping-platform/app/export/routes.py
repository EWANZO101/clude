from datetime import datetime
from flask import Blueprint, Response, send_file, render_template
from flask_login import login_required
from app.businesses.decorators import require_current_business, require_permission
from app.export import csv_export
from app.export.archive import build_full_export

export_bp = Blueprint("export", __name__, template_folder="../templates/export")

CSV_ENDPOINTS = {
    "customers": csv_export.export_customers,
    "suppliers": csv_export.export_suppliers,
    "invoices": csv_export.export_invoices,
    "bills": csv_export.export_bills,
    "expenses": csv_export.export_expenses,
    "chart-of-accounts": csv_export.export_chart_of_accounts,
    "journal-entries": csv_export.export_journal_entries,
}


@export_bp.route("/")
@login_required
@require_current_business
@require_permission("export")
def export_home(business):
    return render_template("export/home.html")


@export_bp.route("/<entity>.csv")
@login_required
@require_current_business
@require_permission("export")
def export_entity_csv(business, entity):
    exporter = CSV_ENDPOINTS.get(entity)
    if exporter is None:
        return Response("Unknown export type.", status=404)
    filename, content = exporter(business)
    return Response(
        content, mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@export_bp.route("/download-everything")
@login_required
@require_current_business
@require_permission("export")
def download_everything(business):
    archive = build_full_export(business)
    timestamp = datetime.utcnow().strftime("%Y%m%d")
    safe_name = "".join(c for c in business.name if c.isalnum() or c in " -_").strip().replace(" ", "-")
    return send_file(
        archive, mimetype="application/zip", as_attachment=True,
        download_name=f"{safe_name or 'business'}-export-{timestamp}.zip",
    )
