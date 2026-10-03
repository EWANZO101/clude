from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash, request, send_from_directory, abort, session
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Company, Director, StatutoryDeadline, Document, DEADLINE_KINDS
from app.storage import save_upload, upload_path
from app.crypto import encrypt_token, decrypt_token
from app import companies_house

main_bp = Blueprint("main", __name__, url_prefix="")


def _owned_company_or_404(company_id):
    return Company.query.filter_by(id=company_id, user_id=current_user.id).first_or_404()


def _parse_date(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        return None


# ---- Dashboard ----

@main_bp.route("/")
@login_required
def dashboard():
    companies = Company.query.filter_by(user_id=current_user.id).order_by(Company.company_name).all()

    upcoming = []
    for c in companies:
        for d in c.deadlines:
            if not d.completed_at:
                upcoming.append((c, d))
    upcoming.sort(key=lambda pair: pair[1].due_date)

    return render_template("dashboard.html", companies=companies, upcoming=upcoming[:10])


# ---- Companies ----

@main_bp.route("/companies/new", methods=["GET", "POST"])
@login_required
def new_company():
    if request.method == "POST":
        name = request.form.get("company_name", "").strip()
        if not name:
            flash("Company name is required.", "error")
            return render_template("companies/form.html", company=None)

        company = Company(
            user_id=current_user.id,
            company_name=name,
            company_number=request.form.get("company_number", "").strip(),
            company_type=request.form.get("company_type", "ltd"),
            company_status=request.form.get("company_status", "active"),
            incorporation_date=_parse_date(request.form.get("incorporation_date")),
            registered_office_address=request.form.get("registered_office_address", "").strip(),
            sic_codes=request.form.get("sic_codes", "").strip(),
            notes=request.form.get("notes", "").strip(),
        )
        db.session.add(company)
        db.session.commit()
        flash("Company added.", "success")
        return redirect(url_for("main.company_detail", company_id=company.id))
    return render_template("companies/form.html", company=None)


@main_bp.route("/companies/lookup", methods=["GET", "POST"])
@login_required
def lookup_company():
    """The 'don't type anything' path: enter a company number, Companies
    House supplies everything else -- profile, registered office, SIC
    codes, current officers, and the real confirmation-statement/accounts
    due dates. Shown as an editable preview before saving, same "fetch then
    confirm" shape as a CSV import, rather than saving blind."""
    api_key = decrypt_token(current_user.companies_house_api_key_encrypted)
    if not companies_house.is_configured(api_key):
        flash("Add your Companies House API key under Settings -> Integrations to look up companies "
              "automatically (or add one manually below).", "error")
        return redirect(url_for("main.new_company"))

    if request.method == "POST":
        number = request.form.get("company_number", "").strip().upper()
        if not number:
            flash("Enter a company number.", "error")
            return render_template("companies/lookup.html")
        try:
            profile = companies_house.lookup_company(number, api_key=api_key)
        except companies_house.CompaniesHouseError as e:
            flash(str(e), "error")
            return render_template("companies/lookup.html")
        if not profile:
            flash(f"No company found for number {number}.", "error")
            return render_template("companies/lookup.html")
        try:
            officers = companies_house.list_officers(number, api_key=api_key)
        except companies_house.CompaniesHouseError:
            officers = []

        session["ch_lookup_data"] = {"profile": profile, "officers": officers}
        return render_template("companies/lookup_preview.html", profile=profile, officers=officers)

    return render_template("companies/lookup.html")


@main_bp.route("/companies/lookup/confirm", methods=["POST"])
@login_required
def confirm_lookup():
    data = session.pop("ch_lookup_data", None)
    if not data:
        flash("That lookup expired — search again.", "error")
        return redirect(url_for("main.lookup_company"))

    profile = data["profile"]
    company = Company(
        user_id=current_user.id,
        company_name=request.form.get("company_name", profile.get("company_name", "")).strip(),
        company_number=profile.get("company_number"),
        company_type=profile.get("company_type", "ltd"),
        company_status=profile.get("company_status", "active"),
        incorporation_date=_parse_date(profile.get("incorporation_date")),
        registered_office_address=profile.get("registered_office_address", ""),
        sic_codes=profile.get("sic_codes", ""),
    )
    db.session.add(company)
    db.session.flush()  # get company.id before attaching children

    for o in data.get("officers", []):
        if o.get("resigned_on"):
            continue  # only bring in current officers automatically
        db.session.add(Director(
            company_id=company.id, name=o["name"], role=o.get("role", "director"),
            appointment_date=_parse_date(o.get("appointed_on")),
            resignation_date=_parse_date(o.get("resigned_on")),
            nationality=o.get("nationality", ""),
        ))

    if profile.get("confirmation_statement_due"):
        db.session.add(StatutoryDeadline(
            company_id=company.id, kind="confirmation_statement",
            due_date=_parse_date(profile["confirmation_statement_due"]), frequency="annual",
        ))
    if profile.get("accounts_due"):
        db.session.add(StatutoryDeadline(
            company_id=company.id, kind="annual_accounts",
            due_date=_parse_date(profile["accounts_due"]), frequency="annual",
        ))

    db.session.commit()
    flash(f"{company.company_name} added from Companies House — directors and filing deadlines filled in automatically.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@main_bp.route("/companies/<company_id>")
@login_required
def company_detail(company_id):
    company = _owned_company_or_404(company_id)
    return render_template("companies/detail.html", company=company, deadline_kinds=DEADLINE_KINDS)


@main_bp.route("/companies/<company_id>/edit", methods=["GET", "POST"])
@login_required
def edit_company(company_id):
    company = _owned_company_or_404(company_id)
    if request.method == "POST":
        company.company_name = request.form.get("company_name", company.company_name).strip() or company.company_name
        company.company_number = request.form.get("company_number", "").strip()
        company.company_type = request.form.get("company_type", company.company_type)
        company.company_status = request.form.get("company_status", company.company_status)
        company.incorporation_date = _parse_date(request.form.get("incorporation_date"))
        company.registered_office_address = request.form.get("registered_office_address", "").strip()
        company.sic_codes = request.form.get("sic_codes", "").strip()
        company.notes = request.form.get("notes", "").strip()
        db.session.commit()
        flash("Company updated.", "success")
        return redirect(url_for("main.company_detail", company_id=company.id))
    return render_template("companies/form.html", company=company)


@main_bp.route("/companies/<company_id>/delete", methods=["POST"])
@login_required
def delete_company(company_id):
    company = _owned_company_or_404(company_id)
    db.session.delete(company)
    db.session.commit()
    flash("Company removed.", "success")
    return redirect(url_for("main.dashboard"))


# ---- Directors ----

@main_bp.route("/companies/<company_id>/directors/new", methods=["POST"])
@login_required
def new_director(company_id):
    company = _owned_company_or_404(company_id)
    name = request.form.get("name", "").strip()
    if not name:
        flash("Director name is required.", "error")
        return redirect(url_for("main.company_detail", company_id=company.id))
    db.session.add(Director(
        company_id=company.id, name=name,
        role=request.form.get("role", "director"),
        appointment_date=_parse_date(request.form.get("appointment_date")),
        nationality=request.form.get("nationality", "").strip(),
        notes=request.form.get("notes", "").strip(),
    ))
    db.session.commit()
    flash("Director added.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@main_bp.route("/directors/<director_id>/resign", methods=["POST"])
@login_required
def resign_director(director_id):
    director = Director.query.filter_by(id=director_id).first_or_404()
    company = _owned_company_or_404(director.company_id)
    director.resignation_date = _parse_date(request.form.get("resignation_date")) or datetime.utcnow().date()
    db.session.commit()
    flash("Director marked as resigned.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@main_bp.route("/directors/<director_id>/delete", methods=["POST"])
@login_required
def delete_director(director_id):
    director = Director.query.filter_by(id=director_id).first_or_404()
    company = _owned_company_or_404(director.company_id)
    db.session.delete(director)
    db.session.commit()
    flash("Director removed.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


# ---- Statutory deadlines ----

@main_bp.route("/companies/<company_id>/deadlines/new", methods=["POST"])
@login_required
def new_deadline(company_id):
    company = _owned_company_or_404(company_id)
    due_date = _parse_date(request.form.get("due_date"))
    if not due_date:
        flash("A valid due date is required.", "error")
        return redirect(url_for("main.company_detail", company_id=company.id))
    db.session.add(StatutoryDeadline(
        company_id=company.id,
        kind=request.form.get("kind", "custom"),
        label=request.form.get("label", "").strip(),
        due_date=due_date,
        frequency=request.form.get("frequency", "annual"),
    ))
    db.session.commit()
    flash("Deadline added.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@main_bp.route("/deadlines/<deadline_id>/complete", methods=["POST"])
@login_required
def complete_deadline(deadline_id):
    deadline = StatutoryDeadline.query.filter_by(id=deadline_id).first_or_404()
    company = _owned_company_or_404(deadline.company_id)
    deadline.mark_complete()
    db.session.commit()
    flash("Marked as filed.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@main_bp.route("/deadlines/<deadline_id>/delete", methods=["POST"])
@login_required
def delete_deadline(deadline_id):
    deadline = StatutoryDeadline.query.filter_by(id=deadline_id).first_or_404()
    company = _owned_company_or_404(deadline.company_id)
    db.session.delete(deadline)
    db.session.commit()
    flash("Deadline removed.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


# ---- Documents ----

@main_bp.route("/companies/<company_id>/documents/upload", methods=["POST"])
@login_required
def upload_document(company_id):
    company = _owned_company_or_404(company_id)
    file = request.files.get("file")
    stored_name = save_upload(file)
    if not stored_name:
        flash("Choose a PDF, image, or document file to upload.", "error")
        return redirect(url_for("main.company_detail", company_id=company.id))
    db.session.add(Document(
        company_id=company.id, original_filename=file.filename,
        stored_filename=stored_name, description=request.form.get("description", "").strip(),
    ))
    db.session.commit()
    flash("Document uploaded.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@main_bp.route("/documents/<document_id>/download")
@login_required
def download_document(document_id):
    doc = Document.query.filter_by(id=document_id).first_or_404()
    _owned_company_or_404(doc.company_id)  # ownership check, raises 404 if not theirs
    from flask import current_app
    return send_from_directory(current_app.config["UPLOAD_FOLDER"], doc.stored_filename,
                                as_attachment=True, download_name=doc.original_filename)


@main_bp.route("/documents/<document_id>/delete", methods=["POST"])
@login_required
def delete_document(document_id):
    doc = Document.query.filter_by(id=document_id).first_or_404()
    company = _owned_company_or_404(doc.company_id)
    import os
    try:
        os.remove(upload_path(doc.stored_filename))
    except OSError:
        pass
    db.session.delete(doc)
    db.session.commit()
    flash("Document deleted.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


# ---- Integrations settings (self-service, no server access needed) ----

@main_bp.route("/settings/integrations", methods=["GET", "POST"])
@login_required
def integrations_settings():
    if request.method == "POST":
        action = request.form.get("action")
        if action == "clear_companies_house":
            current_user.companies_house_api_key_encrypted = None
            db.session.commit()
            flash("Companies House key removed.", "success")
        else:
            key = request.form.get("companies_house_api_key", "").strip()
            if key:
                current_user.companies_house_api_key_encrypted = encrypt_token(key)
                db.session.commit()
                flash("Companies House key saved.", "success")
            else:
                flash("Enter a key to save.", "error")
        return redirect(url_for("main.integrations_settings"))

    has_ch_key = bool(current_user.companies_house_api_key_encrypted)
    return render_template("settings/integrations.html", has_ch_key=has_ch_key)
