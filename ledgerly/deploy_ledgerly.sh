#!/usr/bin/env bash
# Ledgerly full deployment sync script
# Rewrites every application file to match the latest version exactly.
# Safe to re-run. Does NOT touch ledgerly.db (your data is preserved).
set -e

echo "Ledgerly sync: writing $(basename "$PWD")/... files"

cat > 'README.md' << 'LEDGERLY_FILE_EOF'
# Ledgerly

A small Flask + Tailwind app for client payment schedules and multi-currency
contracts: company setup, contract creation, a flexible payment schedule
builder with live editable preview, a searchable ISO 4217 currency selector,
a payment dashboard, shareable client links (optionally PIN-protected), a
rich-text agreement/terms editor with a typed e-signature block, PDF
download, reminder settings, and a full schedule-change audit trail with
staff approve/reject.

## Run it locally

```bash
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
python3 app.py
```

Open **http://localhost:5000** and click **"Set up your company"** to create
your workspace (this creates a `Company` + your first user). Then:

1. **Clients** → add a client.
2. **+ New contract** → title, client, total amount, search/select a
   currency (try typing `pound`, `GBP`, or `£`), and optionally: paste in
   agreement/terms text, tick "let the client set up the schedule
   themselves," and tick "protect the share link with a PIN" (a 4-digit PIN
   is generated automatically — you'll see it on the contract page after).
3. You'll land on the **schedule builder** — pick a frequency (monthly,
   weekly, quarterly, custom dates, etc.) and an amount mode (split evenly,
   percentage, or custom per instalment), click **Generate preview**, edit
   any date/label/amount inline, then **Confirm schedule**. (You can skip
   this step entirely and let the client build it instead — see below.)
4. On the contract page you can **Send for signing** (locks the currency),
   mark instalments **paid**, **Download PDF**, edit the **Agreement &
   sharing** settings (terms text, PIN, whether the client can self-serve
   the schedule), or **copy the share link** to send to the client.
5. **The share link** (`/share/<token>`) is a public, no-login page. If a
   PIN was set, the client enters it once (held in their browser session)
   before seeing anything. From there they can:
   - View the schedule and **download the PDF**.
   - **Set up the payment schedule themselves**, if no schedule exists yet
     and you've allowed it — same builder UI, applied immediately.
   - **Request a change** to an existing schedule — this is *staged*, not
     applied immediately; it shows up as "pending" on your **audit trail**
     page with **Approve & apply** / **Reject** buttons.
   - **Read the agreement** and **sign it** by typing their name — this sets
     the contract to "signed" and the signature appears on the share page
     and in the downloaded PDF.
6. **Reminders** (top nav) configures days-before-due / on-due / overdue
   notification rules per company.
7. Every schedule create/edit, send, sign, and change request/approval is
   written to the contract's **audit trail** (`Instalments → View audit
   trail`), including who requested it and who approved or rejected it.

## Notes on this build

- **Storage**: SQLite (`ledgerly.db`, created automatically on first run).
  Fine for a prototype/demo; swap `SQLALCHEMY_DATABASE_URI` in `app.py` for
  Postgres etc. in production. The app self-heals its own schema on
  startup: if you're running an older `ledgerly.db` that predates a field
  added later (e.g. `agreement_text`, `pin_code`), it adds the missing
  columns automatically the moment you restart the app — no manual step,
  no lost data. You'll see lines like `[startup migration] added missing
  column contract.pin_code` in the console when that happens. (A standalone
  `migrate_add_agreement_fields.py` script is also included for the same
  purpose if you'd rather run it separately.)
- **Auth**: simple email/password via Flask-Login, one company per
  registration. Good enough to demo multi-user/multi-company isolation, not
  hardened for production (no password reset, rate limiting, 2FA, etc.).
- **Currency list**: `currencies.py` holds a maintained ISO 4217-style list
  (code, name, symbol, flag) that powers `/api/currencies`, used by the
  reusable `currency-select` JS widget (`static/js/currency-select.js`).
- **Reminders**: settings are stored and shown on the Reminders page, but no
  email/SMS sender is wired up yet — that's the natural next step (e.g. a
  scheduled job that queries upcoming/overdue `Payment` rows and calls an
  email provider).
- **Schedule change requests**: fully wired end to end. The client's first
  schedule (when none exists yet) is applied immediately since there's
  nothing to protect. Any change to an *existing* schedule — from the client
  via the share link — is staged in the audit log as `pending` and only
  takes effect once staff clicks **Approve & apply** on the audit trail page;
  **Reject** leaves the current schedule untouched. Staff edits from inside
  the dashboard still apply immediately (they don't need to approve
  themselves).
- **PIN protection**: optional per contract, 4 digits, auto-generated,
  regenerable from the Agreement & sharing page. Verified PINs are held in
  a signed session cookie scoped to that share token, so the client doesn't
  have to re-enter it on every page view in the same browser session.
- **Signing**: a typed-name signature (name + a typed "signature" string),
  not a drawn signature — swap in a `<canvas>`-based pad if you need an
  actual drawn signature image later. Signing sets `Contract.signed_at` /
  `signed_by_name` / `signature_text`, flips status to "signed," and is
  included in the PDF.
- **Agreement editor**: a rich-text editor (Quill, via CDN) supporting
  headings, bold/italic/underline, ordered/unordered lists, blockquotes, and
  links — not a plain textarea. Content is sanitized server-side
  (`richtext.py`, via `bleach`) against a small safe-tag allowlist before
  it's stored, and rendered with Tailwind's `prose` classes on the share
  page. The editor lives on both the "New contract" page and the
  "Agreement & sharing" settings page, each with a live preview of exactly
  what the client will see. The PDF export (`pdf_export.py`) parses the
  same stored HTML into headings/bold/italic/lists/blockquotes rather than
  flattening it to plain paragraphs. Agreements saved by an older version of
  this app (plain text with blank-line paragraphs) still render correctly —
  it's detected automatically and formatted as paragraphs, no migration
  needed.
- **PDF export** uses ReportLab (`pdf_export.py`) and is available both to
  staff (`/contracts/<id>/pdf`) and on the public share page.

## Project structure

```
app.py                      # routes
models.py                   # SQLAlchemy models
scheduling.py                # frequency/amount → instalment-list logic
currencies.py                 # ISO 4217 reference data
pdf_export.py                  # ReportLab PDF builder
templates/                      # Jinja2 + Tailwind (CDN) templates
static/js/currency-select.js      # searchable currency dropdown
static/js/schedule-builder.js       # schedule builder + editable preview
```
LEDGERLY_FILE_EOF

cat > 'app.py' << 'LEDGERLY_FILE_EOF'
import json
import os
import random
from datetime import date, datetime

from flask import (
    Flask, render_template, request, redirect, url_for, flash, jsonify,
    send_file, abort, session
)
from flask_login import (
    login_user, logout_user, login_required, current_user, LoginManager
)

from extensions import db, login_manager
from models import (
    Company, User, Client, Contract, PaymentSchedule, Payment,
    ReminderSetting, AuditLog, gen_token
)
from currencies import CURRENCIES, get_currency
from scheduling import build_dates, build_amounts, label_for
from pdf_export import build_contract_pdf
from richtext import clean_agreement_html

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

app = Flask(__name__)
app.config["SECRET_KEY"] = "dev-secret-change-me"
app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{os.path.join(BASE_DIR, 'ledgerly.db')}"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

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
    })


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
    buf = build_contract_pdf(contract)
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
    buf = build_contract_pdf(contract)
    filename = f"{contract.title.replace(' ', '-')}-schedule.pdf"
    return send_file(buf, mimetype="application/pdf", as_attachment=True, download_name=filename)


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
    return jsonify({
        "rows": rows, "meta": meta,
        "total_contract_value": float(contract.total_amount),
        "currency_code": contract.currency_code,
        "total_scheduled": total_scheduled,
        "remaining_balance": remaining_balance,
        "first_payment_date": rows[0]["date"] if rows else None,
        "final_payment_date": rows[-1]["date"] if rows else None,
        "allow_outstanding_balance": contract.allow_outstanding_balance,
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


def run_startup_migrations():
    """Self-healing migration: adds any columns models.py defines that are
    missing from the live SQLite database. This means an existing
    ledgerly.db from an older version of the app fixes itself the moment
    the app is restarted — no manual migration step required."""
    from sqlalchemy import inspect, text

    inspector = inspect(db.engine)
    if not inspector.has_table("contract"):
        return  # brand new database — db.create_all() will make it correctly

    existing_columns = {col["name"] for col in inspector.get_columns("contract")}
    model_columns = {col.name: col for col in Contract.__table__.columns}

    sqlite_type_map = {
        "VARCHAR": "VARCHAR", "TEXT": "TEXT", "BOOLEAN": "BOOLEAN",
        "DATETIME": "DATETIME", "NUMERIC": "NUMERIC", "INTEGER": "INTEGER",
    }

    with db.engine.begin() as conn:
        for name, col in model_columns.items():
            if name in existing_columns:
                continue
            col_type = str(col.type)
            base_type = col_type.split("(")[0].upper()
            sqlite_type = sqlite_type_map.get(base_type, "TEXT")
            conn.execute(text(f"ALTER TABLE contract ADD COLUMN {name} {sqlite_type}"))
            print(f"[startup migration] added missing column contract.{name}")


with app.app_context():
    db.create_all()
    run_startup_migrations()


if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=5095)
LEDGERLY_FILE_EOF

cat > 'currencies.py' << 'LEDGERLY_FILE_EOF'
# ISO 4217 currency reference data used to power the searchable currency
# selector. Kept as a single maintained list (per spec section 4) rather
# than scattering currency literals through the app.

CURRENCIES = [
    {"code": "GBP", "name": "British Pound", "symbol": "£", "flag": "🇬🇧"},
    {"code": "USD", "name": "US Dollar", "symbol": "$", "flag": "🇺🇸"},
    {"code": "EUR", "name": "Euro", "symbol": "€", "flag": "🇪🇺"},
    {"code": "CAD", "name": "Canadian Dollar", "symbol": "$", "flag": "🇨🇦"},
    {"code": "AUD", "name": "Australian Dollar", "symbol": "$", "flag": "🇦🇺"},
    {"code": "JPY", "name": "Japanese Yen", "symbol": "¥", "flag": "🇯🇵"},
    {"code": "CNY", "name": "Chinese Yuan", "symbol": "¥", "flag": "🇨🇳"},
    {"code": "INR", "name": "Indian Rupee", "symbol": "₹", "flag": "🇮🇳"},
    {"code": "CHF", "name": "Swiss Franc", "symbol": "CHF", "flag": "🇨🇭"},
    {"code": "NZD", "name": "New Zealand Dollar", "symbol": "$", "flag": "🇳🇿"},
    {"code": "SEK", "name": "Swedish Krona", "symbol": "kr", "flag": "🇸🇪"},
    {"code": "NOK", "name": "Norwegian Krone", "symbol": "kr", "flag": "🇳🇴"},
    {"code": "DKK", "name": "Danish Krone", "symbol": "kr", "flag": "🇩🇰"},
    {"code": "PLN", "name": "Polish Złoty", "symbol": "zł", "flag": "🇵🇱"},
    {"code": "AED", "name": "UAE Dirham", "symbol": "د.إ", "flag": "🇦🇪"},
    {"code": "SAR", "name": "Saudi Riyal", "symbol": "﷼", "flag": "🇸🇦"},
    {"code": "ZAR", "name": "South African Rand", "symbol": "R", "flag": "🇿🇦"},
    {"code": "BRL", "name": "Brazilian Real", "symbol": "R$", "flag": "🇧🇷"},
    {"code": "MXN", "name": "Mexican Peso", "symbol": "$", "flag": "🇲🇽"},
    {"code": "SGD", "name": "Singapore Dollar", "symbol": "$", "flag": "🇸🇬"},
    {"code": "HKD", "name": "Hong Kong Dollar", "symbol": "$", "flag": "🇭🇰"},
    {"code": "KRW", "name": "South Korean Won", "symbol": "₩", "flag": "🇰🇷"},
    {"code": "TRY", "name": "Turkish Lira", "symbol": "₺", "flag": "🇹🇷"},
    {"code": "RUB", "name": "Russian Ruble", "symbol": "₽", "flag": "🇷🇺"},
    {"code": "THB", "name": "Thai Baht", "symbol": "฿", "flag": "🇹🇭"},
    {"code": "IDR", "name": "Indonesian Rupiah", "symbol": "Rp", "flag": "🇮🇩"},
    {"code": "MYR", "name": "Malaysian Ringgit", "symbol": "RM", "flag": "🇲🇾"},
    {"code": "PHP", "name": "Philippine Peso", "symbol": "₱", "flag": "🇵🇭"},
    {"code": "VND", "name": "Vietnamese Dong", "symbol": "₫", "flag": "🇻🇳"},
    {"code": "ILS", "name": "Israeli New Shekel", "symbol": "₪", "flag": "🇮🇱"},
    {"code": "EGP", "name": "Egyptian Pound", "symbol": "£", "flag": "🇪🇬"},
    {"code": "NGN", "name": "Nigerian Naira", "symbol": "₦", "flag": "🇳🇬"},
    {"code": "KES", "name": "Kenyan Shilling", "symbol": "KSh", "flag": "🇰🇪"},
    {"code": "GHS", "name": "Ghanaian Cedi", "symbol": "₵", "flag": "🇬🇭"},
    {"code": "PKR", "name": "Pakistani Rupee", "symbol": "₨", "flag": "🇵🇰"},
    {"code": "BDT", "name": "Bangladeshi Taka", "symbol": "৳", "flag": "🇧🇩"},
    {"code": "LKR", "name": "Sri Lankan Rupee", "symbol": "₨", "flag": "🇱🇰"},
    {"code": "QAR", "name": "Qatari Riyal", "symbol": "﷼", "flag": "🇶🇦"},
    {"code": "KWD", "name": "Kuwaiti Dinar", "symbol": "د.ك", "flag": "🇰🇼"},
    {"code": "BHD", "name": "Bahraini Dinar", "symbol": ".د.ب", "flag": "🇧🇭"},
    {"code": "OMR", "name": "Omani Rial", "symbol": "﷼", "flag": "🇴🇲"},
    {"code": "JOD", "name": "Jordanian Dinar", "symbol": "د.ا", "flag": "🇯🇴"},
    {"code": "CZK", "name": "Czech Koruna", "symbol": "Kč", "flag": "🇨🇿"},
    {"code": "HUF", "name": "Hungarian Forint", "symbol": "Ft", "flag": "🇭🇺"},
    {"code": "RON", "name": "Romanian Leu", "symbol": "lei", "flag": "🇷🇴"},
    {"code": "ISK", "name": "Icelandic Króna", "symbol": "kr", "flag": "🇮🇸"},
    {"code": "UAH", "name": "Ukrainian Hryvnia", "symbol": "₴", "flag": "🇺🇦"},
    {"code": "ARS", "name": "Argentine Peso", "symbol": "$", "flag": "🇦🇷"},
    {"code": "CLP", "name": "Chilean Peso", "symbol": "$", "flag": "🇨🇱"},
    {"code": "COP", "name": "Colombian Peso", "symbol": "$", "flag": "🇨🇴"},
    {"code": "PEN", "name": "Peruvian Sol", "symbol": "S/", "flag": "🇵🇪"},
    {"code": "TWD", "name": "New Taiwan Dollar", "symbol": "$", "flag": "🇹🇼"},
    {"code": "TZS", "name": "Tanzanian Shilling", "symbol": "TSh", "flag": "🇹🇿"},
    {"code": "MAD", "name": "Moroccan Dirham", "symbol": "د.م.", "flag": "🇲🇦"},
    {"code": "DZD", "name": "Algerian Dinar", "symbol": "د.ج", "flag": "🇩🇿"},
    {"code": "IQD", "name": "Iraqi Dinar", "symbol": "ع.د", "flag": "🇮🇶"},
    {"code": "XOF", "name": "West African CFA Franc", "symbol": "CFA", "flag": "🌍"},
    {"code": "XAF", "name": "Central African CFA Franc", "symbol": "FCFA", "flag": "🌍"},
]

# Simple lookups keyed by ISO code, e.g. for validating stored contract currencies.
CURRENCY_BY_CODE = {c["code"]: c for c in CURRENCIES}


def get_currency(code):
    return CURRENCY_BY_CODE.get((code or "").upper())
LEDGERLY_FILE_EOF

cat > 'extensions.py' << 'LEDGERLY_FILE_EOF'
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager

db = SQLAlchemy()
login_manager = LoginManager()
LEDGERLY_FILE_EOF

cat > 'migrate_add_agreement_fields.py' << 'LEDGERLY_FILE_EOF'
"""
One-off migration: adds the agreement/PIN/signature columns to an existing
ledgerly.db created before those features existed. Safe to run more than
once — it checks which columns already exist first.

Usage (from the project folder, with your venv active):
    python3 migrate_add_agreement_fields.py
"""
import sqlite3
import os

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ledgerly.db")

NEW_COLUMNS = [
    ("agreement_text", "TEXT"),
    ("signed_by_name", "VARCHAR(160)"),
    ("signature_text", "VARCHAR(200)"),
    ("signed_at", "DATETIME"),
    ("pin_code", "VARCHAR(10)"),
    ("client_can_build_schedule", "BOOLEAN DEFAULT 1"),
]


def main():
    if not os.path.exists(DB_PATH):
        print(f"No database found at {DB_PATH} — nothing to migrate. "
              f"Just run the app and it'll create a fresh one with all columns.")
        return

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("PRAGMA table_info(contract)")
    existing = {row[1] for row in cur.fetchall()}

    added = []
    for name, coltype in NEW_COLUMNS:
        if name not in existing:
            cur.execute(f"ALTER TABLE contract ADD COLUMN {name} {coltype}")
            added.append(name)

    conn.commit()
    conn.close()

    if added:
        print(f"Added columns to contract table: {', '.join(added)}")
    else:
        print("Database already has all columns — nothing to do.")


if __name__ == "__main__":
    main()
LEDGERLY_FILE_EOF

cat > 'models.py' << 'LEDGERLY_FILE_EOF'
import json
import secrets
from datetime import date, datetime

from flask_login import UserMixin
from werkzeug.security import check_password_hash, generate_password_hash

from extensions import db


def gen_token(n=20):
    return secrets.token_urlsafe(n)


class Company(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    default_currency = db.Column(db.String(3), default="GBP")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    users = db.relationship("User", backref="company", lazy=True)
    clients = db.relationship("Client", backref="company", lazy=True)
    contracts = db.relationship("Contract", backref="company", lazy=True)


class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False)
    name = db.Column(db.String(120), nullable=False)
    email = db.Column(db.String(160), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def set_password(self, pw):
        self.password_hash = generate_password_hash(pw)

    def check_password(self, pw):
        return check_password_hash(self.password_hash, pw)


class Client(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False)
    name = db.Column(db.String(160), nullable=False)
    email = db.Column(db.String(160))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    contracts = db.relationship("Contract", backref="client", lazy=True)


class Contract(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False)
    client_id = db.Column(db.Integer, db.ForeignKey("client.id"), nullable=False)
    title = db.Column(db.String(200), nullable=False)
    total_amount = db.Column(db.Numeric(12, 2), nullable=False)
    currency_code = db.Column(db.String(3), nullable=False)
    allow_outstanding_balance = db.Column(db.Boolean, default=False)
    allows_schedule_changes = db.Column(db.Boolean, default=True)
    status = db.Column(db.String(20), default="draft")  # draft / sent / signed
    currency_locked = db.Column(db.Boolean, default=False)
    share_token = db.Column(db.String(64), unique=True, default=gen_token)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    # Agreement text + e-signature
    agreement_text = db.Column(db.Text)
    signed_by_name = db.Column(db.String(160))
    signature_text = db.Column(db.String(200))
    signed_at = db.Column(db.DateTime)

    # Share link protection + client self-serve schedule setup
    pin_code = db.Column(db.String(10))
    client_can_build_schedule = db.Column(db.Boolean, default=True)

    schedule = db.relationship(
        "PaymentSchedule", backref="contract", uselist=False, cascade="all, delete-orphan"
    )
    audit_entries = db.relationship(
        "AuditLog", backref="contract", lazy=True, cascade="all, delete-orphan",
        order_by="desc(AuditLog.created_at)"
    )

    def lock_currency(self):
        self.currency_locked = True
        self.status = "sent"

    @property
    def is_signed(self):
        return self.signed_at is not None

    @property
    def amount_paid(self):
        if not self.schedule:
            return 0
        return sum(float(p.amount) for p in self.schedule.payments if p.status == "paid")

    @property
    def amount_remaining(self):
        return float(self.total_amount) - self.amount_paid

    @property
    def next_payment(self):
        if not self.schedule:
            return None
        upcoming = [p for p in self.schedule.payments if p.status in ("upcoming", "overdue")]
        upcoming.sort(key=lambda p: p.due_date)
        return upcoming[0] if upcoming else None

    @property
    def overdue_amount(self):
        if not self.schedule:
            return 0
        today = date.today()
        total = 0.0
        for p in self.schedule.payments:
            if p.status != "paid" and p.due_date < today:
                total += float(p.amount)
        return total

    @property
    def remaining_instalments(self):
        if not self.schedule:
            return 0
        return len([p for p in self.schedule.payments if p.status != "paid"])


class PaymentSchedule(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    contract_id = db.Column(db.Integer, db.ForeignKey("contract.id"), nullable=False)
    frequency = db.Column(db.String(20), nullable=False)  # one_time/weekly/biweekly/monthly/bimonthly/quarterly/custom
    start_date = db.Column(db.Date, nullable=False)
    day_of_month = db.Column(db.Integer)  # only for monthly-style
    num_instalments = db.Column(db.Integer, nullable=False)
    auto_end = db.Column(db.Boolean, default=True)
    amount_mode = db.Column(db.String(20), default="fixed")  # fixed/percentage/custom
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    payments = db.relationship(
        "Payment", backref="schedule", lazy=True, cascade="all, delete-orphan",
        order_by="Payment.sequence"
    )

    @property
    def total_scheduled(self):
        return sum(float(p.amount) for p in self.payments)

    @property
    def first_payment_date(self):
        return self.payments[0].due_date if self.payments else None

    @property
    def final_payment_date(self):
        return self.payments[-1].due_date if self.payments else None


class Payment(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    schedule_id = db.Column(db.Integer, db.ForeignKey("payment_schedule.id"), nullable=False)
    sequence = db.Column(db.Integer, nullable=False)
    due_date = db.Column(db.Date, nullable=False)
    amount = db.Column(db.Numeric(12, 2), nullable=False)
    label = db.Column(db.String(60))  # e.g. Deposit / Final payment
    status = db.Column(db.String(20), default="upcoming")  # upcoming/paid/overdue
    paid_at = db.Column(db.DateTime)

    def refresh_status(self):
        if self.status == "paid":
            return
        self.status = "overdue" if self.due_date < date.today() else "upcoming"


class ReminderSetting(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False, unique=True)
    days_before_due = db.Column(db.Integer, default=3)
    remind_on_due_date = db.Column(db.Boolean, default=True)
    remind_when_overdue = db.Column(db.Boolean, default=True)
    overdue_repeat_days = db.Column(db.Integer, default=7)


class AuditLog(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    contract_id = db.Column(db.Integer, db.ForeignKey("contract.id"), nullable=False)
    action = db.Column(db.String(60), nullable=False)
    original_schedule = db.Column(db.Text)  # JSON snapshot
    requested_change = db.Column(db.Text)   # JSON description
    new_schedule = db.Column(db.Text)       # JSON snapshot
    requested_by = db.Column(db.String(160))
    approved_by = db.Column(db.String(160))
    approval_status = db.Column(db.String(20), default="pending")  # pending/approved/rejected
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def original_dict(self):
        return json.loads(self.original_schedule) if self.original_schedule else None

    def new_dict(self):
        return json.loads(self.new_schedule) if self.new_schedule else None

    def change_dict(self):
        return json.loads(self.requested_change) if self.requested_change else None
LEDGERLY_FILE_EOF

cat > 'pdf_export.py' << 'LEDGERLY_FILE_EOF'
import io
import re
from datetime import date

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.platypus import (
    SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
)
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

from currencies import get_currency

INK = colors.HexColor("#1c1a15")
GOLD = colors.HexColor("#B08D3E")
MUTED = colors.HexColor("#6b6559")

_BLOCK_RE = re.compile(
    r"<(h1|h2|h3|p|blockquote)>(.*?)</\1>|<(ul|ol)>(.*?)</\3>", re.S | re.I
)
_LI_RE = re.compile(r"<li>(.*?)</li>", re.S | re.I)


def _inline_to_reportlab(html_fragment):
    """Map the sanitized inline tags we allow onto ReportLab's mini markup."""
    text = html_fragment
    text = re.sub(r"</?strong>", lambda m: "</b>" if m.group(0).startswith("</") else "<b>", text, flags=re.I)
    text = re.sub(r"</?em>", lambda m: "</i>" if m.group(0).startswith("</") else "<i>", text, flags=re.I)
    text = text.replace("<br>", "<br/>").replace("<br/>", "<br/>\n")
    return text.strip()


def agreement_flowables(agreement_text, styles):
    """Turn stored agreement content (rich HTML, or legacy plain text with
    blank-line paragraphs) into a list of ReportLab flowables."""
    body_style = ParagraphStyle("AgreeBody", parent=styles["Normal"], textColor=INK, fontSize=10, leading=15, spaceAfter=8)
    h_style = ParagraphStyle("AgreeH", parent=styles["Normal"], textColor=INK, fontSize=13, leading=17, fontName="Helvetica-Bold", spaceBefore=10, spaceAfter=6)
    quote_style = ParagraphStyle("AgreeQuote", parent=body_style, leftIndent=14, textColor=MUTED, fontName="Helvetica-Oblique")
    li_style = ParagraphStyle("AgreeLi", parent=body_style, leftIndent=14, spaceAfter=4)

    elems = []
    blocks = list(_BLOCK_RE.finditer(agreement_text or ""))

    if not blocks:
        # Legacy plain-text content (pre rich-text editor): blank-line paragraphs.
        for para in (agreement_text or "").strip().split("\n\n"):
            if not para.strip():
                continue
            safe = para.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br/>")
            elems.append(Paragraph(safe, body_style))
        return elems

    for m in blocks:
        tag, inner, list_tag, list_inner = m.group(1), m.group(2), m.group(3), m.group(4)
        if tag:
            content = _inline_to_reportlab(inner)
            if not content:
                continue
            if tag.lower() in ("h1", "h2", "h3"):
                elems.append(Paragraph(content, h_style))
            elif tag.lower() == "blockquote":
                elems.append(Paragraph(content, quote_style))
            else:
                elems.append(Paragraph(content, body_style))
        elif list_tag:
            items = _LI_RE.findall(list_inner)
            for i, item in enumerate(items, start=1):
                bullet = "•" if list_tag.lower() == "ul" else f"{i}."
                elems.append(Paragraph(f"{bullet}&nbsp;&nbsp;{_inline_to_reportlab(item)}", li_style))
    return elems


def money(amount, code):
    cur = get_currency(code)
    symbol = cur["symbol"] if cur else code
    return f"{symbol}{float(amount):,.2f}"


def build_contract_pdf(contract):
    buf = io.BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        topMargin=22 * mm, bottomMargin=18 * mm,
        leftMargin=20 * mm, rightMargin=20 * mm,
    )
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "Title", parent=styles["Title"], textColor=INK, fontSize=22, spaceAfter=2,
    )
    eyebrow_style = ParagraphStyle(
        "Eyebrow", parent=styles["Normal"], textColor=GOLD, fontSize=10,
        spaceAfter=14, fontName="Helvetica-Bold",
    )
    label_style = ParagraphStyle("Label", parent=styles["Normal"], textColor=MUTED, fontSize=9)
    value_style = ParagraphStyle("Value", parent=styles["Normal"], textColor=INK, fontSize=12)

    elems = []
    elems.append(Paragraph("LEDGERLY &nbsp;&middot;&nbsp; PAYMENT SCHEDULE", eyebrow_style))
    elems.append(Paragraph(contract.title, title_style))
    elems.append(Paragraph(f"Client: {contract.client.name}", value_style))
    elems.append(Spacer(1, 14))

    summary_data = [
        ["Total contract value", money(contract.total_amount, contract.currency_code)],
        ["Currency", f"{contract.currency_code}"],
        ["Amount paid", money(contract.amount_paid, contract.currency_code)],
        ["Remaining balance", money(contract.amount_remaining, contract.currency_code)],
        ["Status", contract.status.upper()],
    ]
    t = Table(summary_data, colWidths=[70 * mm, 90 * mm])
    t.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (0, -1), "Helvetica"),
        ("FONTNAME", (1, 0), (1, -1), "Helvetica-Bold"),
        ("TEXTCOLOR", (0, 0), (0, -1), MUTED),
        ("TEXTCOLOR", (1, 0), (1, -1), INK),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 0), (-1, -2), 0.5, colors.HexColor("#e3ddcb")),
    ]))
    elems.append(t)
    elems.append(Spacer(1, 22))

    elems.append(Paragraph("INSTALMENTS", eyebrow_style))
    if contract.schedule:
        rows = [["#", "Date", "Description", "Amount", "Status"]]
        for p in contract.schedule.payments:
            rows.append([
                str(p.sequence),
                p.due_date.strftime("%-d %B %Y") if hasattr(p.due_date, "strftime") else str(p.due_date),
                p.label or "Instalment",
                money(p.amount, contract.currency_code),
                p.status.capitalize(),
            ])
        pt = Table(rows, colWidths=[10 * mm, 38 * mm, 45 * mm, 32 * mm, 25 * mm], repeatRows=1)
        pt.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), INK),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#f4f1e8")),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("FONTSIZE", (0, 0), (-1, -1), 9.5),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f7f4ea")]),
            ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#e3ddcb")),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ("ALIGN", (3, 0), (3, -1), "RIGHT"),
        ]))
        elems.append(pt)
    else:
        elems.append(Paragraph("No payment schedule has been created for this contract yet.", value_style))

    if contract.agreement_text and contract.agreement_text.strip():
        elems.append(Spacer(1, 24))
        elems.append(Paragraph("AGREEMENT", eyebrow_style))
        elems.extend(agreement_flowables(contract.agreement_text, styles))

    elems.append(Spacer(1, 18))
    elems.append(Paragraph("SIGNATURE", eyebrow_style))
    if contract.is_signed:
        sig_style = ParagraphStyle("Sig", parent=styles["Normal"], textColor=INK, fontSize=14, fontName="Helvetica-Oblique")
        elems.append(Paragraph(contract.signature_text or contract.signed_by_name, sig_style))
        elems.append(Paragraph(
            f"Signed by {contract.signed_by_name} on {contract.signed_at.strftime('%-d %B %Y')}",
            ParagraphStyle("SigMeta", parent=styles["Normal"], textColor=MUTED, fontSize=9),
        ))
    else:
        elems.append(Paragraph(
            "Not yet signed. &nbsp;&nbsp;&nbsp; Signature: ______________________  &nbsp;&nbsp; Date: ____________",
            value_style,
        ))

    elems.append(Spacer(1, 24))
    elems.append(Paragraph(
        f"Generated by Ledgerly on {date.today().strftime('%-d %B %Y')}.",
        ParagraphStyle("Footer", parent=styles["Normal"], textColor=MUTED, fontSize=8),
    ))

    doc.build(elems)
    buf.seek(0)
    return buf
LEDGERLY_FILE_EOF

cat > 'requirements.txt' << 'LEDGERLY_FILE_EOF'
Flask==3.0.3
Flask-SQLAlchemy==3.1.1
Flask-Login==0.6.3
reportlab==4.2.5
bleach==6.1.0
LEDGERLY_FILE_EOF

cat > 'richtext.py' << 'LEDGERLY_FILE_EOF'
import bleach

ALLOWED_TAGS = [
    "p", "br", "strong", "b", "em", "i", "u", "s",
    "h1", "h2", "h3", "ul", "ol", "li", "blockquote", "a", "span",
]
ALLOWED_ATTRS = {
    "a": ["href", "target", "rel"],
    "span": ["class"],
}
ALLOWED_PROTOCOLS = ["http", "https", "mailto"]


def clean_agreement_html(raw_html):
    """Sanitize rich-text agreement HTML coming from the Quill editor before
    it's stored or rendered. Strips anything outside a small safe allowlist
    (scripts, styles, event handlers, iframes, etc.)."""
    if not raw_html or not raw_html.strip():
        return None
    cleaned = bleach.clean(
        raw_html,
        tags=ALLOWED_TAGS,
        attributes=ALLOWED_ATTRS,
        protocols=ALLOWED_PROTOCOLS,
        strip=True,
    )
    # Quill leaves behind empty "<p><br></p>" for blank lines — collapse a
    # document that's *only* empty paragraphs down to nothing.
    stripped = cleaned.replace("<p><br></p>", "").strip()
    return cleaned if stripped else None
LEDGERLY_FILE_EOF

cat > 'scheduling.py' << 'LEDGERLY_FILE_EOF'
"""Turns payment-schedule-builder input into a concrete list of instalments."""
from datetime import date, timedelta
import calendar


def add_months(d: date, months: int, day_of_month: int | None = None) -> date:
    month_index = d.month - 1 + months
    year = d.year + month_index // 12
    month = month_index % 12 + 1
    day = day_of_month or d.day
    last_day = calendar.monthrange(year, month)[1]
    day = min(day, last_day)
    return date(year, month, day)


FREQUENCY_STEPS = {
    "weekly": ("days", 7),
    "biweekly": ("days", 14),
    "monthly": ("months", 1),
    "bimonthly": ("months", 2),
    "quarterly": ("months", 3),
}


def build_dates(frequency, start_date, num_instalments, day_of_month=None, custom_dates=None):
    """Return a list of `date` objects, one per instalment."""
    if frequency == "one_time":
        return [start_date]

    if frequency == "custom":
        return sorted(custom_dates or [start_date])

    unit, step = FREQUENCY_STEPS[frequency]
    dates = []
    for i in range(num_instalments):
        if unit == "days":
            dates.append(start_date + timedelta(days=step * i))
        else:
            dates.append(add_months(start_date, step * i, day_of_month))
    return dates


def build_amounts(amount_mode, total_amount, num_instalments, fixed_amount=None,
                   percentage=None, custom_amounts=None):
    """Return a list of Decimal-friendly floats, one per instalment, and any
    remaining balance not covered by the schedule."""
    if amount_mode == "custom":
        amounts = list(custom_amounts or [])
    elif amount_mode == "percentage":
        each = round(total_amount * (percentage / 100.0), 2)
        amounts = [each] * num_instalments
    else:  # fixed
        amt = fixed_amount if fixed_amount is not None else round(total_amount / num_instalments, 2)
        amounts = [amt] * num_instalments
        # push rounding remainder onto the final instalment so totals reconcile
        scheduled = round(amt * num_instalments, 2)
        remainder = round(total_amount - scheduled, 2)
        if amounts and remainder != 0 and fixed_amount is None:
            amounts[-1] = round(amounts[-1] + remainder, 2)

    remaining_balance = round(total_amount - sum(amounts), 2)
    return amounts, remaining_balance


def label_for(index, count):
    if count == 1:
        return "One-off payment"
    if index == 0:
        return "Deposit"
    if index == count - 1:
        return "Final payment"
    return None
LEDGERLY_FILE_EOF

mkdir -p "static/js"
cat > 'static/js/currency-select.js' << 'LEDGERLY_FILE_EOF'
// Searchable currency dropdown. Works on any element with class
// "currency-select" containing a text input (.cs-input), a hidden input
// (.cs-hidden) that carries the ISO code for form submission, and a
// results container (.cs-results).
(function () {
  function initCurrencySelect(root) {
    const input = root.querySelector(".cs-input");
    const hidden = root.querySelector(".cs-hidden");
    const results = root.querySelector(".cs-results");
    const display = root.querySelector(".cs-display");

    function renderResults(items) {
      results.innerHTML = "";
      if (!items.length) {
        results.innerHTML = '<div class="px-3 py-2 text-xs text-muted">No matching currency</div>';
      }
      items.forEach((c) => {
        const row = document.createElement("button");
        row.type = "button";
        row.className = "w-full text-left px-3 py-2 text-sm hover:bg-ink-raised flex items-center gap-2.5 transition";
        row.innerHTML = `<span>${c.flag}</span><span class="num text-gold w-12">${c.code}</span><span class="text-parchment flex-1">${c.name}</span><span class="num text-muted">${c.symbol}</span>`;
        row.addEventListener("click", () => {
          hidden.value = c.code;
          input.value = `${c.code} — ${c.name}`;
          if (display) display.textContent = `${c.flag} ${c.code} — ${c.name} (${c.symbol})`;
          results.classList.add("hidden");
          root.dispatchEvent(new CustomEvent("currency-change", { detail: c }));
        });
        results.appendChild(row);
      });
      results.classList.remove("hidden");
    }

    async function search(q) {
      const res = await fetch(`/api/currencies?q=${encodeURIComponent(q)}`);
      const data = await res.json();
      renderResults(data);
    }

    input.addEventListener("focus", () => search(""));
    input.addEventListener("input", () => search(input.value));
    document.addEventListener("click", (e) => {
      if (!root.contains(e.target)) results.classList.add("hidden");
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".currency-select").forEach(initCurrencySelect);
  });
})();
LEDGERLY_FILE_EOF

mkdir -p "static/js"
cat > 'static/js/rich-editor.js' << 'LEDGERLY_FILE_EOF'
// Initializes a Quill rich text editor bound to a hidden input/textarea,
// used for the agreement/terms field. Works on any element with class
// "rich-editor" that has a data-target attribute pointing to the id of the
// hidden form field it should sync into on submit.
(function () {
  function initRichEditor(root) {
    const targetId = root.dataset.target;
    const target = document.getElementById(targetId);
    const editorEl = root.querySelector(".rich-editor-surface");
    const previewEl = document.querySelector(root.dataset.previewTarget || "");

    const quill = new Quill(editorEl, {
      theme: "snow",
      placeholder: root.dataset.placeholder || "Write the agreement here…",
      modules: {
        toolbar: [
          [{ header: [2, 3, false] }],
          ["bold", "italic", "underline"],
          [{ list: "ordered" }, { list: "bullet" }],
          ["blockquote", "link"],
          ["clean"],
        ],
      },
    });

    if (target && target.value) {
      quill.root.innerHTML = target.value;
    }

    function sync() {
      const html = quill.root.innerHTML;
      const isEmpty = quill.getText().trim().length === 0;
      if (target) target.value = isEmpty ? "" : html;
      if (previewEl) previewEl.innerHTML = isEmpty
        ? '<p class="text-muted italic">Nothing written yet — this section won\u2019t appear for the client.</p>'
        : html;
    }

    quill.on("text-change", sync);
    sync();

    const form = root.closest("form");
    if (form) form.addEventListener("submit", sync);
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".rich-editor").forEach(initRichEditor);
  });
})();
LEDGERLY_FILE_EOF

mkdir -p "static/js"
cat > 'static/js/schedule-builder.js' << 'LEDGERLY_FILE_EOF'
(function () {
  const form = document.getElementById("schedule-form");
  if (!form) return;

  const previewUrl = form.dataset.previewUrl;
  const currencySymbol = form.dataset.currencySymbol;
  const contractTotal = parseFloat(form.dataset.contractTotal);
  const allowOutstanding = form.dataset.allowOutstanding === "true";

  const frequencySel = form.querySelector('[name="frequency"]');
  const amountModeSel = form.querySelector('[name="amount_mode"]');
  const monthlyFields = form.querySelector("#monthly-fields");
  const customDateFields = form.querySelector("#custom-date-fields");
  const numInstalmentsField = form.querySelector("#num-instalments-field");
  const fixedAmountField = form.querySelector("#fixed-amount-field");
  const percentageField = form.querySelector("#percentage-field");
  const customAmountsField = form.querySelector("#custom-amounts-field");

  function updateFrequencyFields() {
    const freq = frequencySel.value;
    customDateFields.classList.toggle("hidden", freq !== "custom");
    numInstalmentsField.classList.toggle("hidden", freq === "custom" || freq === "one_time");
    monthlyFields.classList.toggle("hidden", !["monthly", "bimonthly"].includes(freq));
  }

  function updateAmountFields() {
    const mode = amountModeSel.value;
    fixedAmountField.classList.toggle("hidden", mode !== "fixed");
    percentageField.classList.toggle("hidden", mode !== "percentage");
    customAmountsField.classList.toggle("hidden", mode !== "custom");
  }

  frequencySel.addEventListener("change", updateFrequencyFields);
  amountModeSel.addEventListener("change", updateAmountFields);
  updateFrequencyFields();
  updateAmountFields();

  const previewSection = document.getElementById("preview-section");
  const previewBody = document.getElementById("preview-body");
  const confirmBtn = document.getElementById("confirm-btn");
  const sumScheduled = document.getElementById("sum-scheduled");
  const sumRemaining = document.getElementById("sum-remaining");
  const sumFirst = document.getElementById("sum-first");
  const sumFinal = document.getElementById("sum-final");
  const balanceWarning = document.getElementById("balance-warning");

  function fmt(n) {
    return currencySymbol + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function recalcTotals() {
    let total = 0;
    previewBody.querySelectorAll("tr").forEach((row) => {
      const amt = parseFloat(row.querySelector(".row-amount").value) || 0;
      total += amt;
    });
    total = Math.round(total * 100) / 100;
    const remaining = Math.round((contractTotal - total) * 100) / 100;
    sumScheduled.textContent = fmt(total);
    sumRemaining.textContent = fmt(remaining);

    if (Math.abs(remaining) > 0.009 && !allowOutstanding) {
      balanceWarning.classList.remove("hidden");
      balanceWarning.textContent = remaining > 0
        ? `Schedule is ${fmt(remaining)} short of the contract total.`
        : `Schedule exceeds the contract total by ${fmt(Math.abs(remaining))}.`;
      confirmBtn.disabled = true;
      confirmBtn.classList.add("opacity-40", "cursor-not-allowed");
    } else {
      balanceWarning.classList.add("hidden");
      confirmBtn.disabled = false;
      confirmBtn.classList.remove("opacity-40", "cursor-not-allowed");
    }
  }

  function renderPreview(data) {
    previewBody.innerHTML = "";
    data.rows.forEach((row, i) => {
      const tr = document.createElement("tr");
      tr.className = "border-t border-ink-line";
      tr.innerHTML = `
        <td class="py-2 pr-3 text-muted num">${row.sequence}</td>
        <td class="py-2 pr-3"><input type="date" class="row-date bg-ink-raised border border-ink-line rounded px-2 py-1 text-sm num" value="${row.date}"></td>
        <td class="py-2 pr-3"><input type="text" class="row-label bg-ink-raised border border-ink-line rounded px-2 py-1 text-sm w-32" value="${row.label || ''}" placeholder="Instalment"></td>
        <td class="py-2 pr-3 text-right"><input type="number" step="0.01" class="row-amount bg-ink-raised border border-ink-line rounded px-2 py-1 text-sm num text-right w-28" value="${row.amount}"></td>
        <td class="py-2"><span class="stamp text-gold">Upcoming</span></td>
      `;
      previewBody.appendChild(tr);
    });
    previewBody.querySelectorAll(".row-amount").forEach((el) => el.addEventListener("input", recalcTotals));

    sumFirst.textContent = data.first_payment_date || "—";
    sumFinal.textContent = data.final_payment_date || "—";
    previewSection.classList.remove("hidden");
    recalcTotals();
    previewSection.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  document.getElementById("preview-btn").addEventListener("click", async () => {
    const fd = new FormData(form);
    const res = await fetch(previewUrl, { method: "POST", body: fd });
    const data = await res.json();
    if (data.error) {
      alert(data.error);
      return;
    }
    renderPreview(data);
  });

  form.addEventListener("submit", (e) => {
    if (previewSection.classList.contains("hidden")) {
      e.preventDefault();
      alert("Generate a preview first.");
      return;
    }
    const rows = [];
    previewBody.querySelectorAll("tr").forEach((row, i) => {
      rows.push({
        sequence: i + 1,
        date: row.querySelector(".row-date").value,
        amount: parseFloat(row.querySelector(".row-amount").value) || 0,
        label: row.querySelector(".row-label").value || null,
      });
    });
    const meta = {
      frequency: frequencySel.value,
      start_date: form.querySelector('[name="start_date"]').value,
      day_of_month: form.querySelector('[name="day_of_month"]').value || null,
      amount_mode: amountModeSel.value,
      auto_end: form.querySelector('[name="auto_end"]').checked,
    };
    form.querySelector('[name="rows_json"]').value = JSON.stringify(rows);
    form.querySelector('[name="meta_json"]').value = JSON.stringify(meta);
  });
})();
LEDGERLY_FILE_EOF

mkdir -p "templates"
cat > 'templates/base.html' << 'LEDGERLY_FILE_EOF'
<!doctype html>
<html lang="en" class="scroll-smooth">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{% block title %}Ledgerly{% endblock %}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,500;9..144,600&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<script src="https://cdn.tailwindcss.com?plugins=typography"></script>
<script>
  tailwind.config = {
    theme: {
      extend: {
        colors: {
          ink: { DEFAULT: '#0E1210', surface: '#161B18', raised: '#1E2420', line: '#2B322C' },
          gold: { DEFAULT: '#B08D3E', soft: '#8F7434', bright: '#D4B364' },
          parchment: '#F3EFE4',
          muted: '#95907F',
          sage: '#5C8367',
          brick: '#B9584C',
        },
        fontFamily: {
          display: ['Fraunces', 'serif'],
          sans: ['Inter', 'sans-serif'],
          mono: ['"JetBrains Mono"', 'monospace'],
        },
      }
    }
  }
</script>
<link href="https://cdn.jsdelivr.net/npm/quill@2.0.2/dist/quill.snow.css" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/quill@2.0.2/dist/quill.js"></script>
<style>
  body { background-color: #0E1210; background-image: radial-gradient(circle at 15% 0%, rgba(176,141,62,0.07), transparent 45%); }
  .stamp {
    display: inline-flex; align-items: center; gap: .35rem;
    border: 1.5px solid currentColor; border-radius: 3px;
    padding: .15rem .55rem; font-size: .68rem; letter-spacing: .12em;
    text-transform: uppercase; font-weight: 600; transform: rotate(-2deg);
    font-family: 'JetBrains Mono', monospace;
  }
  .stamp::before { content: ''; width: 5px; height: 5px; border-radius: 999px; background: currentColor; }
  .num { font-family: 'JetBrains Mono', monospace; font-variant-numeric: tabular-nums; }
  ::selection { background: #B08D3E; color: #0E1210; }

  /* Quill dark-theme overrides */
  .ql-toolbar.ql-snow { border-color: #2B322C; background: #1E2420; border-radius: 8px 8px 0 0; }
  .ql-container.ql-snow { border-color: #2B322C; border-radius: 0 0 8px 8px; background: #161B18; font-family: 'Inter', sans-serif; font-size: 14px; }
  .ql-snow .ql-stroke { stroke: #95907F; }
  .ql-snow .ql-fill { fill: #95907F; }
  .ql-snow .ql-picker { color: #95907F; }
  .ql-toolbar.ql-snow .ql-formats button:hover .ql-stroke,
  .ql-toolbar.ql-snow .ql-formats button.ql-active .ql-stroke { stroke: #B08D3E; }
  .ql-toolbar.ql-snow .ql-formats button:hover .ql-fill,
  .ql-toolbar.ql-snow .ql-formats button.ql-active .ql-fill { fill: #B08D3E; }
  .ql-toolbar.ql-snow .ql-formats button.ql-active,
  .ql-toolbar.ql-snow .ql-formats button:hover { color: #B08D3E; }
  .ql-snow .ql-picker-options { background: #1E2420; border-color: #2B322C !important; }
  .ql-editor { color: #F3EFE4; min-height: 260px; }
  .ql-editor.ql-blank::before { color: #6b6559; font-style: normal; }
  .ql-editor h2 { font-family: 'Fraunces', serif; font-size: 1.25rem; margin-top: .6em; }
  .ql-editor h3 { font-family: 'Fraunces', serif; font-size: 1.1rem; margin-top: .6em; }
  .ql-editor blockquote { border-left: 3px solid #B08D3E; color: #95907F; padding-left: .75rem; }
  .ql-editor a { color: #D4B364; }
</style>
</head>
<body class="min-h-screen text-parchment font-sans antialiased">

{% if current_user.is_authenticated %}
<header class="border-b border-ink-line">
  <div class="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
    <div class="flex items-center gap-8">
      <a href="{{ url_for('dashboard') }}" class="font-display text-xl tracking-tight text-parchment">
        Ledger<span class="text-gold">ly</span>
      </a>
      <nav class="hidden md:flex items-center gap-6 text-sm text-muted">
        <a href="{{ url_for('dashboard') }}" class="hover:text-parchment transition">Dashboard</a>
        <a href="{{ url_for('contracts_list') }}" class="hover:text-parchment transition">Contracts</a>
        <a href="{{ url_for('clients') }}" class="hover:text-parchment transition">Clients</a>
        <a href="{{ url_for('reminders') }}" class="hover:text-parchment transition">Reminders</a>
      </nav>
    </div>
    <div class="flex items-center gap-4">
      <a href="{{ url_for('contract_new') }}" class="text-sm bg-gold text-ink font-semibold px-3.5 py-1.5 rounded-md hover:bg-gold-bright transition">+ New contract</a>
      <span class="text-xs text-muted hidden sm:inline">{{ current_user.company.name }}</span>
      <a href="{{ url_for('logout') }}" class="text-xs text-muted hover:text-brick transition">Sign out</a>
    </div>
  </div>
</header>
{% endif %}

<main class="max-w-6xl mx-auto px-6 py-10">
  {% with messages = get_flashed_messages(with_categories=true) %}
    {% if messages %}
      <div class="mb-6 space-y-2">
      {% for category, message in messages %}
        <div class="text-sm px-4 py-2.5 rounded-md border {{ 'border-brick/50 bg-brick/10 text-brick' if category=='error' else 'border-sage/50 bg-sage/10 text-sage' }}">
          {{ message }}
        </div>
      {% endfor %}
      </div>
    {% endif %}
  {% endwith %}

  {% block content %}{% endblock %}
</main>

</body>
</html>
LEDGERLY_FILE_EOF

mkdir -p "templates"
cat > 'templates/clients.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Clients · Ledgerly{% endblock %}
{% block content %}
<p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">People</p>
<h1 class="font-display text-3xl mb-8">Clients</h1>

<div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
  <div class="lg:col-span-2 space-y-3">
    {% if not clients %}
    <div class="border border-dashed border-ink-line rounded-lg p-10 text-center text-muted">No clients yet — add your first one.</div>
    {% endif %}
    {% for c in clients %}
    <div class="bg-ink-surface border border-ink-line rounded-lg p-4 flex items-center justify-between">
      <div>
        <p class="font-medium">{{ c.name }}</p>
        {% if c.email %}<p class="text-xs text-muted">{{ c.email }}</p>{% endif %}
      </div>
    </div>
    {% endfor %}
  </div>

  <div>
    <form method="post" class="bg-ink-surface border border-ink-line rounded-lg p-5 space-y-4">
      <p class="font-display text-lg mb-1">Add a client</p>
      <div>
        <label class="block text-xs text-muted mb-1.5">Name</label>
        <input name="name" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
      </div>
      <div>
        <label class="block text-xs text-muted mb-1.5">Email (optional)</label>
        <input type="email" name="email" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
      </div>
      <button class="w-full bg-gold text-ink font-semibold rounded-md py-2 text-sm hover:bg-gold-bright transition">Add client</button>
    </form>
  </div>
</div>
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/agreement.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Agreement & sharing · {{ contract.title }}{% endblock %}
{% block content %}
<p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">{{ contract.title }}</p>
<h1 class="font-display text-3xl mb-8">Agreement & sharing</h1>

<form method="post" class="grid grid-cols-1 lg:grid-cols-3 gap-8 items-start">
  <div class="lg:col-span-2 space-y-6">

    <div class="bg-ink-surface border border-ink-line rounded-lg p-6">
      <div class="flex items-baseline justify-between mb-1">
        <p class="font-display text-lg">Agreement / terms</p>
        <span class="text-xs text-muted">shown above the signature block</span>
      </div>
      <p class="text-xs text-muted mb-4">Write the contract terms here — headings, bold/italic, and lists are all supported. This appears on the client's share page and in the downloaded PDF.</p>
      <div class="rich-editor" data-target="agreement_text_hidden" data-preview-target="#agreement-preview" data-placeholder="Write the contract terms here…">
        <div class="rich-editor-surface"></div>
      </div>
      <textarea id="agreement_text_hidden" name="agreement_text" class="hidden">{{ contract.agreement_text or '' }}</textarea>
    </div>

    <div class="bg-ink-surface border border-ink-line rounded-lg p-6">
      <p class="font-display text-lg mb-4">Sharing settings</p>
      <div class="space-y-3">
        <label class="flex items-center gap-2 text-sm text-muted">
          <input type="checkbox" name="client_can_build_schedule" {{ 'checked' if contract.client_can_build_schedule }} class="rounded border-ink-line bg-ink-raised">
          Let the client set up the schedule themselves via the share link
        </label>

        <label class="flex items-center gap-2 text-sm text-muted">
          <input type="checkbox" name="require_pin" id="require_pin" {{ 'checked' if contract.pin_code }} class="rounded border-ink-line bg-ink-raised">
          Protect the share link with a PIN
        </label>

        {% if contract.pin_code %}
        <div class="ml-6 flex items-center gap-3 text-sm">
          <span class="text-muted">Current PIN:</span>
          <span class="num text-gold text-lg tracking-widest">{{ contract.pin_code }}</span>
          <label class="flex items-center gap-1.5 text-xs text-muted">
            <input type="checkbox" name="regenerate_pin" class="rounded border-ink-line bg-ink-raised">
            Generate a new PIN
          </label>
        </div>
        {% else %}
        <p class="ml-6 text-xs text-muted">A 4-digit PIN will be generated automatically when you save with this checked.</p>
        {% endif %}
      </div>
    </div>

    <button class="bg-gold text-ink font-semibold rounded-md px-5 py-2.5 text-sm hover:bg-gold-bright transition">Save settings</button>
    <a href="{{ url_for('contract_view', contract_id=contract.id) }}" class="text-xs text-muted hover:text-gold ml-3 inline-block">← Back to contract</a>
  </div>

  <!-- Live preview: what the client will actually see -->
  <div class="lg:sticky lg:top-6">
    <div class="bg-ink-raised border border-ink-line rounded-lg p-5">
      <p class="text-gold text-xs tracking-[0.2em] uppercase mb-4">Client will see</p>
      <div id="agreement-preview" class="prose prose-invert prose-sm max-w-none prose-headings:font-display prose-a:text-gold pb-4 mb-4 border-b border-ink-line">
        {% if contract.agreement_text %}{{ contract.agreement_text|agreement_html|safe }}{% else %}
        <p class="text-muted italic">Nothing written yet — this section won't appear for the client.</p>
        {% endif %}
      </div>
      <p class="text-xs text-muted mb-2">Signature block</p>
      <div class="border border-dashed border-ink-line rounded-md p-3 text-xs text-muted">
        Name, typed signature, and an "I agree" checkbox appear here automatically on the share page.
      </div>
    </div>
  </div>
</form>

<script src="{{ url_for('static', filename='js/rich-editor.js') }}"></script>
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/audit.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Audit trail · {{ contract.title }}{% endblock %}
{% block content %}
<p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">{{ contract.title }}</p>
<h1 class="font-display text-3xl mb-8">Audit trail</h1>

{% if not entries %}
<div class="border border-dashed border-ink-line rounded-lg p-10 text-center text-muted">No changes recorded yet.</div>
{% else %}
<div class="space-y-4">
  {% for e in entries %}
  <div class="bg-ink-surface border border-ink-line rounded-lg p-5">
    <div class="flex items-center justify-between mb-2">
      <p class="font-medium capitalize">{{ e.action.replace('_', ' ') }}</p>
      <span class="stamp {{ 'text-sage' if e.approval_status=='approved' else ('text-brick' if e.approval_status=='rejected' else 'text-gold') }}">{{ e.approval_status }}</span>
    </div>
    <p class="text-xs text-muted mb-3">{{ e.created_at.strftime('%-d %B %Y, %H:%M') }}</p>
    {% set change = e.change_dict() %}
    {% if change and change.summary %}
    <p class="text-sm mb-2">{{ change.summary }}</p>
    {% endif %}
    <div class="grid grid-cols-2 gap-4 text-xs text-muted mt-3">
      <p>Requested by: <span class="text-parchment">{{ e.requested_by or '—' }}</span></p>
      <p>Approved by: <span class="text-parchment">{{ e.approved_by or '—' }}</span></p>
    </div>

    {% if e.approval_status == 'pending' %}
    <div class="flex items-center gap-2 mt-4 pt-4 border-t border-ink-line">
      <form method="post" action="{{ url_for('audit_approve', contract_id=contract.id, audit_id=e.id) }}">
        <button class="text-xs bg-gold text-ink font-semibold px-3 py-1.5 rounded-md hover:bg-gold-bright transition">Approve & apply</button>
      </form>
      <form method="post" action="{{ url_for('audit_reject', contract_id=contract.id, audit_id=e.id) }}">
        <button class="text-xs border border-ink-line px-3 py-1.5 rounded-md hover:border-brick hover:text-brick transition">Reject</button>
      </form>
    </div>
    {% endif %}
  </div>
  {% endfor %}
</div>
{% endif %}
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/list.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Contracts · Ledgerly{% endblock %}
{% block content %}
<div class="flex items-end justify-between mb-8">
  <div>
    <p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">All contracts</p>
    <h1 class="font-display text-3xl">Contracts</h1>
  </div>
  <a href="{{ url_for('contract_new') }}" class="text-sm bg-gold text-ink font-semibold px-3.5 py-1.5 rounded-md hover:bg-gold-bright transition">+ New contract</a>
</div>

{% if not contracts %}
<div class="border border-dashed border-ink-line rounded-lg p-10 text-center text-muted">No contracts yet.</div>
{% else %}
<div class="bg-ink-surface border border-ink-line rounded-lg divide-y divide-ink-line">
  {% for c in contracts %}
  <a href="{{ url_for('contract_view', contract_id=c.id) }}" class="flex items-center justify-between px-5 py-4 hover:bg-ink-raised transition">
    <div>
      <p class="font-medium">{{ c.title }}</p>
      <p class="text-xs text-muted mt-0.5">{{ c.client.name }}</p>
    </div>
    <div class="flex items-center gap-6 text-sm">
      <span class="num">{{ c.total_amount|money(c.currency_code) }}</span>
      <span class="stamp {{ 'text-sage' if c.status=='signed' else ('text-gold' if c.status=='sent' else 'text-muted') }}">{{ c.status }}</span>
    </div>
  </a>
  {% endfor %}
</div>
{% endif %}
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/new.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}New contract · Ledgerly{% endblock %}
{% block content %}
<p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">Step 1 of 2</p>
<h1 class="font-display text-3xl mb-8">New contract</h1>

<form method="post" id="new-contract-form" class="grid grid-cols-1 lg:grid-cols-3 gap-8 items-start">
  <div class="lg:col-span-2 space-y-6">

    <!-- Basics -->
    <div class="bg-ink-surface border border-ink-line rounded-lg p-6">
      <p class="font-display text-lg mb-5">Basics</p>
      <div class="space-y-5">
        <div>
          <label class="block text-xs text-muted mb-1.5">Contract title</label>
          <input id="f-title" name="title" required placeholder="Website Development" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
        </div>
        <div>
          <label class="block text-xs text-muted mb-1.5">Client</label>
          {% if clients %}
          <select id="f-client" name="client_id" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
            <option value="">Select a client…</option>
            {% for c in clients %}
            <option value="{{ c.id }}">{{ c.name }}</option>
            {% endfor %}
          </select>
          {% else %}
          <p class="text-sm text-muted">No clients yet. <a href="{{ url_for('clients') }}" class="text-gold hover:underline">Add one first</a>.</p>
          {% endif %}
        </div>
      </div>
    </div>

    <!-- Amount & currency -->
    <div class="bg-ink-surface border border-ink-line rounded-lg p-6">
      <p class="font-display text-lg mb-5">Amount &amp; currency</p>
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="block text-xs text-muted mb-1.5">Contract total</label>
          <input id="f-total" type="number" step="0.01" min="0" name="total_amount" required placeholder="2400.00" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
        </div>
        <div>
          <label class="block text-xs text-muted mb-1.5">Currency</label>
          <div class="currency-select relative" data-name="currency_code">
            <input type="text" class="cs-input w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold" placeholder="🔍 Search currency..." value="GBP — British Pound" autocomplete="off">
            <input type="hidden" class="cs-hidden" name="currency_code" value="GBP">
            <div class="cs-results hidden absolute z-10 mt-1 w-full max-h-64 overflow-y-auto bg-ink-raised border border-ink-line rounded-md shadow-xl"></div>
          </div>
        </div>
      </div>
      <label class="flex items-center gap-2 text-sm text-muted mt-4">
        <input type="checkbox" name="allow_outstanding_balance" class="rounded border-ink-line bg-ink-raised">
        Allow an outstanding balance (schedule doesn't have to sum to the full total)
      </label>
    </div>

    <!-- Agreement -->
    <div class="bg-ink-surface border border-ink-line rounded-lg p-6">
      <div class="flex items-baseline justify-between mb-1">
        <p class="font-display text-lg">Agreement / terms</p>
        <span class="text-xs text-muted">optional — can be edited later</span>
      </div>
      <p class="text-xs text-muted mb-4">Shown to the client above the signature block on the share page and in the PDF.</p>
      <div class="rich-editor" data-target="agreement_text_hidden" data-preview-target="#agreement-preview" data-placeholder="e.g. This agreement is between [Company] and [Client] for the delivery of…">
        <div class="rich-editor-surface"></div>
      </div>
      <textarea id="agreement_text_hidden" name="agreement_text" class="hidden"></textarea>
    </div>

    <!-- Sharing -->
    <div class="bg-ink-surface border border-ink-line rounded-lg p-6">
      <p class="font-display text-lg mb-4">Client access</p>
      <div class="space-y-2.5">
        <label class="flex items-center gap-2 text-sm text-muted">
          <input type="checkbox" name="allows_schedule_changes" checked class="rounded border-ink-line bg-ink-raised">
          Client may request schedule changes later (requires your approval)
        </label>
        <label class="flex items-center gap-2 text-sm text-muted">
          <input type="checkbox" name="client_can_build_schedule" checked class="rounded border-ink-line bg-ink-raised">
          Let the client set up the initial schedule themselves via the share link
        </label>
        <label class="flex items-center gap-2 text-sm text-muted">
          <input type="checkbox" name="require_pin" class="rounded border-ink-line bg-ink-raised">
          Protect the share link with a PIN (auto-generated, shown after saving)
        </label>
      </div>
    </div>

    <button class="bg-gold text-ink font-semibold rounded-md px-5 py-2.5 text-sm hover:bg-gold-bright transition">Continue to payment schedule →</button>
  </div>

  <!-- Live summary sidebar -->
  <div class="lg:sticky lg:top-6 space-y-4">
    <div class="bg-ink-raised border border-ink-line rounded-lg p-5">
      <p class="text-gold text-xs tracking-[0.2em] uppercase mb-3">Preview</p>
      <p id="preview-title" class="font-display text-lg leading-snug">Untitled contract</p>
      <p id="preview-client" class="text-xs text-muted mt-1">No client selected</p>
      <div class="mt-4 pt-4 border-t border-ink-line">
        <p class="text-xs text-muted mb-1">Total value</p>
        <p id="preview-total" class="num text-2xl text-gold">£0.00</p>
      </div>
    </div>
    <div class="bg-ink-surface border border-ink-line rounded-lg p-5">
      <p class="text-gold text-xs tracking-[0.2em] uppercase mb-3">Agreement preview</p>
      <div id="agreement-preview" class="prose prose-invert prose-sm max-w-none prose-headings:font-display prose-a:text-gold">
        <p class="text-muted italic">Nothing written yet — this section won't appear for the client.</p>
      </div>
    </div>
  </div>
</form>

<script src="{{ url_for('static', filename='js/currency-select.js') }}"></script>
<script>
  const titleInput = document.getElementById('f-title');
  const clientSelect = document.getElementById('f-client');
  const totalInput = document.getElementById('f-total');
  const previewTitle = document.getElementById('preview-title');
  const previewClient = document.getElementById('preview-client');
  const previewTotal = document.getElementById('preview-total');
  let currencySymbol = '£';

  function refreshPreview() {
    previewTitle.textContent = titleInput.value.trim() || 'Untitled contract';
    if (clientSelect) {
      const opt = clientSelect.options[clientSelect.selectedIndex];
      previewClient.textContent = (opt && opt.value) ? opt.textContent : 'No client selected';
    }
    const amt = parseFloat(totalInput.value) || 0;
    previewTotal.textContent = currencySymbol + amt.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  titleInput.addEventListener('input', refreshPreview);
  if (clientSelect) clientSelect.addEventListener('change', refreshPreview);
  totalInput.addEventListener('input', refreshPreview);
  document.querySelector('.currency-select').addEventListener('currency-change', (e) => {
    currencySymbol = e.detail.symbol;
    refreshPreview();
  });
  refreshPreview();
</script>
<script src="{{ url_for('static', filename='js/rich-editor.js') }}"></script>
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/schedule_builder.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Payment schedule · {{ contract.title }}{% endblock %}
{% block content %}
{% set cur = contract.currency_code %}
<p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">Step 2 of 2</p>
<h1 class="font-display text-3xl mb-1">Build the payment schedule</h1>
<p class="text-muted text-sm mb-8">{{ contract.title }} &middot; {{ contract.total_amount|money(cur) }} total {{ '(outstanding balance allowed)' if contract.allow_outstanding_balance else '' }}</p>

<form id="schedule-form" method="post"
      data-preview-url="{{ url_for('schedule_preview', contract_id=contract.id) }}"
      data-currency-symbol="{{ contract.total_amount|money(cur)|first }}"
      data-contract-total="{{ contract.total_amount }}"
      data-allow-outstanding="{{ 'true' if contract.allow_outstanding_balance else 'false' }}"
      class="grid grid-cols-1 lg:grid-cols-5 gap-8">

  <div class="lg:col-span-2 bg-ink-surface border border-ink-line rounded-lg p-6 space-y-5 h-fit">
    <div>
      <label class="block text-xs text-muted mb-1.5">Payment frequency</label>
      <select name="frequency" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
        <option value="one_time">One-time</option>
        <option value="weekly">Weekly</option>
        <option value="biweekly">Every 2 weeks</option>
        <option value="monthly" selected>Monthly</option>
        <option value="bimonthly">Every 2 months</option>
        <option value="quarterly">Quarterly</option>
        <option value="custom">Custom dates</option>
      </select>
    </div>

    <div>
      <label class="block text-xs text-muted mb-1.5">Payment start date</label>
      <input type="date" name="start_date" required value="{{ (contract.created_at.date()).isoformat() }}" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
    </div>

    <div id="monthly-fields">
      <label class="block text-xs text-muted mb-1.5">Day of month</label>
      <input type="number" name="day_of_month" min="1" max="31" placeholder="e.g. 5" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
    </div>

    <div id="num-instalments-field">
      <label class="block text-xs text-muted mb-1.5">Number of instalments</label>
      <input type="number" name="num_instalments" min="1" value="6" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
    </div>

    <div id="custom-date-fields" class="hidden">
      <label class="block text-xs text-muted mb-1.5">Custom dates (comma separated, YYYY-MM-DD)</label>
      <textarea name="custom_dates" rows="2" placeholder="2026-09-05, 2026-10-20, 2026-12-01" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold"></textarea>
    </div>

    <label class="flex items-center gap-2 text-sm text-muted">
      <input type="checkbox" name="auto_end" checked class="rounded border-ink-line bg-ink-raised">
      Automatically end after the final instalment
    </label>

    <hr class="border-ink-line">

    <div>
      <label class="block text-xs text-muted mb-1.5">Payment amount</label>
      <select name="amount_mode" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
        <option value="fixed" selected>Fixed amount (split evenly)</option>
        <option value="percentage">Percentage of contract total</option>
        <option value="custom">Custom amount per instalment</option>
      </select>
    </div>

    <div id="fixed-amount-field">
      <label class="block text-xs text-muted mb-1.5">Fixed amount per instalment (optional — leave blank to split evenly)</label>
      <input type="number" step="0.01" name="fixed_amount" placeholder="Auto-split" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
    </div>

    <div id="percentage-field" class="hidden">
      <label class="block text-xs text-muted mb-1.5">Percentage per instalment</label>
      <input type="number" step="0.1" name="percentage" placeholder="e.g. 16.67" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
    </div>

    <div id="custom-amounts-field" class="hidden">
      <label class="block text-xs text-muted mb-1.5">Custom amounts (comma separated)</label>
      <textarea name="custom_amounts" rows="2" placeholder="800, 400, 400, 400, 400" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold"></textarea>
    </div>

    <button type="button" id="preview-btn" class="w-full border border-gold text-gold font-semibold rounded-md py-2 text-sm hover:bg-gold hover:text-ink transition">Generate preview</button>

    <input type="hidden" name="rows_json">
    <input type="hidden" name="meta_json">
  </div>

  <div class="lg:col-span-3">
    <div id="preview-section" class="hidden bg-ink-surface border border-ink-line rounded-lg p-6">
      <p class="font-display text-lg mb-4">Schedule preview</p>

      <div class="grid grid-cols-4 gap-4 mb-5 text-sm">
        <div><p class="text-xs text-muted">Total scheduled</p><p id="sum-scheduled" class="num">—</p></div>
        <div><p class="text-xs text-muted">Remaining balance</p><p id="sum-remaining" class="num">—</p></div>
        <div><p class="text-xs text-muted">First payment</p><p id="sum-first" class="num">—</p></div>
        <div><p class="text-xs text-muted">Final payment</p><p id="sum-final" class="num">—</p></div>
      </div>

      <div id="balance-warning" class="hidden text-xs text-brick bg-brick/10 border border-brick/40 rounded-md px-3 py-2 mb-4"></div>

      <div class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-xs text-muted uppercase tracking-wide">
              <th class="pb-2 pr-3">#</th>
              <th class="pb-2 pr-3">Date</th>
              <th class="pb-2 pr-3">Description</th>
              <th class="pb-2 pr-3 text-right">Amount</th>
              <th class="pb-2">Status</th>
            </tr>
          </thead>
          <tbody id="preview-body"></tbody>
        </table>
      </div>

      <p class="text-xs text-muted mt-4">Edit any date, label, or amount above before confirming — totals update automatically.</p>

      <button id="confirm-btn" type="submit" class="mt-5 bg-gold text-ink font-semibold rounded-md px-5 py-2.5 text-sm hover:bg-gold-bright transition">Confirm schedule</button>
    </div>

    {% if not contract.schedule %}
    <div class="text-sm text-muted mt-4">Fill in the schedule options on the left, then click <span class="text-gold">Generate preview</span> to see and edit exact instalments before saving.</div>
    {% endif %}
  </div>
</form>

<script src="{{ url_for('static', filename='js/schedule-builder.js') }}"></script>
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/share.html' << 'LEDGERLY_FILE_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ contract.title }} · Payment schedule</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,600&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<script src="https://cdn.tailwindcss.com?plugins=typography"></script>
<script>
  tailwind.config = { theme: { extend: {
    colors: { ink: { DEFAULT: '#0E1210', surface: '#161B18', raised: '#1E2420', line: '#2B322C' },
      gold: { DEFAULT: '#B08D3E', soft: '#8F7434', bright: '#D4B364' },
      parchment: '#F3EFE4', muted: '#95907F', sage: '#5C8367', brick: '#B9584C' },
    fontFamily: { display: ['Fraunces', 'serif'], sans: ['Inter', 'sans-serif'], mono: ['"JetBrains Mono"', 'monospace'] }
  } } }
</script>
<style>
  body { background-color: #0E1210; background-image: radial-gradient(circle at 15% 0%, rgba(176,141,62,0.07), transparent 45%); }
  .stamp { display: inline-flex; align-items: center; gap: .35rem; border: 1.5px solid currentColor; border-radius: 3px; padding: .15rem .55rem; font-size: .68rem; letter-spacing: .12em; text-transform: uppercase; font-weight: 600; transform: rotate(-2deg); font-family: 'JetBrains Mono', monospace; }
  .stamp::before { content: ''; width: 5px; height: 5px; border-radius: 999px; background: currentColor; }
  .num { font-family: 'JetBrains Mono', monospace; font-variant-numeric: tabular-nums; }
</style>
</head>
<body class="min-h-screen text-parchment font-sans antialiased">
{% set cur = contract.currency_code %}
<main class="max-w-3xl mx-auto px-6 py-14">
  <div class="font-display text-xl mb-10">Ledger<span class="text-gold">ly</span></div>

  <p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">Payment schedule for</p>
  <h1 class="font-display text-3xl mb-2">{{ contract.title }}</h1>
  <p class="text-muted text-sm mb-8">Prepared for {{ contract.client.name }}</p>

  <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-10">
    <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
      <p class="text-xs text-muted mb-1">Total</p>
      <p class="num">{{ contract.total_amount|money(cur) }}</p>
    </div>
    <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
      <p class="text-xs text-muted mb-1">Paid</p>
      <p class="num text-sage">{{ contract.amount_paid|money(cur) }}</p>
    </div>
    <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
      <p class="text-xs text-muted mb-1">Remaining</p>
      <p class="num">{{ contract.amount_remaining|money(cur) }}</p>
    </div>
    <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
      <p class="text-xs text-muted mb-1">Currency</p>
      <p class="num">{{ cur }}</p>
    </div>
  </div>

  {% if contract.schedule %}
  <div class="bg-ink-surface border border-ink-line rounded-lg overflow-hidden mb-4">
    <table class="w-full text-sm">
      <thead>
        <tr class="text-left text-xs text-muted uppercase tracking-wide border-b border-ink-line">
          <th class="px-4 py-3">#</th>
          <th class="px-4 py-3">Date</th>
          <th class="px-4 py-3">Description</th>
          <th class="px-4 py-3 text-right">Amount</th>
          <th class="px-4 py-3">Status</th>
        </tr>
      </thead>
      <tbody>
      {% for p in contract.schedule.payments %}
        <tr class="border-b border-ink-line last:border-0">
          <td class="px-4 py-3 text-muted num">{{ p.sequence }}</td>
          <td class="px-4 py-3 num">{{ p.due_date.strftime('%-d %b %Y') }}</td>
          <td class="px-4 py-3 text-muted">{{ p.label or 'Instalment' }}</td>
          <td class="px-4 py-3 text-right num">{{ p.amount|money(cur) }}</td>
          <td class="px-4 py-3"><span class="stamp {{ 'text-sage' if p.status=='paid' else ('text-brick' if p.status=='overdue' else 'text-gold') }}">{{ p.status }}</span></td>
        </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
  {% if contract.allows_schedule_changes and contract.client_can_build_schedule %}
  <a href="{{ url_for('public_schedule_builder', token=token) }}" class="text-xs text-gold hover:underline mb-8 inline-block">Request a change to this schedule →</a>
  {% endif %}
  {% elif contract.client_can_build_schedule %}
  <div class="border border-dashed border-ink-line rounded-lg p-8 text-center mb-8">
    <p class="text-muted mb-3">No payment schedule has been set up yet — you can build your own.</p>
    <a href="{{ url_for('public_schedule_builder', token=token) }}" class="inline-block text-sm bg-gold text-ink font-semibold px-4 py-2 rounded-md hover:bg-gold-bright transition">Set up payment schedule</a>
  </div>
  {% else %}
  <div class="border border-dashed border-ink-line rounded-lg p-8 text-center text-muted mb-8">A payment schedule hasn't been published for this contract yet.</div>
  {% endif %}

  <div class="mb-8">
    <a href="{{ url_for('contract_share_pdf', token=contract.share_token) }}" class="inline-block text-sm border border-ink-line px-4 py-2 rounded-md hover:border-gold transition">Download PDF</a>
  </div>

  {% if contract.agreement_text %}
  <div class="border-t border-ink-line pt-10 mb-10">
    <p class="text-gold text-xs tracking-[0.2em] uppercase mb-4">Agreement</p>
    <div class="prose prose-invert max-w-none prose-headings:font-display prose-a:text-gold prose-blockquote:border-gold prose-blockquote:text-muted">
      {{ contract.agreement_text|agreement_html|safe }}
    </div>
  </div>
  {% endif %}

  <div class="border-t border-ink-line pt-10">
    <p class="text-gold text-xs tracking-[0.2em] uppercase mb-4">Signature</p>
    {% if contract.is_signed %}
    <div class="bg-ink-surface border border-sage/40 rounded-lg p-6">
      <p class="font-display text-2xl italic mb-2">{{ contract.signature_text }}</p>
      <p class="text-xs text-muted">Signed by {{ contract.signed_by_name }} on {{ contract.signed_at.strftime('%-d %B %Y') }}</p>
      <span class="stamp text-sage mt-3 inline-flex">Signed</span>
    </div>
    {% else %}
    <form method="post" action="{{ url_for('contract_sign', token=token) }}" class="bg-ink-surface border border-ink-line rounded-lg p-6 space-y-4">
      <div>
        <label class="block text-xs text-muted mb-1.5">Your full name</label>
        <input type="text" name="full_name" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
      </div>
      <div>
        <label class="block text-xs text-muted mb-1.5">Type your name to sign</label>
        <input type="text" name="signature_text" required placeholder="Your signature" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-lg font-display italic focus:outline-none focus:border-gold">
      </div>
      <label class="flex items-start gap-2 text-sm text-muted">
        <input type="checkbox" name="agree" required class="mt-0.5 rounded border-ink-line bg-ink-raised">
        I have read and agree to the terms above{% if not contract.agreement_text %} and the payment schedule shown{% endif %}.
      </label>
      <button class="bg-gold text-ink font-semibold rounded-md px-5 py-2.5 text-sm hover:bg-gold-bright transition">Sign agreement</button>
    </form>
    {% endif %}
  </div>
</main>
</body>
</html>
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/share_pin.html' << 'LEDGERLY_FILE_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Enter PIN · {{ contract.title }}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,600&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = { theme: { extend: {
    colors: { ink: { DEFAULT: '#0E1210', surface: '#161B18', raised: '#1E2420', line: '#2B322C' },
      gold: { DEFAULT: '#B08D3E', soft: '#8F7434', bright: '#D4B364' },
      parchment: '#F3EFE4', muted: '#95907F', sage: '#5C8367', brick: '#B9584C' },
    fontFamily: { display: ['Fraunces', 'serif'], sans: ['Inter', 'sans-serif'], mono: ['"JetBrains Mono"', 'monospace'] }
  } } }
</script>
<style>
  body { background-color: #0E1210; background-image: radial-gradient(circle at 15% 0%, rgba(176,141,62,0.07), transparent 45%); }
</style>
</head>
<body class="min-h-screen text-parchment font-sans antialiased flex items-center justify-center">
<div class="max-w-sm w-full px-6">
  <div class="font-display text-xl mb-6 text-center">Ledger<span class="text-gold">ly</span></div>

  {% with messages = get_flashed_messages(with_categories=true) %}
    {% if messages %}
      <div class="mb-4 space-y-2">
      {% for category, message in messages %}
        <div class="text-sm px-4 py-2.5 rounded-md border border-brick/50 bg-brick/10 text-brick text-center">{{ message }}</div>
      {% endfor %}
      </div>
    {% endif %}
  {% endwith %}

  <div class="bg-ink-surface border border-ink-line rounded-lg p-6 text-center">
    <p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">Protected document</p>
    <p class="font-display text-lg mb-4">{{ contract.title }}</p>
    <p class="text-sm text-muted mb-5">Enter the PIN you were given to view this contract.</p>
    <form method="post" action="{{ url_for('contract_share_verify_pin', token=token) }}">
      <input type="text" name="pin" maxlength="10" inputmode="numeric" autofocus placeholder="••••" class="w-full text-center num text-2xl tracking-[0.5em] bg-ink-raised border border-ink-line rounded-md px-3 py-3 mb-4 focus:outline-none focus:border-gold">
      <button class="w-full bg-gold text-ink font-semibold rounded-md py-2.5 text-sm hover:bg-gold-bright transition">Unlock</button>
    </form>
  </div>
</div>
</body>
</html>
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/share_schedule.html' << 'LEDGERLY_FILE_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Set up payment schedule · {{ contract.title }}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,600&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = { theme: { extend: {
    colors: { ink: { DEFAULT: '#0E1210', surface: '#161B18', raised: '#1E2420', line: '#2B322C' },
      gold: { DEFAULT: '#B08D3E', soft: '#8F7434', bright: '#D4B364' },
      parchment: '#F3EFE4', muted: '#95907F', sage: '#5C8367', brick: '#B9584C' },
    fontFamily: { display: ['Fraunces', 'serif'], sans: ['Inter', 'sans-serif'], mono: ['"JetBrains Mono"', 'monospace'] }
  } } }
</script>
<style>
  body { background-color: #0E1210; background-image: radial-gradient(circle at 15% 0%, rgba(176,141,62,0.07), transparent 45%); }
  .stamp { display: inline-flex; align-items: center; gap: .35rem; border: 1.5px solid currentColor; border-radius: 3px; padding: .15rem .55rem; font-size: .68rem; letter-spacing: .12em; text-transform: uppercase; font-weight: 600; transform: rotate(-2deg); font-family: 'JetBrains Mono', monospace; }
  .num { font-family: 'JetBrains Mono', monospace; font-variant-numeric: tabular-nums; }
</style>
</head>
<body class="min-h-screen text-parchment font-sans antialiased">
{% set cur = contract.currency_code %}
<main class="max-w-4xl mx-auto px-6 py-14">
  <div class="font-display text-xl mb-8">Ledger<span class="text-gold">ly</span></div>

  <p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">{{ 'Propose a change to' if contract.schedule else 'Set up' }}</p>
  <h1 class="font-display text-3xl mb-1">Payment schedule</h1>
  <p class="text-muted text-sm mb-8">{{ contract.title }} &middot; {{ contract.total_amount|money(cur) }} total{{ ' (outstanding balance allowed)' if contract.allow_outstanding_balance else '' }}</p>

  {% if contract.schedule %}
  <div class="text-xs text-gold bg-gold/10 border border-gold/30 rounded-md px-4 py-2.5 mb-8">
    A schedule already exists for this contract. Submitting below sends a change request to {{ contract.company.name }} for approval — it won't take effect immediately.
  </div>
  {% endif %}

  <form id="schedule-form" method="post"
        data-preview-url="{{ url_for('public_schedule_preview', token=token) }}"
        data-currency-symbol="{{ contract.total_amount|money(cur)|first }}"
        data-contract-total="{{ contract.total_amount }}"
        data-allow-outstanding="{{ 'true' if contract.allow_outstanding_balance else 'false' }}"
        class="grid grid-cols-1 lg:grid-cols-5 gap-8">

    <div class="lg:col-span-2 bg-ink-surface border border-ink-line rounded-lg p-6 space-y-5 h-fit">
      <div>
        <label class="block text-xs text-muted mb-1.5">Your name</label>
        <input type="text" name="requester_name" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
      </div>

      <hr class="border-ink-line">

      <div>
        <label class="block text-xs text-muted mb-1.5">Payment frequency</label>
        <select name="frequency" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
          <option value="one_time">One-time</option>
          <option value="weekly">Weekly</option>
          <option value="biweekly">Every 2 weeks</option>
          <option value="monthly" selected>Monthly</option>
          <option value="bimonthly">Every 2 months</option>
          <option value="quarterly">Quarterly</option>
          <option value="custom">Custom dates</option>
        </select>
      </div>

      <div>
        <label class="block text-xs text-muted mb-1.5">Payment start date</label>
        <input type="date" name="start_date" required value="{{ date.today().isoformat() }}" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
      </div>

      <div id="monthly-fields">
        <label class="block text-xs text-muted mb-1.5">Day of month</label>
        <input type="number" name="day_of_month" min="1" max="31" placeholder="e.g. 5" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
      </div>

      <div id="num-instalments-field">
        <label class="block text-xs text-muted mb-1.5">Number of instalments</label>
        <input type="number" name="num_instalments" min="1" value="6" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
      </div>

      <div id="custom-date-fields" class="hidden">
        <label class="block text-xs text-muted mb-1.5">Custom dates (comma separated, YYYY-MM-DD)</label>
        <textarea name="custom_dates" rows="2" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold"></textarea>
      </div>

      <label class="flex items-center gap-2 text-sm text-muted">
        <input type="checkbox" name="auto_end" checked class="rounded border-ink-line bg-ink-raised">
        Automatically end after the final instalment
      </label>

      <hr class="border-ink-line">

      <div>
        <label class="block text-xs text-muted mb-1.5">Payment amount</label>
        <select name="amount_mode" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
          <option value="fixed" selected>Fixed amount (split evenly)</option>
          <option value="percentage">Percentage of contract total</option>
          <option value="custom">Custom amount per instalment</option>
        </select>
      </div>

      <div id="fixed-amount-field">
        <label class="block text-xs text-muted mb-1.5">Fixed amount per instalment (optional)</label>
        <input type="number" step="0.01" name="fixed_amount" placeholder="Auto-split" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
      </div>

      <div id="percentage-field" class="hidden">
        <label class="block text-xs text-muted mb-1.5">Percentage per instalment</label>
        <input type="number" step="0.1" name="percentage" placeholder="e.g. 16.67" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
      </div>

      <div id="custom-amounts-field" class="hidden">
        <label class="block text-xs text-muted mb-1.5">Custom amounts (comma separated)</label>
        <textarea name="custom_amounts" rows="2" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold"></textarea>
      </div>

      <button type="button" id="preview-btn" class="w-full border border-gold text-gold font-semibold rounded-md py-2 text-sm hover:bg-gold hover:text-ink transition">Generate preview</button>

      <input type="hidden" name="rows_json">
      <input type="hidden" name="meta_json">
    </div>

    <div class="lg:col-span-3">
      <div id="preview-section" class="hidden bg-ink-surface border border-ink-line rounded-lg p-6">
        <p class="font-display text-lg mb-4">Schedule preview</p>

        <div class="grid grid-cols-4 gap-4 mb-5 text-sm">
          <div><p class="text-xs text-muted">Total scheduled</p><p id="sum-scheduled" class="num">—</p></div>
          <div><p class="text-xs text-muted">Remaining balance</p><p id="sum-remaining" class="num">—</p></div>
          <div><p class="text-xs text-muted">First payment</p><p id="sum-first" class="num">—</p></div>
          <div><p class="text-xs text-muted">Final payment</p><p id="sum-final" class="num">—</p></div>
        </div>

        <div id="balance-warning" class="hidden text-xs text-brick bg-brick/10 border border-brick/40 rounded-md px-3 py-2 mb-4"></div>

        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs text-muted uppercase tracking-wide">
                <th class="pb-2 pr-3">#</th>
                <th class="pb-2 pr-3">Date</th>
                <th class="pb-2 pr-3">Description</th>
                <th class="pb-2 pr-3 text-right">Amount</th>
                <th class="pb-2">Status</th>
              </tr>
            </thead>
            <tbody id="preview-body"></tbody>
          </table>
        </div>

        <p class="text-xs text-muted mt-4">Edit any date, label, or amount above before confirming — totals update automatically.</p>

        <button id="confirm-btn" type="submit" class="mt-5 bg-gold text-ink font-semibold rounded-md px-5 py-2.5 text-sm hover:bg-gold-bright transition">
          {{ 'Submit change request' if contract.schedule else 'Confirm schedule' }}
        </button>
      </div>

      {% if not contract.schedule %}
      <div class="text-sm text-muted mt-4">Fill in the options on the left, then click <span class="text-gold">Generate preview</span> to see and edit exact instalments before confirming.</div>
      {% endif %}
    </div>
  </form>

  <a href="{{ url_for('contract_share', token=token) }}" class="text-xs text-muted hover:text-gold mt-8 inline-block">← Back to contract</a>
</main>
<script src="{{ url_for('static', filename='js/schedule-builder.js') }}"></script>
</body>
</html>
LEDGERLY_FILE_EOF

mkdir -p "templates/contracts"
cat > 'templates/contracts/view.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}{{ contract.title }} · Ledgerly{% endblock %}
{% block content %}
{% set cur = contract.currency_code %}

<div class="flex flex-wrap items-start justify-between gap-4 mb-8">
  <div>
    <p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">{{ contract.client.name }}</p>
    <h1 class="font-display text-3xl">{{ contract.title }}</h1>
    <div class="flex items-center gap-2 mt-2">
      <span class="stamp {{ 'text-sage' if contract.status=='signed' else ('text-gold' if contract.status=='sent' else 'text-muted') }}">{{ contract.status }}</span>
      {% if contract.currency_locked %}
      <span class="text-xs text-muted">🔒 Currency locked to {{ cur }}</span>
      {% endif %}
      {% if contract.pin_code %}
      <span class="text-xs text-muted">🔑 PIN protected</span>
      {% endif %}
    </div>
    {% if contract.is_signed %}
    <p class="text-xs text-sage mt-1">Signed by {{ contract.signed_by_name }} on {{ contract.signed_at.strftime('%-d %B %Y') }}</p>
    {% endif %}
  </div>
  <div class="flex items-center gap-2">
    <a href="{{ url_for('contract_pdf', contract_id=contract.id) }}" class="text-sm border border-ink-line px-3.5 py-1.5 rounded-md hover:border-gold transition">Download PDF</a>
    <a href="{{ url_for('contract_agreement', contract_id=contract.id) }}" class="text-sm border border-ink-line px-3.5 py-1.5 rounded-md hover:border-gold transition">Agreement & sharing</a>
    {% if contract.schedule %}
    <a href="{{ url_for('schedule_builder', contract_id=contract.id) }}" class="text-sm border border-ink-line px-3.5 py-1.5 rounded-md hover:border-gold transition">Edit schedule</a>
    {% endif %}
    {% if contract.status == 'draft' %}
    <form method="post" action="{{ url_for('contract_send', contract_id=contract.id) }}">
      <button class="text-sm bg-gold text-ink font-semibold px-3.5 py-1.5 rounded-md hover:bg-gold-bright transition">Send for signing</button>
    </form>
    {% endif %}
  </div>
</div>

<div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
  <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
    <p class="text-xs text-muted mb-1">Total value</p>
    <p class="num text-lg">{{ contract.total_amount|money(cur) }}</p>
  </div>
  <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
    <p class="text-xs text-muted mb-1">Paid</p>
    <p class="num text-lg text-sage">{{ contract.amount_paid|money(cur) }}</p>
  </div>
  <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
    <p class="text-xs text-muted mb-1">Remaining</p>
    <p class="num text-lg">{{ contract.amount_remaining|money(cur) }}</p>
  </div>
  <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
    <p class="text-xs text-muted mb-1">Overdue</p>
    <p class="num text-lg {{ 'text-brick' if contract.overdue_amount > 0 else '' }}">{{ contract.overdue_amount|money(cur) }}</p>
  </div>
</div>

{% if contract.next_payment %}
<div class="bg-ink-surface border border-ink-line rounded-lg p-4 mb-8 flex items-center justify-between">
  <div>
    <p class="text-xs text-muted mb-1">Next payment</p>
    <p class="num">{{ contract.next_payment.amount|money(cur) }} due {{ contract.next_payment.due_date.strftime('%-d %B %Y') }}</p>
  </div>
  <p class="text-xs text-muted">{{ contract.remaining_instalments }} instalment(s) remaining</p>
</div>
{% endif %}

<div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
  <div class="lg:col-span-2">
    <p class="font-display text-lg mb-3">Instalments</p>
    {% if not contract.schedule %}
    <div class="border border-dashed border-ink-line rounded-lg p-8 text-center text-muted">
      No payment schedule yet. <a href="{{ url_for('schedule_builder', contract_id=contract.id) }}" class="text-gold hover:underline">Build one</a>.
    </div>
    {% else %}
    <div class="bg-ink-surface border border-ink-line rounded-lg overflow-hidden">
      <table class="w-full text-sm">
        <thead>
          <tr class="text-left text-xs text-muted uppercase tracking-wide border-b border-ink-line">
            <th class="px-4 py-3">#</th>
            <th class="px-4 py-3">Date</th>
            <th class="px-4 py-3">Description</th>
            <th class="px-4 py-3 text-right">Amount</th>
            <th class="px-4 py-3">Status</th>
            <th class="px-4 py-3"></th>
          </tr>
        </thead>
        <tbody>
        {% for p in contract.schedule.payments %}
          <tr class="border-b border-ink-line last:border-0">
            <td class="px-4 py-3 text-muted num">{{ p.sequence }}</td>
            <td class="px-4 py-3 num">{{ p.due_date.strftime('%-d %b %Y') }}</td>
            <td class="px-4 py-3 text-muted">{{ p.label or 'Instalment' }}</td>
            <td class="px-4 py-3 text-right num">{{ p.amount|money(cur) }}</td>
            <td class="px-4 py-3">
              <span class="stamp {{ 'text-sage' if p.status=='paid' else ('text-brick' if p.status=='overdue' else 'text-gold') }}">{{ p.status }}</span>
            </td>
            <td class="px-4 py-3 text-right">
              {% if p.status != 'paid' %}
              <form method="post" action="{{ url_for('mark_paid', contract_id=contract.id, payment_id=p.id) }}">
                <button class="text-xs text-gold hover:underline">Mark paid</button>
              </form>
              {% endif %}
            </td>
          </tr>
        {% endfor %}
        </tbody>
      </table>
    </div>
    {% endif %}
    <a href="{{ url_for('contract_audit', contract_id=contract.id) }}" class="text-xs text-muted hover:text-gold mt-3 inline-block">View audit trail →</a>
  </div>

  <div>
    <p class="font-display text-lg mb-3">Share with client</p>
    <div class="bg-ink-surface border border-ink-line rounded-lg p-4">
      <p class="text-xs text-muted mb-2">Anyone with this link can view the schedule and download the PDF — no login required.</p>
      <div class="flex items-center gap-2">
        <input readonly value="{{ share_url }}" id="share-url" class="flex-1 bg-ink-raised border border-ink-line rounded-md px-2.5 py-1.5 text-xs num truncate">
        <button onclick="navigator.clipboard.writeText(document.getElementById('share-url').value); this.textContent='Copied'" class="text-xs border border-ink-line px-2.5 py-1.5 rounded-md hover:border-gold transition shrink-0">Copy</button>
      </div>
      <a href="{{ share_url }}" target="_blank" class="text-xs text-gold hover:underline mt-2 inline-block">Open share page →</a>
      {% if contract.pin_code %}
      <div class="mt-3 pt-3 border-t border-ink-line flex items-center justify-between">
        <span class="text-xs text-muted">PIN to share with them</span>
        <span class="num text-gold tracking-widest">{{ contract.pin_code }}</span>
      </div>
      {% endif %}
    </div>
  </div>
</div>

{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates"
cat > 'templates/dashboard.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Dashboard · Ledgerly{% endblock %}
{% block content %}

<div class="flex items-end justify-between mb-8">
  <div>
    <p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">Overview</p>
    <h1 class="font-display text-3xl">Payment dashboard</h1>
  </div>
</div>

<div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-10">
  <div class="bg-ink-surface border border-ink-line rounded-lg p-5">
    <p class="text-xs text-muted uppercase tracking-wide mb-2">Across all contracts</p>
    <p class="num text-2xl">£{{ '{:,.2f}'.format(total_value) }}</p>
    <p class="text-xs text-muted mt-1">Total contract value</p>
  </div>
  <div class="bg-ink-surface border border-ink-line rounded-lg p-5">
    <p class="text-xs text-muted uppercase tracking-wide mb-2">Collected</p>
    <p class="num text-2xl text-sage">£{{ '{:,.2f}'.format(total_paid) }}</p>
    <p class="text-xs text-muted mt-1">Amount paid</p>
  </div>
  <div class="bg-ink-surface border border-ink-line rounded-lg p-5">
    <p class="text-xs text-muted uppercase tracking-wide mb-2">Needs attention</p>
    <p class="num text-2xl {{ 'text-brick' if total_overdue > 0 else '' }}">£{{ '{:,.2f}'.format(total_overdue) }}</p>
    <p class="text-xs text-muted mt-1">Overdue amount</p>
  </div>
</div>

<div class="flex items-center justify-between mb-4">
  <h2 class="font-display text-xl">Contracts</h2>
  <a href="{{ url_for('contract_new') }}" class="text-sm text-gold hover:underline">+ New contract</a>
</div>

{% if not contracts %}
<div class="border border-dashed border-ink-line rounded-lg p-10 text-center text-muted">
  No contracts yet. <a href="{{ url_for('contract_new') }}" class="text-gold hover:underline">Create your first contract</a> to build a payment schedule.
</div>
{% else %}
<div class="space-y-3">
  {% for c in contracts %}
  <a href="{{ url_for('contract_view', contract_id=c.id) }}" class="block bg-ink-surface border border-ink-line rounded-lg p-5 hover:border-gold/50 transition">
    <div class="flex flex-wrap items-center justify-between gap-4">
      <div>
        <p class="font-medium">{{ c.title }}</p>
        <p class="text-xs text-muted mt-0.5">{{ c.client.name }} &middot; {{ c.currency_code }}</p>
      </div>
      <div class="flex items-center gap-8 text-sm">
        <div>
          <p class="text-muted text-xs">Total</p>
          <p class="num">{{ c.total_amount|money(c.currency_code) }}</p>
        </div>
        <div>
          <p class="text-muted text-xs">Remaining</p>
          <p class="num">{{ c.amount_remaining|money(c.currency_code) }}</p>
        </div>
        <div>
          <p class="text-muted text-xs">Next due</p>
          {% if c.next_payment %}
          <p class="num">{{ c.next_payment.due_date.strftime('%-d %b') }}</p>
          {% else %}
          <p class="text-muted">—</p>
          {% endif %}
        </div>
        <div>
          {% if c.overdue_amount > 0 %}
          <span class="stamp text-brick">Overdue</span>
          {% elif c.status == 'signed' %}
          <span class="stamp text-sage">Paid up</span>
          {% elif c.status == 'sent' %}
          <span class="stamp text-gold">Sent</span>
          {% else %}
          <span class="stamp text-muted">Draft</span>
          {% endif %}
        </div>
      </div>
    </div>
  </a>
  {% endfor %}
</div>
{% endif %}

{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates"
cat > 'templates/login.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Sign in · Ledgerly{% endblock %}
{% block content %}
<div class="max-w-sm mx-auto mt-16">
  <div class="text-center mb-8">
    <div class="font-display text-3xl">Ledger<span class="text-gold">ly</span></div>
    <p class="text-muted text-sm mt-2">Contracts, instalments, and currencies — kept in order.</p>
  </div>
  <form method="post" class="bg-ink-surface border border-ink-line rounded-lg p-6 space-y-4">
    <div>
      <label class="block text-xs text-muted mb-1.5">Email</label>
      <input type="email" name="email" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
    </div>
    <div>
      <label class="block text-xs text-muted mb-1.5">Password</label>
      <input type="password" name="password" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
    </div>
    <button class="w-full bg-gold text-ink font-semibold rounded-md py-2 text-sm hover:bg-gold-bright transition">Sign in</button>
  </form>
  <p class="text-center text-sm text-muted mt-5">No account? <a href="{{ url_for('register') }}" class="text-gold hover:underline">Set up your company</a></p>
</div>
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates"
cat > 'templates/register.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Set up your company · Ledgerly{% endblock %}
{% block content %}
<div class="max-w-sm mx-auto mt-12">
  <div class="text-center mb-8">
    <div class="font-display text-3xl">Ledger<span class="text-gold">ly</span></div>
    <p class="text-muted text-sm mt-2">Set up your company workspace.</p>
  </div>
  <form method="post" class="bg-ink-surface border border-ink-line rounded-lg p-6 space-y-4">
    <div>
      <label class="block text-xs text-muted mb-1.5">Company name</label>
      <input type="text" name="company_name" required placeholder="Acme Studio Ltd" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
    </div>
    <div>
      <label class="block text-xs text-muted mb-1.5">Your name</label>
      <input type="text" name="name" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
    </div>
    <div>
      <label class="block text-xs text-muted mb-1.5">Email</label>
      <input type="email" name="email" required class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
    </div>
    <div>
      <label class="block text-xs text-muted mb-1.5">Password</label>
      <input type="password" name="password" required minlength="6" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm focus:outline-none focus:border-gold">
    </div>
    <button class="w-full bg-gold text-ink font-semibold rounded-md py-2 text-sm hover:bg-gold-bright transition">Create workspace</button>
  </form>
  <p class="text-center text-sm text-muted mt-5">Already set up? <a href="{{ url_for('login') }}" class="text-gold hover:underline">Sign in</a></p>
</div>
{% endblock %}
LEDGERLY_FILE_EOF

mkdir -p "templates"
cat > 'templates/reminders.html' << 'LEDGERLY_FILE_EOF'
{% extends "base.html" %}
{% block title %}Payment reminders · Ledgerly{% endblock %}
{% block content %}
<p class="text-gold text-xs tracking-[0.2em] uppercase mb-1">Automation</p>
<h1 class="font-display text-3xl mb-8">Payment reminders</h1>

<div class="max-w-lg">
<form method="post" class="bg-ink-surface border border-ink-line rounded-lg p-6 space-y-5">
  <div>
    <label class="block text-xs text-muted mb-1.5">Days before due date to send a reminder</label>
    <input type="number" min="0" name="days_before_due" value="{{ setting.days_before_due }}" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
  </div>

  <label class="flex items-center gap-2 text-sm text-muted">
    <input type="checkbox" name="remind_on_due_date" {{ 'checked' if setting.remind_on_due_date }} class="rounded border-ink-line bg-ink-raised">
    Send a reminder on the due date
  </label>

  <label class="flex items-center gap-2 text-sm text-muted">
    <input type="checkbox" name="remind_when_overdue" {{ 'checked' if setting.remind_when_overdue }} class="rounded border-ink-line bg-ink-raised">
    Notify when a payment becomes overdue
  </label>

  <div>
    <label class="block text-xs text-muted mb-1.5">Repeat overdue reminders every (days)</label>
    <input type="number" min="1" name="overdue_repeat_days" value="{{ setting.overdue_repeat_days }}" class="w-full bg-ink-raised border border-ink-line rounded-md px-3 py-2 text-sm num focus:outline-none focus:border-gold">
  </div>

  <button class="bg-gold text-ink font-semibold rounded-md px-5 py-2.5 text-sm hover:bg-gold-bright transition">Save reminder settings</button>
</form>
<p class="text-xs text-muted mt-4">These settings control when reminder notifications are queued. Wiring them to an email/SMS provider is a follow-up step.</p>
</div>
{% endblock %}
LEDGERLY_FILE_EOF

echo "All files written."

if [ -d .venv ]; then
  echo "Installing/updating Python dependencies in .venv..."
  ./.venv/bin/pip install -r requirements.txt --quiet
elif [ -d venv ]; then
  echo "Installing/updating Python dependencies in venv..."
  ./venv/bin/pip install -r requirements.txt --quiet
else
  echo "No .venv or venv directory found here — install dependencies manually:"
  echo "  pip install -r requirements.txt"
fi

echo ""
echo "Done. Restart the app (e.g. python app.py, or your process manager) to pick up the changes."
echo "Your ledgerly.db was not touched — the app migrates its own schema automatically on startup."
