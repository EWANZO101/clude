import io
import zipfile

from flask import render_template, send_file, current_app

from app.cloudloader import cloudloader_bp
from app.cloudloader.lua_templates import render_cloudloader_files


@cloudloader_bp.route("/cloudloader")
def info():
    """Public page - no login required. This is the resource ANY customer
    installs, regardless of which developer's products they bought."""
    return render_template("cloudloader/info.html")


@cloudloader_bp.route("/cloudloader/download")
def download():
    files = render_cloudloader_files(
        site_name=current_app.config["SITE_NAME"],
        api_base=current_app.config["SITE_URL"],
    )

    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, content in files.items():
            zf.writestr(f"cloudloader/{name}", content)
    buffer.seek(0)

    return send_file(
        buffer,
        as_attachment=True,
        download_name="cloudloader.zip",
        mimetype="application/zip",
    )
