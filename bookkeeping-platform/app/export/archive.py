"""Builds a single zip containing every CSV export plus the business's
uploaded documents plus a manifest — enough for the records to be genuinely
useful outside this platform, per the spec's data-portability principle."""
import io
import json
import os
import zipfile
from datetime import datetime
from flask import current_app
from app.export.csv_export import ALL_EXPORTERS


def build_full_export(business):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for exporter in ALL_EXPORTERS:
            filename, content = exporter(business)
            zf.writestr(f"data/{filename}", content)

        manifest = {
            "business_name": business.name,
            "business_id": business.id,
            "base_currency": business.base_currency,
            "exported_at": datetime.utcnow().isoformat() + "Z",
            "contents": {
                "data/": "CSV exports of every core record type (customers, suppliers, "
                         "invoices, bills, expenses, chart of accounts, journal entries).",
                "documents/": "Every document/receipt uploaded for this business, under "
                              "its original filename.",
            },
        }
        zf.writestr("manifest.json", json.dumps(manifest, indent=2))

        upload_dir = os.path.join(current_app.config["UPLOAD_FOLDER"], business.id)
        if os.path.isdir(upload_dir):
            from app.models.document import Document
            docs = Document.query.filter_by(business_id=business.id).all()
            for doc in docs:
                src = os.path.join(current_app.config["UPLOAD_FOLDER"], doc.stored_path)
                if os.path.exists(src):
                    zf.write(src, f"documents/{doc.original_filename}")

    buf.seek(0)
    return buf
