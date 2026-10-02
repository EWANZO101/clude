from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash
from flask_login import login_required, current_user

from app.extensions import db
from app.models import WireBatch, WireSpool, WireIssuanceEvent, Barcode, ActivityEvent, gen_wire_barcode
from app.permissions import require_sidebar_item
from app.barcode_render import code128_data_uri

bp = Blueprint("wire", __name__, url_prefix="/wire")
bp.before_request(require_sidebar_item("wire"))


def _register_barcode(code: str, entity_type: str, entity_id: int):
    db.session.add(Barcode(code=code, entity_type=entity_type, entity_id=entity_id))


def _parse_float(raw):
    raw = (raw or "").strip()
    return float(raw) if raw else None


@bp.route("/")
@login_required
def list_spools():
    status = request.args.get("status", "")
    query = WireSpool.query
    if status:
        query = query.filter_by(status=status)
    else:
        query = query.filter(WireSpool.status != "scrapped")  # scrapped hidden by default, still reachable via filter
    spools = query.order_by(WireSpool.wire_type, WireSpool.received_at.desc()).all()
    counts = {
        s: WireSpool.query.filter_by(status=s).count()
        for s in ("in_stock", "issued", "empty", "scrapped")
    }
    return render_template("wire/list.html", spools=spools, status=status, counts=counts)


@bp.route("/add", methods=["GET", "POST"])
@login_required
def add_spool():
    if request.method == "POST":
        wire_type = request.form.get("wire_type", "").strip()
        if not wire_type:
            flash("Wire type is required.", "danger")
            return render_template("wire/add.html")

        barcode_code = request.form.get("barcode_code", "").strip() or gen_wire_barcode()
        if Barcode.query.get(barcode_code) is not None:
            flash(f"Barcode '{barcode_code}' is already in use.", "danger")
            return render_template("wire/add.html")

        weight_lbs = _parse_float(request.form.get("weight_lbs"))
        spool = WireSpool(
            wire_type=wire_type,
            diameter=request.form.get("diameter", "").strip() or None,
            weight_lbs=weight_lbs,
            current_weight_lbs=weight_lbs,
            unit_cost=_parse_float(request.form.get("unit_cost")),
            barcode_code=barcode_code,
        )
        db.session.add(spool)
        db.session.flush()
        _register_barcode(barcode_code, "wire", spool.id)
        db.session.commit()

        flash(f"Spool of '{spool.wire_label()}' added.", "success")
        return redirect(url_for("wire.list_spools"))

    return render_template("wire/add.html")


@bp.route("/bulk-add", methods=["GET", "POST"])
@login_required
def bulk_add():
    if request.method == "POST":
        wire_type = request.form.get("wire_type", "").strip()
        try:
            quantity = int(request.form.get("quantity", "0"))
        except ValueError:
            quantity = 0

        if not wire_type:
            flash("Wire type is required.", "danger")
            return render_template("wire/bulk_add.html")
        if quantity < 1 or quantity > 500:
            flash("Quantity must be between 1 and 500.", "danger")
            return render_template("wire/bulk_add.html")

        batch = WireBatch(
            lot_number=request.form.get("lot_number", "").strip() or None,
            wire_type=wire_type,
            diameter=request.form.get("diameter", "").strip() or None,
            weight_lbs=_parse_float(request.form.get("weight_lbs")),
            unit_cost=_parse_float(request.form.get("unit_cost")),
            quantity=quantity,
            received_by=current_user.username,
        )
        db.session.add(batch)
        db.session.flush()

        for _ in range(quantity):
            barcode_code = gen_wire_barcode()
            # Practically unreachable (128-bit-ish hex code space), but
            # matches the collision-safety pattern every other barcoded
            # entity in this app follows rather than trusting randomness
            # blindly on a loop that runs up to 500 times per call.
            while Barcode.query.get(barcode_code) is not None:
                barcode_code = gen_wire_barcode()
            spool = WireSpool(
                batch_id=batch.id, wire_type=wire_type,
                diameter=batch.diameter, weight_lbs=batch.weight_lbs,
                current_weight_lbs=batch.weight_lbs, unit_cost=batch.unit_cost,
                barcode_code=barcode_code,
            )
            db.session.add(spool)
            db.session.flush()
            _register_barcode(barcode_code, "wire", spool.id)

        db.session.add(ActivityEvent(
            event_type="wire_bulk_add", entity_name=wire_type, actor=current_user.username,
            local_user_id=current_user.id,
            detail=f"Received batch {batch.label} — {quantity} spools" + (f" (lot {batch.lot_number})" if batch.lot_number else ""),
        ))
        db.session.commit()

        flash(f"Batch {batch.label} added — {quantity} spools of '{wire_type}'.", "success")
        return redirect(url_for("wire.list_spools"))

    return render_template("wire/bulk_add.html")


@bp.route("/batches")
@login_required
def list_batches():
    batches = WireBatch.query.order_by(WireBatch.received_at.desc()).all()
    return render_template("wire/batches.html", batches=batches)


@bp.route("/<int:spool_id>/edit", methods=["GET", "POST"])
@login_required
def edit_spool(spool_id):
    spool = WireSpool.query.get_or_404(spool_id)
    if request.method == "POST":
        spool.wire_type = request.form.get("wire_type", spool.wire_type).strip() or spool.wire_type
        spool.diameter = request.form.get("diameter", spool.diameter or "").strip() or None
        weight = request.form.get("weight_lbs", "")
        if weight:
            spool.weight_lbs = float(weight)
            # A spool that never had a weight (current_weight_lbs still
            # NULL) starts being weight-tracked from here -- but once
            # it's tracked, editing the nominal weight_lbs must not
            # silently overwrite however much has actually been used, so
            # this only ever fires once per spool.
            if spool.current_weight_lbs is None:
                spool.current_weight_lbs = spool.weight_lbs
        cost = request.form.get("unit_cost", "")
        spool.unit_cost = float(cost) if cost else spool.unit_cost
        db.session.commit()
        flash("Spool updated.", "success")
        return redirect(url_for("wire.list_spools"))
    return render_template("wire/edit.html", spool=spool)


@bp.route("/<int:spool_id>/delete", methods=["POST"])
@login_required
def delete_spool(spool_id):
    spool = WireSpool.query.get_or_404(spool_id)
    if spool.status == "issued":
        flash("An issued spool can't be deleted — return or empty it first.", "danger")
        return redirect(url_for("wire.list_spools"))
    if spool.issuance_events:
        # Found by testing: this used to cascade-delete the spool's
        # WireIssuanceEvent rows along with it, silently pulling real
        # consumption out of the reporting rollups. A spool that's ever
        # been issued keeps its history — scrap it to get it out of
        # active inventory instead of deleting it.
        flash("This spool has issuance history, so deleting it would corrupt reporting — scrap it instead.", "danger")
        return redirect(url_for("wire.list_spools"))
    Barcode.query.filter_by(code=spool.barcode_code).delete()
    db.session.delete(spool)
    db.session.commit()
    flash("Spool deleted.", "info")
    return redirect(url_for("wire.list_spools"))


@bp.route("/<int:spool_id>/issue", methods=["POST"])
@login_required
def issue_spool(spool_id):
    spool = WireSpool.query.get_or_404(spool_id)
    if spool.status != "in_stock":
        flash(f"That spool isn't available to issue (status: {spool.status}).", "danger")
        return redirect(_next_target())

    project = request.form.get("project", "").strip() or None
    issued_to = current_user.username  # who's at the kiosk, same convention as Tool checkout

    spool.status = "issued"
    spool.issued_to = issued_to
    spool.current_project = project
    db.session.add(WireIssuanceEvent(
        spool_id=spool.id, issued_to=issued_to, project=project,
        starting_weight_lbs=spool.current_weight_lbs,
    ))
    db.session.add(ActivityEvent(
        event_type="wire_issue", entity_name=spool.wire_label(), actor=issued_to,
        local_user_id=current_user.id,
        project=project, detail=f"Spool issued — for {project or 'no project specified'}",
    ))
    db.session.commit()
    flash(f"Spool of '{spool.wire_label()}' issued.", "success")
    return redirect(_next_target())


def _open_issuance(spool):
    return WireIssuanceEvent.query.filter_by(spool_id=spool.id, resolved_at=None).order_by(
        WireIssuanceEvent.issued_at.desc()
    ).first()


def _resolve_issuance(spool, outcome, finishing_weight_lbs=None):
    """finishing_weight_lbs is only ever server-computed for 'empty' (0 --
    fully consumed) or read from the Return pop-up; consumed_lbs is always
    derived here from the event's own starting_weight_lbs, never trusted
    from the caller, and stays None when the spool had no starting weight
    to begin with (nothing to compute)."""
    event = _open_issuance(spool)
    if event is not None:
        event.resolved_at = datetime.utcnow()
        event.outcome = outcome
        if finishing_weight_lbs is not None and event.starting_weight_lbs is not None:
            event.finishing_weight_lbs = finishing_weight_lbs
            event.consumed_lbs = round(event.starting_weight_lbs - finishing_weight_lbs, 4)
    return event


def _next_target():
    return url_for("scan.index") if request.form.get("next") == "scan" else url_for("wire.list_spools")


@bp.route("/<int:spool_id>/empty", methods=["POST"])
@login_required
def empty_spool(spool_id):
    spool = WireSpool.query.get_or_404(spool_id)
    if spool.status != "issued":
        flash("Only an issued spool can be marked empty.", "danger")
        return redirect(_next_target())

    issued_to = spool.issued_to
    _resolve_issuance(spool, "emptied", finishing_weight_lbs=0 if spool.current_weight_lbs is not None else None)
    if spool.current_weight_lbs is not None:
        spool.current_weight_lbs = 0
    spool.status = "empty"
    spool.issued_to = None
    spool.current_project = None
    db.session.add(ActivityEvent(
        event_type="wire_empty", entity_name=spool.wire_label(), actor=current_user.username,
        local_user_id=current_user.id,
        detail=f"Marked empty (was issued to {issued_to})" if issued_to else "Marked empty",
    ))
    db.session.commit()
    flash(f"Spool of '{spool.wire_label()}' marked empty.", "info")
    return redirect(_next_target())


@bp.route("/<int:spool_id>/return", methods=["POST"])
@login_required
def return_spool(spool_id):
    spool = WireSpool.query.get_or_404(spool_id)
    if spool.status != "issued":
        flash("Only an issued spool can be returned to stock.", "danger")
        return redirect(_next_target())

    # Only a spool with a tracked weight actually prompts for/needs a
    # finishing weight (see current_weight_lbs on the model) -- a spool
    # that was never given a weight_lbs just returns as before.
    finishing_weight_lbs = None
    if spool.current_weight_lbs is not None:
        raw = request.form.get("finishing_weight_lbs")
        finishing_weight_lbs = _parse_float(raw)
        if finishing_weight_lbs is None:
            flash("Finishing weight (lbs) is required to return this spool.", "danger")
            return redirect(_next_target())
        if finishing_weight_lbs < 0:
            flash("Finishing weight can't be negative.", "danger")
            return redirect(_next_target())
        open_event = _open_issuance(spool)
        starting = open_event.starting_weight_lbs if open_event else spool.current_weight_lbs
        if starting is not None and finishing_weight_lbs > starting:
            flash(f"Finishing weight ({finishing_weight_lbs} lbs) can't be more than the "
                  f"starting weight ({starting} lbs).", "danger")
            return redirect(_next_target())

    issued_to = spool.issued_to
    _resolve_issuance(spool, "returned", finishing_weight_lbs=finishing_weight_lbs)
    if finishing_weight_lbs is not None:
        spool.current_weight_lbs = finishing_weight_lbs
    spool.status = "in_stock"
    spool.issued_to = None
    spool.current_project = None
    weight_detail = f", {finishing_weight_lbs} lbs remaining" if finishing_weight_lbs is not None else ""
    db.session.add(ActivityEvent(
        event_type="wire_return", entity_name=spool.wire_label(), actor=current_user.username,
        local_user_id=current_user.id,
        detail=(f"Returned to stock, partially used (was issued to {issued_to}){weight_detail}"
                if issued_to else f"Returned to stock{weight_detail}"),
    ))
    db.session.commit()
    flash(f"Spool of '{spool.wire_label()}' returned to stock" +
          (f" — {finishing_weight_lbs} lbs remaining." if finishing_weight_lbs is not None else "."), "success")
    return redirect(_next_target())


@bp.route("/<int:spool_id>/scrap", methods=["POST"])
@login_required
def scrap_spool(spool_id):
    spool = WireSpool.query.get_or_404(spool_id)
    if spool.status == "scrapped":
        flash("That spool is already scrapped.", "warning")
        return redirect(_next_target())

    was_issued = spool.status == "issued"
    if was_issued:
        _resolve_issuance(spool, "scrapped")
    issued_to = spool.issued_to
    spool.status = "scrapped"
    spool.issued_to = None
    spool.current_project = None
    spool.scrap_reason = request.form.get("reason", "").strip() or None
    db.session.add(ActivityEvent(
        event_type="wire_scrap", entity_name=spool.wire_label(), actor=current_user.username,
        local_user_id=current_user.id,
        detail=f"Scrapped" + (f" — {spool.scrap_reason}" if spool.scrap_reason else "")
               + (f" (was issued to {issued_to})" if was_issued and issued_to else ""),
    ))
    db.session.commit()
    flash(f"Spool of '{spool.wire_label()}' scrapped.", "warning")
    return redirect(_next_target())


@bp.route("/<int:spool_id>/barcode")
@login_required
def view_barcode(spool_id):
    spool = WireSpool.query.get_or_404(spool_id)
    return render_template("wire/barcode.html", spool=spool, barcode_image=code128_data_uri(spool.barcode_code))


@bp.route("/reporting")
@login_required
def reporting():
    in_stock = WireSpool.query.filter_by(status="in_stock").all()
    stock_value = sum((s.unit_cost or 0) for s in in_stock)

    resolved_events = WireIssuanceEvent.query.filter(WireIssuanceEvent.resolved_at.isnot(None)).all()
    total_weight_lbs = round(sum(e.consumed_lbs or 0 for e in resolved_events), 4)

    by_project = {}
    by_welder = {}
    by_type = {}
    for e in resolved_events:
        key_p = e.project or "(no project)"
        by_project[key_p] = by_project.get(key_p, 0) + 1
        by_welder[e.issued_to] = by_welder.get(e.issued_to, 0) + 1
        wt = e.spool.wire_type if e.spool else "(unknown)"
        by_type[wt] = by_type.get(wt, 0) + 1

    outcome_counts = {"emptied": 0, "returned": 0, "scrapped": 0}
    for e in resolved_events:
        if e.outcome in outcome_counts:
            outcome_counts[e.outcome] += 1

    open_issuances = WireIssuanceEvent.query.filter_by(resolved_at=None).order_by(
        WireIssuanceEvent.issued_at.desc()
    ).all()

    return render_template(
        "wire/reporting.html",
        stock_count=len(in_stock), stock_value=stock_value, total_weight_lbs=total_weight_lbs,
        by_project=sorted(by_project.items(), key=lambda kv: -kv[1]),
        by_welder=sorted(by_welder.items(), key=lambda kv: -kv[1]),
        by_type=sorted(by_type.items(), key=lambda kv: -kv[1]),
        outcome_counts=outcome_counts,
        open_issuances=open_issuances,
    )
