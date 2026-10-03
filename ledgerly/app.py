import json
import os
import random
import re
from datetime import date, datetime

from flask import (
    Flask, render_template, request, redirect, url_for, flash, jsonify,
    send_file, abort, session, send_from_directory
)
from flask_login import (
    login_user, logout_user, login_required, current_user, LoginManager
)
from werkzeug.utils import secure_filename

from extensions import db, login_manager
from models import (
    Company, User, Client, Contract, PaymentSchedule, Payment,
    ReminderSetting, AuditLog, gen_token
)
from currencies import CURRENCIES, get_currency
from scheduling import build_dates, build_amounts, label_for, max_months_cutoff
from pdf_export import build_contract_pdf
from richtext import clean_agreement_html

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

app = Flask(__name__)
app.config["SECRET_KEY"] = "dev-secret-change-me"
app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{os.path.join(BASE_DIR, 'ledgerly.db')}"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
app.config["UPLOAD_FOLDER"] = os.path.join(BASE_DIR, "uploads")
app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024  # 5MB cap on uploads (logo files)
os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

ALLOWED_LOGO_EXTENSIONS = {"png", "jpg", "jpeg"}

db.init_app(app)
login_manager.init_app(app)
login_manager.login_view = "login"


@login_manager.user_loader
def load_user(user_id):
    return db.session.get(User, int(user_id))


def money_fmt(amount, code):
    cur = get_currency(code)
    symbol = cur["symbol"] if cur else (code or "")
    try:
        return f"{symbol}{float(amount):,.2f}"
    except (TypeError, ValueError):
        return f"{symbol}0.00"


app.jinja_env.filters["money"] = money_fmt


def agreement_html_filter(text):
    """Legacy content saved before the rich-text editor was added is plain
    text with blank-line paragraphs; anything saved since is already HTML.
    Render both correctly without a migration step."""
    if not text:
        return ""
    if "<" in text and ">" in text:
        return text  # already HTML (sanitized on save)
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    escaped = [
        p.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br>")
        for p in paragraphs
    ]
    return "".join(f"<p>{p}</p>" for p in escaped)


app.jinja_env.filters["agreement_html"] = agreement_html_filter


def gen_pin():
    return f"{random.randint(0, 9999):04d}"


def _share_verified(token):
    return session.get(f"share_ok_{token}") is True


# ---------------------------------------------------------------- auth ----

@app.route("/register", methods=["GET", "POST"])
def register():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard"))
    if request.method == "POST":
        company_name = request.form["company_name"].strip()
        name = request.form["name"].strip()
        email = request.form["email"].strip().lower()
        password = request.form["password"]

        if User.query.filter_by(email=email).first():
            flash("An account with that email already exists.", "error")
            return render_template("register.html")

        company = Company(name=company_name, default_currency="GBP")
        db.session.add(company)
        db.session.flush()

        user = User(company_id=company.id, name=name, email=email)
        user.set_password(password)
        db.session.add(user)

        db.session.add(ReminderSetting(company_id=company.id))
        db.session.commit()

        login_user(user)
        flash(f"Welcome to Ledgerly, {company_name} is set up.", "success")
        return redirect(url_for("dashboard"))
    return render_template("register.html")


@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard"))
    if request.method == "POST":
        email = request.form["email"].strip().lower()
        password = request.form["password"]
        user = User.query.filter_by(email=email).first()
        if user and user.check_password(password):
            login_user(user)
            return redirect(url_for("dashboard"))
        flash("Incorrect email or password.", "error")
    return render_template("login.html")


@app.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("login"))


# ----------------------------------------------------------- dashboard ----

@app.route("/")
@login_required
def dashboard():
    contracts = Contract.query.filter_by(company_id=current_user.company_id) \
        .order_by(Contract.created_at.desc()).all()

    for c in contracts:
        if c.schedule:
            for p in c.schedule.payments:
                p.refresh_status()
    db.session.commit()

    total_value = sum(float(c.total_amount) for c in contracts)
    total_paid = sum(c.amount_paid for c in contracts)
    total_overdue = sum(c.overdue_amount for c in contracts)

    return render_template(
        "dashboard.html", contracts=contracts,
        total_value=total_value, total_paid=total_paid, total_overdue=total_overdue,
    )


# ------------------------------------------------------------- clients ----

@app.route("/clients", methods=["GET", "POST"])
@login_required
def clients():
    if request.method == "POST":
        c = Client(
            company_id=current_user.company_id,
            name=request.form["name"].strip(),
            email=request.form.get("email", "").strip(),
        )
        db.session.add(c)
        db.session.commit()
        flash(f"Added client {c.name}.", "success")
        return redirect(url_for("clients"))

    all_clients = Client.query.filter_by(company_id=current_user.company_id) \
        .order_by(Client.name).all()
    return render_template("clients.html", clients=all_clients)


# ----------------------------------------------------------- currency API-

@app.route("/api/currencies")
def api_currencies():
    q = (request.args.get("q") or "").strip().lower()
    if not q:
        results = CURRENCIES
    else:
        results = [
            c for c in CURRENCIES
            if q in c["code"].lower()
            or q in c["name"].lower()
            or q in c["symbol"].lower()
        ]
    return jsonify(results[:30])


# ----------------------------------------------------------- contracts ----

@app.route("/contracts")
@login_required
def contracts_list():
    all_contracts = Contract.query.filter_by(company_id=current_user.company_id) \
        .order_by(Contract.created_at.desc()).all()
    return render_template("contracts/list.html", contracts=all_contracts)


@app.route("/contracts/new", methods=["GET", "POST"])
@login_required
def contract_new():
    clients_qs = Client.query.filter_by(company_id=current_user.company_id).order_by(Client.name).all()
    if request.method == "POST":
        client_id = request.form.get("client_id")
        if not client_id:
            flash("Choose or add a client first.", "error")
            return render_template("contracts/new.html", clients=clients_qs, currencies=CURRENCIES)
        try:
            total_amount = float(request.form["total_amount"])
        except (KeyError, ValueError):
            flash("Enter a valid contract total.", "error")
            return render_template("contracts/new.html", clients=clients_qs, currencies=CURRENCIES)

        currency_code = request.form.get("currency_code", "GBP").upper()
        if not get_currency(currency_code):
            flash("Choose a currency from the list.", "error")
            return render_template("contracts/new.html", clients=clients_qs, currencies=CURRENCIES)

        require_pin = bool(request.form.get("require_pin"))
        contract = Contract(
            company_id=current_user.company_id,
            client_id=int(client_id),
            title=request.form["title"].strip(),
            total_amount=total_amount,
            currency_code=currency_code,
            allow_outstanding_balance=bool(request.form.get("allow_outstanding_balance")),
            allows_schedule_changes=bool(request.form.get("allows_schedule_changes", True)),
            agreement_text=clean_agreement_html(request.form.get("agreement_text", "")),
            client_can_build_schedule=bool(request.form.get("client_can_build_schedule", True)),
            pin_code=gen_pin() if require_pin else None,
            max_payment_months=int(request.form["max_payment_months"]) if request.form.get("max_payment_months") else None,
        )
        db.session.add(contract)
        db.session.commit()
        return redirect(url_for("schedule_builder", contract_id=contract.id))

    return render_template("contracts/new.html", clients=clients_qs, currencies=CURRENCIES)


@app.route("/contracts/<int:contract_id>/agreement", methods=["GET", "POST"])
@login_required
def contract_agreement(contract_id):
    contract = _owned_contract(contract_id)
    if request.method == "POST":
        contract.agreement_text = clean_agreement_html(request.form.get("agreement_text", ""))
        contract.client_can_build_schedule = bool(request.form.get("client_can_build_schedule"))
        contract.max_payment_months = int(request.form["max_payment_months"]) if request.form.get("max_payment_months") else None
        require_pin = bool(request.form.get("require_pin"))
        if require_pin and not contract.pin_code:
            contract.pin_code = gen_pin()
        elif require_pin and request.form.get("regenerate_pin"):
            contract.pin_code = gen_pin()
        elif not require_pin:
            contract.pin_code = None
        db.session.commit()
        flash("Agreement and share settings saved.", "success")
        return redirect(url_for("contract_view", contract_id=contract.id))
    return render_template("contracts/agreement.html", contract=contract)


def _owned_contract(contract_id):
    contract = db.session.get(Contract, contract_id)
    if not contract or contract.company_id != current_user.company_id:
        abort(404)
    return contract


def _compute_schedule(contract, form):
    frequency = form.get("frequency", "monthly")
    start_date = datetime.strptime(form["start_date"], "%Y-%m-%d").date()
    day_of_month = form.get("day_of_month")
    day_of_month = int(day_of_month) if day_of_month else None
    num_instalments = int(form.get("num_instalments") or 1)
    amount_mode = form.get("amount_mode", "fixed")

    custom_dates = None
    if frequency == "custom":
        raw = [d.strip() for d in form.get("custom_dates", "").split(",") if d.strip()]
        custom_dates = [datetime.strptime(d, "%Y-%m-%d").date() for d in raw]
        num_instalments = len(custom_dates)

    dates = build_dates(frequency, start_date, num_instalments, day_of_month, custom_dates)

    fixed_amount = None
    percentage = None
    custom_amounts = None
    if amount_mode == "fixed" and form.get("fixed_amount"):
        fixed_amount = float(form["fixed_amount"])
    elif amount_mode == "percentage" and form.get("percentage"):
        percentage = float(form["percentage"])
    elif amount_mode == "custom":
        raw = [a.strip() for a in form.get("custom_amounts", "").split(",") if a.strip()]
        custom_amounts = [float(a) for a in raw]
        if len(custom_amounts) < len(dates):
            custom_amounts += [0.0] * (len(dates) - len(custom_amounts))
        dates = dates[: len(custom_amounts)] if len(custom_amounts) < len(dates) else dates

    amounts, remaining_balance = build_amounts(
        amount_mode, float(contract.total_amount), len(dates),
        fixed_amount=fixed_amount, percentage=percentage, custom_amounts=custom_amounts,
    )

    rows = []
    for i, (d, amt) in enumerate(zip(dates, amounts)):
        rows.append({
            "sequence": i + 1,
            "date": d.isoformat(),
            "amount": round(amt, 2),
            "label": label_for(i, len(dates)),
        })

    meta = {
        "frequency": frequency, "start_date": start_date.isoformat(),
        "day_of_month": day_of_month, "amount_mode": amount_mode,
        "auto_end": bool(form.get("auto_end", True)),
    }
    return rows, remaining_balance, meta


@app.route("/contracts/<int:contract_id>/schedule", methods=["GET", "POST"])
@login_required
def schedule_builder(contract_id):
    contract = _owned_contract(contract_id)

    if request.method == "POST":
        rows_json = request.form.get("rows_json")
        meta_json = request.form.get("meta_json")
        if not rows_json or not meta_json:
            flash("Generate a preview before confirming the schedule.", "error")
            return redirect(url_for("schedule_builder", contract_id=contract.id))

        rows = json.loads(rows_json)
        meta = json.loads(meta_json)

        is_edit = contract.schedule is not None
        original_snapshot = None
        if is_edit:
            original_snapshot = [
                {"sequence": p.sequence, "date": p.due_date.isoformat(),
                 "amount": float(p.amount), "label": p.label}
                for p in contract.schedule.payments
            ]
            for p in list(contract.schedule.payments):
                db.session.delete(p)
            db.session.delete(contract.schedule)
            db.session.flush()

        schedule = PaymentSchedule(
            contract_id=contract.id,
            frequency=meta["frequency"],
            start_date=datetime.strptime(meta["start_date"], "%Y-%m-%d").date(),
            day_of_month=meta.get("day_of_month"),
            num_instalments=len(rows),
            auto_end=meta.get("auto_end", True),
            amount_mode=meta.get("amount_mode", "fixed"),
        )
        db.session.add(schedule)
        db.session.flush()

        for row in rows:
            db.session.add(Payment(
                schedule_id=schedule.id,
                sequence=row["sequence"],
                due_date=datetime.strptime(row["date"], "%Y-%m-%d").date(),
                amount=row["amount"],
                label=row.get("label"),
            ))

        action = "schedule_edited" if is_edit else "schedule_created"
        db.session.add(AuditLog(
            contract_id=contract.id,
            action=action,
            original_schedule=json.dumps(original_snapshot) if original_snapshot else None,
            requested_change=json.dumps({"summary": f"{meta['frequency']} schedule, {len(rows)} instalments"}),
            new_schedule=json.dumps(rows),
            requested_by=current_user.name,
            approved_by=current_user.name,
            approval_status="approved",
        ))

        db.session.commit()
        flash("Payment schedule saved.", "success")
        return redirect(url_for("contract_view", contract_id=contract.id))

    return render_template(
        "contracts/schedule_builder.html", contract=contract, currencies=CURRENCIES
    )


@app.route("/contracts/<int:contract_id>/schedule/preview", methods=["POST"])
@login_required
def schedule_preview(contract_id):
    contract = _owned_contract(contract_id)
    try:
        rows, remaining_balance, meta = _compute_schedule(contract, request.form)
    except Exception as exc:
        return jsonify({"error": str(exc)}), 400

    total_scheduled = round(sum(r["amount"] for r in rows), 2)
    cutoff = max_months_cutoff(datetime.strptime(meta["start_date"], "%Y-%m-%d").date(), contract.max_payment_months)
    exceeds_months = bool(cutoff and rows and datetime.strptime(rows[-1]["date"], "%Y-%m-%d").date() > cutoff)
    return jsonify({
        "rows": rows,
        "meta": meta,
        "total_contract_value": float(contract.total_amount),
        "currency_code": contract.currency_code,
        "total_scheduled": total_scheduled,
        "remaining_balance": remaining_balance,
        "first_payment_date": rows[0]["date"] if rows else None,
        "final_payment_date": rows[-1]["date"] if rows else None,
        "allow_outstanding_balance": contract.allow_outstanding_balance,
        "max_payment_months": contract.max_payment_months,
        "max_payment_cutoff": cutoff.isoformat() if cutoff else None,
        "exceeds_max_months": exceeds_months,
    })


@app.route("/contracts/<int:contract_id>/delete", methods=["POST"])
@login_required
def contract_delete(contract_id):
    contract = _owned_contract(contract_id)
    title = contract.title
    db.session.delete(contract)
    db.session.commit()
    flash(f'Deleted "{title}" and its payment schedule, audit trail, and share link.', "success")
    return redirect(url_for("contracts_list"))


@app.route("/contracts/<int:contract_id>")
@login_required
def contract_view(contract_id):
    contract = _owned_contract(contract_id)
    if contract.schedule:
        for p in contract.schedule.payments:
            p.refresh_status()
        db.session.commit()
    share_url = url_for("contract_share", token=contract.share_token, _external=True)
    return render_template("contracts/view.html", contract=contract, share_url=share_url)


@app.route("/contracts/<int:contract_id>/send", methods=["POST"])
@login_required
def contract_send(contract_id):
    contract = _owned_contract(contract_id)
    if not contract.schedule:
        flash("Add a payment schedule before sending the contract.", "error")
        return redirect(url_for("contract_view", contract_id=contract.id))
    contract.lock_currency()
    db.session.add(AuditLog(
        contract_id=contract.id, action="contract_sent",
        requested_by=current_user.name, approved_by=current_user.name,
        approval_status="approved",
        requested_change=json.dumps({"summary": f"Contract sent, currency locked to {contract.currency_code}"}),
    ))
    db.session.commit()
    flash("Contract sent and currency locked.", "success")
    return redirect(url_for("contract_view", contract_id=contract.id))


@app.route("/contracts/<int:contract_id>/payments/<int:payment_id>/mark-paid", methods=["POST"])
@login_required
def mark_paid(contract_id, payment_id):
    contract = _owned_contract(contract_id)
    payment = db.session.get(Payment, payment_id)
    if not payment or payment.schedule.contract_id != contract.id:
        abort(404)
    payment.status = "paid"
    payment.paid_at = datetime.utcnow()
    if contract.status != "signed":
        contract.status = "signed"
    db.session.commit()
    return redirect(url_for("contract_view", contract_id=contract.id))


@app.route("/contracts/<int:contract_id>/pdf")
@login_required
def contract_pdf(contract_id):
    contract = _owned_contract(contract_id)
    buf = build_contract_pdf(contract, upload_folder=app.config["UPLOAD_FOLDER"])
    filename = f"{contract.title.replace(' ', '-')}-schedule.pdf"
    return send_file(buf, mimetype="application/pdf", as_attachment=True, download_name=filename)


@app.route("/contracts/<int:contract_id>/audit")
@login_required
def contract_audit(contract_id):
    contract = _owned_contract(contract_id)
    entries = AuditLog.query.filter_by(contract_id=contract.id).order_by(AuditLog.created_at.desc()).all()
    return render_template("contracts/audit.html", contract=contract, entries=entries)


@app.route("/contracts/<int:contract_id>/audit/<int:audit_id>/approve", methods=["POST"])
@login_required
def audit_approve(contract_id, audit_id):
    contract = _owned_contract(contract_id)
    entry = db.session.get(AuditLog, audit_id)
    if not entry or entry.contract_id != contract.id or entry.approval_status != "pending":
        abort(404)

    proposed_rows = entry.new_dict()
    if proposed_rows and contract.schedule:
        for p in list(contract.schedule.payments):
            db.session.delete(p)
        db.session.flush()
        for row in proposed_rows:
            db.session.add(Payment(
                schedule_id=contract.schedule.id,
                sequence=row["sequence"],
                due_date=datetime.strptime(row["date"], "%Y-%m-%d").date(),
                amount=row["amount"],
                label=row.get("label"),
            ))
    entry.approval_status = "approved"
    entry.approved_by = current_user.name
    db.session.commit()
    flash("Change request approved and applied to the schedule.", "success")
    return redirect(url_for("contract_audit", contract_id=contract.id))


@app.route("/contracts/<int:contract_id>/audit/<int:audit_id>/reject", methods=["POST"])
@login_required
def audit_reject(contract_id, audit_id):
    contract = _owned_contract(contract_id)
    entry = db.session.get(AuditLog, audit_id)
    if not entry or entry.contract_id != contract.id or entry.approval_status != "pending":
        abort(404)
    entry.approval_status = "rejected"
    entry.approved_by = current_user.name
    db.session.commit()
    flash("Change request rejected. The existing schedule is unchanged.", "success")
    return redirect(url_for("contract_audit", contract_id=contract.id))


# ------------------------------------------------------ public share link-

def _get_shared_contract_or_404(token):
    contract = Contract.query.filter_by(share_token=token).first()
    if not contract:
        abort(404)
    return contract


@app.route("/share/<token>", methods=["GET"])
def contract_share(token):
    contract = _get_shared_contract_or_404(token)
    if contract.pin_code and not _share_verified(token):
        return render_template("contracts/share_pin.html", contract=contract, token=token)
    if contract.schedule:
        for p in contract.schedule.payments:
            p.refresh_status()
        db.session.commit()
    return render_template("contracts/share.html", contract=contract, token=token)


@app.route("/share/<token>/verify-pin", methods=["POST"])
def contract_share_verify_pin(token):
    contract = _get_shared_contract_or_404(token)
    submitted = (request.form.get("pin") or "").strip()
    if contract.pin_code and submitted == contract.pin_code:
        session[f"share_ok_{token}"] = True
        return redirect(url_for("contract_share", token=token))
    flash("Incorrect PIN. Please try again.", "error")
    return render_template("contracts/share_pin.html", contract=contract, token=token), 401


def _require_share_access(token):
    contract = _get_shared_contract_or_404(token)
    if contract.pin_code and not _share_verified(token):
        abort(403)
    return contract


@app.route("/share/<token>/pdf")
def contract_share_pdf(token):
    contract = _require_share_access(token)
    buf = build_contract_pdf(contract, upload_folder=app.config["UPLOAD_FOLDER"])
    filename = f"{contract.title.replace(' ', '-')}-schedule.pdf"
    return send_file(buf, mimetype="application/pdf", as_attachment=True, download_name=filename)


def _violates_max_months(contract, rows, meta):
    if not contract.max_payment_months or not rows:
        return False
    start = datetime.strptime(meta["start_date"], "%Y-%m-%d").date()
    cutoff = max_months_cutoff(start, contract.max_payment_months)
    final = datetime.strptime(rows[-1]["date"], "%Y-%m-%d").date()
    return cutoff is not None and final > cutoff


@app.route("/share/<token>/schedule", methods=["GET", "POST"])
def public_schedule_builder(token):
    contract = _require_share_access(token)
    if not contract.client_can_build_schedule:
        abort(403)

    if request.method == "POST":
        rows_json = request.form.get("rows_json")
        meta_json = request.form.get("meta_json")
        requester_name = (request.form.get("requester_name") or "Client").strip()
        if not rows_json or not meta_json:
            flash("Generate a preview before confirming the schedule.", "error")
            return redirect(url_for("public_schedule_builder", token=token))

        rows = json.loads(rows_json)
        meta = json.loads(meta_json)
        editing_existing = contract.schedule is not None

        if editing_existing and not contract.allows_schedule_changes:
            abort(403)

        if _violates_max_months(contract, rows, meta):
            flash(f"The full balance must be paid off within {contract.max_payment_months} months of the first payment. Please adjust the schedule.", "error")
            return redirect(url_for("public_schedule_builder", token=token))

        if editing_existing:
            # Existing schedules require staff approval — stage the request only.
            original_snapshot = [
                {"sequence": p.sequence, "date": p.due_date.isoformat(),
                 "amount": float(p.amount), "label": p.label}
                for p in contract.schedule.payments
            ]
            db.session.add(AuditLog(
                contract_id=contract.id,
                action="schedule_change_requested",
                original_schedule=json.dumps(original_snapshot),
                requested_change=json.dumps({"summary": f"Client proposed a {meta['frequency']} schedule, {len(rows)} instalments"}),
                new_schedule=json.dumps(rows),
                requested_by=requester_name,
                approval_status="pending",
            ))
            db.session.commit()
            flash("Thanks — your requested change has been submitted for approval.", "success")
            return redirect(url_for("contract_share", token=token))

        # No schedule yet: client can set it up directly.
        schedule = PaymentSchedule(
            contract_id=contract.id,
            frequency=meta["frequency"],
            start_date=datetime.strptime(meta["start_date"], "%Y-%m-%d").date(),
            day_of_month=meta.get("day_of_month"),
            num_instalments=len(rows),
            auto_end=meta.get("auto_end", True),
            amount_mode=meta.get("amount_mode", "fixed"),
        )
        db.session.add(schedule)
        db.session.flush()
        for row in rows:
            db.session.add(Payment(
                schedule_id=schedule.id,
                sequence=row["sequence"],
                due_date=datetime.strptime(row["date"], "%Y-%m-%d").date(),
                amount=row["amount"],
                label=row.get("label"),
            ))
        db.session.add(AuditLog(
            contract_id=contract.id,
            action="schedule_created",
            requested_change=json.dumps({"summary": f"Client set up a {meta['frequency']} schedule, {len(rows)} instalments"}),
            new_schedule=json.dumps(rows),
            requested_by=requester_name,
            approved_by=requester_name,
            approval_status="approved",
        ))
        db.session.commit()
        flash("Your payment schedule has been set up.", "success")
        return redirect(url_for("contract_share", token=token))

    return render_template("contracts/share_schedule.html", contract=contract, token=token, date=date)


@app.route("/share/<token>/schedule/preview", methods=["POST"])
def public_schedule_preview(token):
    contract = _require_share_access(token)
    try:
        rows, remaining_balance, meta = _compute_schedule(contract, request.form)
    except Exception as exc:
        return jsonify({"error": str(exc)}), 400
    total_scheduled = round(sum(r["amount"] for r in rows), 2)
    cutoff = max_months_cutoff(datetime.strptime(meta["start_date"], "%Y-%m-%d").date(), contract.max_payment_months)
    exceeds_months = bool(cutoff and rows and datetime.strptime(rows[-1]["date"], "%Y-%m-%d").date() > cutoff)
    return jsonify({
        "rows": rows, "meta": meta,
        "total_contract_value": float(contract.total_amount),
        "currency_code": contract.currency_code,
        "total_scheduled": total_scheduled,
        "remaining_balance": remaining_balance,
        "first_payment_date": rows[0]["date"] if rows else None,
        "final_payment_date": rows[-1]["date"] if rows else None,
        "allow_outstanding_balance": contract.allow_outstanding_balance,
        "max_payment_months": contract.max_payment_months,
        "max_payment_cutoff": cutoff.isoformat() if cutoff else None,
        "exceeds_max_months": exceeds_months,
    })


@app.route("/share/<token>/sign", methods=["POST"])
def contract_sign(token):
    contract = _require_share_access(token)
    full_name = (request.form.get("full_name") or "").strip()
    signature_text = (request.form.get("signature_text") or "").strip()
    agree = bool(request.form.get("agree"))
    if not full_name or not signature_text or not agree:
        flash("Enter your name, a typed signature, and confirm you agree before signing.", "error")
        return redirect(url_for("contract_share", token=token))

    contract.signed_by_name = full_name
    contract.signature_text = signature_text
    contract.signed_at = datetime.utcnow()
    if contract.status != "signed":
        contract.status = "signed"
    db.session.add(AuditLog(
        contract_id=contract.id, action="contract_signed",
        requested_by=full_name, approved_by=full_name, approval_status="approved",
        requested_change=json.dumps({"summary": f"Signed by {full_name}"}),
    ))
    db.session.commit()
    flash("Signed — thank you.", "success")
    return redirect(url_for("contract_share", token=token))


# -------------------------------------------------------------- reminders-

@app.route("/reminders", methods=["GET", "POST"])
@login_required
def reminders():
    setting = ReminderSetting.query.filter_by(company_id=current_user.company_id).first()
    if not setting:
        setting = ReminderSetting(company_id=current_user.company_id)
        db.session.add(setting)
        db.session.commit()

    if request.method == "POST":
        setting.days_before_due = int(request.form.get("days_before_due") or 0)
        setting.remind_on_due_date = bool(request.form.get("remind_on_due_date"))
        setting.remind_when_overdue = bool(request.form.get("remind_when_overdue"))
        setting.overdue_repeat_days = int(request.form.get("overdue_repeat_days") or 7)
        db.session.commit()
        flash("Reminder settings saved.", "success")
        return redirect(url_for("reminders"))

    return render_template("reminders.html", setting=setting)


# ---------------------------------------------------------------- branding-

def _valid_hex_color(value):
    if not value:
        return False
    v = value.strip()
    return bool(re.fullmatch(r"#[0-9A-Fa-f]{6}", v))


@app.route("/branding", methods=["GET", "POST"])
@login_required
def branding():
    company = current_user.company

    if request.method == "POST":
        display_name = (request.form.get("brand_display_name") or "").strip()
        company.brand_display_name = display_name or None

        bg = (request.form.get("brand_bg_color") or "").strip()
        accent = (request.form.get("brand_accent_color") or "").strip()
        if _valid_hex_color(bg):
            company.brand_bg_color = bg
        if _valid_hex_color(accent):
            company.brand_accent_color = accent

        remove_logo = bool(request.form.get("remove_logo"))
        if remove_logo and company.brand_logo_filename:
            old_path = os.path.join(app.config["UPLOAD_FOLDER"], company.brand_logo_filename)
            if os.path.isfile(old_path):
                os.remove(old_path)
            company.brand_logo_filename = None

        logo_file = request.files.get("logo")
        if logo_file and logo_file.filename:
            ext = logo_file.filename.rsplit(".", 1)[-1].lower() if "." in logo_file.filename else ""
            if ext not in ALLOWED_LOGO_EXTENSIONS:
                flash("Logo must be a PNG or JPG image.", "error")
                return redirect(url_for("branding"))
            if company.brand_logo_filename:
                old_path = os.path.join(app.config["UPLOAD_FOLDER"], company.brand_logo_filename)
                if os.path.isfile(old_path):
                    os.remove(old_path)
            filename = secure_filename(f"company_{company.id}_logo.{ext}")
            logo_file.save(os.path.join(app.config["UPLOAD_FOLDER"], filename))
            company.brand_logo_filename = filename

        db.session.commit()
        flash("Branding saved. New PDFs and share pages will use it right away.", "success")
        return redirect(url_for("branding"))

    return render_template("branding.html", company=company)


@app.route("/uploads/<path:filename>")
def uploaded_file(filename):
    return send_from_directory(app.config["UPLOAD_FOLDER"], filename)


def run_startup_migrations():
    """Self-healing migration: adds any columns models.py defines that are
    missing from the live SQLite database, for every model table. This
    means an existing ledgerly.db from an older version of the app fixes
    itself the moment the app is restarted — no manual migration step
    required, regardless of which table gained new columns."""
    from sqlalchemy import inspect, text

    inspector = inspect(db.engine)
    sqlite_type_map = {
        "VARCHAR": "VARCHAR", "TEXT": "TEXT", "BOOLEAN": "BOOLEAN",
        "DATETIME": "DATETIME", "NUMERIC": "NUMERIC", "INTEGER": "INTEGER",
    }

    for table_name, model in (("contract", Contract), ("company", Company)):
        if not inspector.has_table(table_name):
            continue  # brand new database — db.create_all() already made it correctly

        existing_columns = {col["name"] for col in inspector.get_columns(table_name)}
        model_columns = {col.name: col for col in model.__table__.columns}

        with db.engine.begin() as conn:
            for name, col in model_columns.items():
                if name in existing_columns:
                    continue
                col_type = str(col.type)
                base_type = col_type.split("(")[0].upper()
                sqlite_type = sqlite_type_map.get(base_type, "TEXT")
                conn.execute(text(f"ALTER TABLE {table_name} ADD COLUMN {name} {sqlite_type}"))
                print(f"[startup migration] added missing column {table_name}.{name}")


with app.app_context():
    db.create_all()
    run_startup_migrations()


if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=5095)
