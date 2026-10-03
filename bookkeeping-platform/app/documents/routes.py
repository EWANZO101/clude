import os
import uuid
from flask import Blueprint, render_template, request, redirect, url_for, flash, current_app, send_from_directory
from flask_login import login_required, current_user
from werkzeug.utils import secure_filename
from app.extensions import db
from app.models.document import Document
from app.businesses.decorators import require_current_business, require_permission

documents_bp = Blueprint("documents", __name__, template_folder="../templates/documents")

ALLOWED_EXTENSIONS = {"pdf", "png", "jpg", "jpeg", "gif", "csv", "xlsx", "docx", "txt"}


def _allowed(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


@documents_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def list_documents(business):
    documents = Document.query.filter_by(business_id=business.id).order_by(Document.uploaded_at.desc()).all()
    return render_template("documents/list.html", documents=documents)


@documents_bp.route("/upload", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def upload_document(business):
    if request.method == "POST":
        file = request.files.get("file")
        if not file or file.filename == "":
            flash("Choose a file to upload.", "error")
            return render_template("documents/upload.html")
        if not _allowed(file.filename):
            flash("That file type is not supported.", "error")
            return render_template("documents/upload.html")

        safe_name = secure_filename(file.filename)
        stored_name = f"{uuid.uuid4()}_{safe_name}"
        business_dir = os.path.join(current_app.config["UPLOAD_FOLDER"], business.id)
        os.makedirs(business_dir, exist_ok=True)
        full_path = os.path.join(business_dir, stored_name)
        file.save(full_path)

        doc = Document(
            business_id=business.id,
            original_filename=safe_name,
            stored_path=os.path.join(business.id, stored_name),
            content_type=file.content_type,
            size_bytes=os.path.getsize(full_path),
            related_type=request.form.get("related_type") or None,
            related_id=request.form.get("related_id") or None,
            uploaded_by_id=current_user.id,
        )
        db.session.add(doc)
        db.session.commit()
        flash("Document uploaded. The original file is retained as-is.", "success")
        return redirect(url_for("documents.list_documents"))

    return render_template("documents/upload.html")


@documents_bp.route("/<document_id>/download")
@login_required
@require_current_business
@require_permission("view")
def download_document(business, document_id):
    doc = Document.query.filter_by(id=document_id, business_id=business.id).first_or_404()
    directory = current_app.config["UPLOAD_FOLDER"]
    return send_from_directory(directory, doc.stored_path, as_attachment=True, download_name=doc.original_filename)
