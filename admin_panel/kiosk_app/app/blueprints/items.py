import csv
import io

from flask import Blueprint, render_template, redirect, url_for, request, flash, abort, Response, send_file
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Item, Barcode, StockAudit, IssuanceEvent, gen_item_barcode, ActivityEvent
from app.permissions import require_sidebar_item, ADMIN_ROLES
from app.barcode_render import code128_data_uri, qr_data_uri
from app.categorization import guess_category

bp = Blueprint("items", __name__, url_prefix="/items")
bp.before_request(require_sidebar_item("items"))

LOW_STOCK_THRESHOLD = 5  # flat constant, matches technical doc ("no per-item reorder point field exists yet")


def _register_barcode(code: str, entity_type: str, entity_id: int):
    db.session.add(Barcode(code=code, entity_type=entity_type, entity_id=entity_id))


def _category_suggestions():
    return sorted({c for (c,) in db.session.query(Item.category).filter(Item.category.isnot(None)).distinct()})


def _location_suggestions():
    return sorted({v for (v,) in db.session.query(Item.location).filter(Item.location.isnot(None)).distinct()})


def _supplier_suggestions():
    return sorted({v for (v,) in db.session.query(Item.supplier).filter(Item.supplier.isnot(None)).distinct()})


def _audit_freeze_active() -> bool:
    """True if stock movement should be blocked right now: an audit is
    open AND the current user isn't an admin-capable role. Admins/
    super_admins — the roles actually running the audit — can still
    override for a genuine business need mid-count; everyone else is
    frozen out so a moving target can't produce false discrepancies
    while the shelves are being counted (the actual point of the Part 1
    RolePermission note about disabling logins "during a stock audit" —
    this freezes movement specifically rather than the blunter
    everyone's-logged-out approach, and is enforced automatically rather
    than relying on an admin remembering to flip the kill-switch)."""
    if current_user.role in ADMIN_ROLES:
        return False
    return StockAudit.query.filter_by(status="open").first() is not None


@bp.route("/")
@login_required
def list_items():
    q = request.args.get("q", "").strip()
    query = Item.query.filter_by(deleted_at=None)
    if q:
        like = f"%{q}%"
        query = query.filter(db.or_(Item.name.ilike(like), Item.sku.ilike(like)))
    items = query.order_by(Item.name).all()
    low_stock_count = Item.query.filter(Item.deleted_at.is_(None), Item.quantity < LOW_STOCK_THRESHOLD).count()

    groups = {}
    for it in items:
        label = (it.category or "").strip() or "Uncategorized"
        groups.setdefault(label, []).append(it)
    items_by_category = sorted(groups.items(), key=lambda kv: (kv[0] == "Uncategorized", kv[0].lower()))
    uncategorized_count = len(groups.get("Uncategorized", []))

    return render_template(
        "items/list.html", items=items, q=q, low_stock_count=low_stock_count,
        items_by_category=items_by_category, uncategorized_count=uncategorized_count,
    )


@bp.route("/auto-categorize", methods=["POST"])
@login_required
def auto_categorize():
    """Best-effort bulk categorization for items with no category set —
    never touches an item that already has one, and skips (leaving
    uncategorized) any name the keyword list in app/categorization.py
    doesn't recognize, rather than force a low-confidence guess."""
    if current_user.role not in ADMIN_ROLES:
        abort(403)

    uncategorized = Item.query.filter(Item.deleted_at.is_(None), Item.category.is_(None)).all()
    categorized_count = 0
    for item in uncategorized:
        guess = guess_category(item.name)
        if guess:
            item.category = guess
            categorized_count += 1

    if categorized_count:
        db.session.add(ActivityEvent(
            event_type="items_auto_categorized", entity_name=f"{categorized_count} item(s)",
            actor=current_user.username, local_user_id=current_user.id,
            detail=f"Auto-categorized {categorized_count} of {len(uncategorized)} previously uncategorized items",
        ))
        db.session.commit()
        left = len(uncategorized) - categorized_count
        msg = f"Categorized {categorized_count} item(s)."
        if left:
            msg += f" {left} left uncategorized — no keyword match found for those names."
        flash(msg, "success")
    else:
        flash("No matches found — nothing was categorized.", "info")

    return redirect(url_for("items.list_items"))


@bp.route("/low-stock")
@login_required
def low_stock():
    items = Item.query.filter(
        Item.deleted_at.is_(None), Item.quantity < LOW_STOCK_THRESHOLD
    ).order_by(Item.quantity).all()
    return render_template("items/low_stock.html", items=items, threshold=LOW_STOCK_THRESHOLD)


@bp.route("/add", methods=["GET", "POST"])
@login_required
def add_item():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Name is required.", "danger")
            return render_template("items/add.html", category_suggestions=_category_suggestions(),
                                    location_suggestions=_location_suggestions(),
                                    supplier_suggestions=_supplier_suggestions())

        barcode_code = request.form.get("barcode_code", "").strip() or gen_item_barcode()
        if Barcode.query.get(barcode_code) is not None:
            flash(f"Barcode '{barcode_code}' is already in use.", "danger")
            return render_template("items/add.html", category_suggestions=_category_suggestions(),
                                    location_suggestions=_location_suggestions(),
                                    supplier_suggestions=_supplier_suggestions())

        try:
            quantity = int(request.form.get("quantity", "0") or 0)
        except ValueError:
            quantity = 0

        item = Item(
            name=name,
            sku=request.form.get("sku", "").strip() or None,
            description=request.form.get("description", "").strip() or None,
            quantity=max(0, quantity),
            unit=request.form.get("unit", "").strip() or None,
            barcode_code=barcode_code,
            category=request.form.get("category") or None,
            unit_cost=float(request.form.get("unit_cost")) if request.form.get("unit_cost") else None,
            location=request.form.get("location", "").strip() or None,
            supplier=request.form.get("supplier", "").strip() or None,
        )
        db.session.add(item)
        db.session.flush()
        _register_barcode(barcode_code, "item", item.id)
        db.session.commit()

        flash(f"Item '{item.name}' added.", "success")
        return redirect(url_for("items.list_items"))

    return render_template("items/add.html", category_suggestions=_category_suggestions(),
                            location_suggestions=_location_suggestions(),
                            supplier_suggestions=_supplier_suggestions())


@bp.route("/<int:item_id>/edit", methods=["GET", "POST"])
@login_required
def edit_item(item_id):
    item = Item.query.get_or_404(item_id)
    if request.method == "POST":
        item.name = request.form.get("name", item.name).strip()
        item.sku = request.form.get("sku", item.sku or "").strip() or None
        item.description = request.form.get("description", item.description or "").strip() or None
        item.unit = request.form.get("unit", item.unit or "").strip() or None
        item.category = request.form.get("category") or None
        item.unit_cost = float(request.form.get("unit_cost")) if request.form.get("unit_cost") else None
        item.supplier = request.form.get("supplier", item.supplier or "").strip() or None
        db.session.commit()
        flash("Item updated.", "success")
        return redirect(url_for("items.list_items"))
    return render_template("items/edit.html", item=item, category_suggestions=_category_suggestions(),
                            supplier_suggestions=_supplier_suggestions())


@bp.route("/<int:item_id>/delete", methods=["POST"])
@login_required
def delete_item(item_id):
    item = Item.query.get_or_404(item_id)
    if _audit_freeze_active():
        flash("An active stock audit is in progress — items can't be deleted until it's closed.", "danger")
        return redirect(url_for("items.list_items"))
    open_audit = StockAudit.query.filter_by(status="open").first()
    if open_audit is not None and any(l.item_id == item.id for l in open_audit.lines):
        # Even an admin (who otherwise bypasses the freeze above) can't
        # delete an item that's already been counted in the open audit —
        # doing so would orphan that count with no item left to
        # reconcile or dismiss it against.
        flash("This item was already counted in the open stock audit — resolve that count before deleting it.", "danger")
        return redirect(url_for("items.list_items"))
    from datetime import datetime
    Barcode.query.filter_by(code=item.barcode_code).delete()
    # Soft-delete (tombstone), not db.session.delete — see Item.deleted_at:
    # a hard delete here would never reach the Admin Panel's own mirror of
    # this item (see app/blueprints/sync_api.py / the Instance Agent's
    # inventory sync), which would just re-create it right back on its
    # next sync pass. Also sidesteps orphaning any IssuanceEvent rows that
    # reference this item.
    item.deleted_at = datetime.utcnow()
    db.session.commit()
    flash("Item deleted.", "info")
    return redirect(url_for("items.list_items"))


@bp.route("/<int:item_id>/adjust", methods=["POST"])
@login_required
def adjust_item(item_id):
    item = Item.query.get_or_404(item_id)
    if _audit_freeze_active():
        flash("Stock movement is frozen while a stock audit is open. Count this item from the audit instead.", "danger")
        if request.headers.get("X-Requested-With") == "XMLHttpRequest":
            from flask import jsonify
            return jsonify({"ok": False, "error": "audit_frozen"}), 409
        return redirect(url_for("items.list_items"))

    try:
        delta = int(request.form.get("delta", "0"))
    except ValueError:
        delta = 0
    project = request.form.get("project", "").strip() or None

    actual_delta = item.adjust_stock(
        delta, adjusted_by=current_user.username, project=project, local_user_id=current_user.id,
    )
    db.session.commit()

    if request.headers.get("X-Requested-With") == "XMLHttpRequest":
        from flask import jsonify
        return jsonify({"ok": True, "quantity": item.quantity, "actual_delta": actual_delta})

    # Scan workflow (Part 4) posts here with next=scan so the kiosk lands
    # back on the scan screen ready for the next item, instead of the full
    # items list.
    if request.form.get("next") == "scan":
        return redirect(url_for("scan.index"))
    return redirect(url_for("items.list_items"))


@bp.route("/<int:item_id>/transfer", methods=["POST"])
@login_required
def transfer_item(item_id):
    """Relocates an item (spec: 'Transfer stock') -- a first-class action
    alongside Add/Remove, kept separate from edit_item so every location
    change is always logged (see Item.transfer_to), the same reasoning
    that already keeps quantity changes out of the plain edit form."""
    item = Item.query.get_or_404(item_id)
    if _audit_freeze_active():
        flash("Stock movement is frozen while a stock audit is open.", "danger")
        return redirect(url_for("items.list_items"))

    new_location = request.form.get("location", "").strip()
    if not new_location:
        flash("A destination location is required to transfer this item.", "danger")
        if request.form.get("next") == "scan":
            return redirect(url_for("scan.index"))
        return redirect(url_for("items.view_item", item_id=item.id))

    item.transfer_to(new_location, transferred_by=current_user.username, local_user_id=current_user.id)
    db.session.commit()
    flash(f"'{item.name}' transferred to '{new_location}'.", "success")

    if request.form.get("next") == "scan":
        return redirect(url_for("scan.index"))
    return redirect(url_for("items.view_item", item_id=item.id))


@bp.route("/<int:item_id>")
@login_required
def view_item(item_id):
    item = Item.query.get_or_404(item_id)
    issuances = (
        IssuanceEvent.query.filter_by(item_id=item.id)
        .order_by(IssuanceEvent.created_at.desc())
        .all()
    )

    projects = {}
    users = {}
    for ev in issuances:
        proj_key = ev.project or "No project"
        projects[proj_key] = projects.get(proj_key, 0) + ev.quantity
        users[ev.employee] = users.get(ev.employee, 0) + ev.quantity

    projects_summary = sorted(projects.items(), key=lambda kv: -kv[1])
    users_summary = sorted(users.items(), key=lambda kv: -kv[1])

    # Matched by entity_name -- ActivityEvent has no item_id (see its own
    # comment), same limitation the dashboard's global feed already has.
    recent_activity = (
        ActivityEvent.query.filter_by(entity_name=item.name)
        .order_by(ActivityEvent.created_at.desc())
        .limit(15).all()
    )

    return render_template(
        "items/detail.html", item=item, issuances=issuances,
        projects_summary=projects_summary, users_summary=users_summary,
        recent_activity=recent_activity, location_suggestions=_location_suggestions(),
    )


@bp.route("/<int:item_id>/pdf")
@login_required
def export_item_pdf(item_id):
    # Imported lazily, not at module load time: reportlab is only needed
    # for this one button, and a kiosk machine where it failed to install
    # (offline, blocked pip, wheel mismatch) must not take the whole app
    # down at startup over it — real incident (2026-09-11): a module-level
    # import here crashed the entire kiosk process on 'pierre', which the
    # Admin Panel's health check then auto-rolled-back.
    try:
        from reportlab.lib import colors
        from reportlab.lib.pagesizes import letter
        from reportlab.lib.styles import getSampleStyleSheet
        from reportlab.lib.units import inch
        from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
    except ImportError:
        flash("PDF export isn't available on this machine right now (missing dependency). "
              "Contact support if this persists.", "danger")
        return redirect(url_for("items.view_item", item_id=item_id))

    item = Item.query.get_or_404(item_id)
    issuances = (
        IssuanceEvent.query.filter_by(item_id=item.id)
        .order_by(IssuanceEvent.created_at.desc())
        .all()
    )

    projects = {}
    users = {}
    for ev in issuances:
        proj_key = ev.project or "No project"
        projects[proj_key] = projects.get(proj_key, 0) + ev.quantity
        users[ev.employee] = users.get(ev.employee, 0) + ev.quantity
    projects_summary = sorted(projects.items(), key=lambda kv: -kv[1])
    users_summary = sorted(users.items(), key=lambda kv: -kv[1])

    buf = io.BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=letter,
        topMargin=0.6 * inch, bottomMargin=0.6 * inch,
        leftMargin=0.6 * inch, rightMargin=0.6 * inch,
    )
    styles = getSampleStyleSheet()
    table_style = TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#232b45")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f5f5f8")]),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ])

    story = [
        Paragraph(item.name, styles["Title"]),
        Paragraph(
            f"SKU: {item.sku or '—'} &nbsp;&nbsp; Barcode: {item.barcode_code} &nbsp;&nbsp; "
            f"Category: {item.category_display()}",
            styles["Normal"],
        ),
        Spacer(1, 14),
    ]

    if item.description:
        story.append(Paragraph("Description", styles["Heading2"]))
        story.append(Paragraph(item.description, styles["Normal"]))
        story.append(Spacer(1, 10))

    story.append(Paragraph("Stock", styles["Heading2"]))
    story.append(Table(
        [["Field", "Value"],
         ["Quantity in stock", f"{item.quantity} {item.unit or ''}".strip()],
         ["Unit cost", f"{item.unit_cost:.2f}" if item.unit_cost is not None else "—"],
         ["Normal re-issue interval (days)", item.normal_interval_days if item.normal_interval_days else "—"],
         ["Last adjusted by", item.last_adjusted_by or "—"],
         ["Last used on project", item.last_used_project or "—"],
         ["Updated at", item.updated_at.strftime("%Y-%m-%d %H:%M")],
         ["Created at", item.created_at.strftime("%Y-%m-%d %H:%M")]],
        colWidths=[220, 280], style=table_style,
    ))
    story.append(Spacer(1, 14))

    story.append(Paragraph("Booked out by project", styles["Heading2"]))
    if projects_summary:
        rows = [["Project", "Quantity"]] + [[p, f"{q} {item.unit or ''}".strip()] for p, q in projects_summary]
        story.append(Table(rows, colWidths=[300, 200], style=table_style))
    else:
        story.append(Paragraph("No issuances recorded yet.", styles["Normal"]))
    story.append(Spacer(1, 14))

    story.append(Paragraph("Booked out by user", styles["Heading2"]))
    if users_summary:
        rows = [["User", "Quantity"]] + [[u, f"{q} {item.unit or ''}".strip()] for u, q in users_summary]
        story.append(Table(rows, colWidths=[300, 200], style=table_style))
    else:
        story.append(Paragraph("No issuances recorded yet.", styles["Normal"]))
    story.append(Spacer(1, 14))

    story.append(Paragraph("Issuance history", styles["Heading2"]))
    if issuances:
        rows = [["Date", "User", "Project", "Qty"]] + [
            [ev.created_at.strftime("%Y-%m-%d %H:%M"), ev.employee, ev.project or "—", str(ev.quantity)]
            for ev in issuances
        ]
        story.append(Table(rows, colWidths=[120, 160, 160, 60], style=table_style))
    else:
        story.append(Paragraph("No issuances recorded yet.", styles["Normal"]))

    doc.build(story)
    buf.seek(0)

    safe_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in item.name)[:64] or "item"
    return send_file(
        buf, mimetype="application/pdf", as_attachment=True,
        download_name=f"{safe_name}_report.pdf",
    )


@bp.route("/<int:item_id>/barcode")
@login_required
def view_barcode(item_id):
    item = Item.query.get_or_404(item_id)
    return render_template(
        "items/barcode.html", item=item,
        barcode_image=code128_data_uri(item.barcode_code),
        qr_image=qr_data_uri(item.barcode_code),
    )


@bp.route("/export.csv")
@login_required
def export_csv():
    items = Item.query.filter_by(deleted_at=None).order_by(Item.name).all()
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["name", "sku", "description", "quantity", "unit", "barcode_code", "category", "unit_cost"])
    for i in items:
        writer.writerow([i.name, i.sku or "", i.description or "", i.quantity, i.unit or "",
                          i.barcode_code, i.category_display(), i.unit_cost or ""])
    return Response(buf.getvalue(), mimetype="text/csv",
                     headers={"Content-Disposition": "attachment; filename=items.csv"})


@bp.route("/import", methods=["GET", "POST"])
@login_required
def import_csv():
    if request.method == "POST":
        f = request.files.get("file")
        if f is None or f.filename == "":
            flash("Choose a CSV file.", "danger")
            return render_template("items/import.html")

        text = f.stream.read().decode("utf-8-sig")
        reader = csv.DictReader(io.StringIO(text))

        created, updated, errors = 0, 0, []
        for row_num, row in enumerate(reader, start=2):
            name = (row.get("name") or "").strip()
            if not name:
                errors.append(f"Row {row_num}: missing name, skipped.")
                continue

            sku = (row.get("sku") or "").strip() or None
            existing = None
            if sku:
                existing = Item.query.filter_by(sku=sku, deleted_at=None).first()
            if existing is None:
                existing = Item.query.filter_by(name=name, deleted_at=None).first()

            try:
                quantity = int(row.get("quantity") or 0)
            except ValueError:
                quantity = 0

            if existing:
                existing.quantity = max(0, quantity)
                existing.unit = (row.get("unit") or "").strip() or existing.unit
                existing.description = (row.get("description") or "").strip() or existing.description
                updated += 1
            else:
                barcode_code = (row.get("barcode_code") or "").strip() or gen_item_barcode()
                if Barcode.query.get(barcode_code) is not None:
                    barcode_code = gen_item_barcode()  # collision — auto-regenerate rather than fail the row
                item = Item(
                    name=name, sku=sku, description=(row.get("description") or "").strip() or None,
                    quantity=max(0, quantity), unit=(row.get("unit") or "").strip() or None,
                    barcode_code=barcode_code, category=(row.get("category") or "").strip() or None,
                )
                db.session.add(item)
                db.session.flush()
                _register_barcode(barcode_code, "item", item.id)
                created += 1

        db.session.commit()
        flash(f"Import complete — {created} created, {updated} updated.", "success")
        for e in errors:
            flash(e, "warning")
        return redirect(url_for("items.list_items"))

    return render_template("items/import.html")
