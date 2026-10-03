"""
Welding wire check-out/check-in (spec items 1-16): every coil is its
own WireCoil (identified by the barcode on its tag), tracked with a
live status exactly like Tool is (available / checked_out / empty /
inactive) so a coil that's out can't be checked out again by someone
else (spec item 10). Every checkout/checkin cycle is its own
WireTransaction row -- checkout opens one, checkin closes it.
starting_weight is always read server-side from the coil's
current_weight at checkout time, and consumed is always computed
server-side at checkin -- a caller can only ever supply
finishing_weight (spec item 4), so the chain can't drift or be
tampered with from the client.

Wire type/code (spec items 7, 8) is a real admin-manageable table
(WireCode) rather than a hard-coded list -- see the /codes endpoints
below.
"""
import csv
import io
from datetime import datetime, timezone, timedelta
from flask import Blueprint, request, jsonify, Response, send_file
from app.models import db, WireCoil, WireCode, WireTransaction, WireProjectBudget, ActivityEvent
from app.auth import permission_required
from app.reporting import get_wire_project_variances
from app.routes_admin import _assign_barcode, _reassign_barcode

wire_bp = Blueprint("wire", __name__, url_prefix="/api/wire")


def _now():
    return datetime.now(timezone.utc)


def _aware(dt):
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


# ───────────────────────── Wire codes (spec items 7, 8) ────────────────
@wire_bp.route("/codes", methods=["GET"])
def list_wire_codes():
    """Active by default (what the kiosk dropdown should show); pass
    ?include_inactive=1 for the admin management screen."""
    query = WireCode.query
    if request.args.get("include_inactive") != "1":
        query = query.filter_by(is_active=True)
    codes = query.order_by(WireCode.name.asc()).all()
    return jsonify([c.to_dict() for c in codes]), 200


@wire_bp.route("/codes", methods=["POST"])
@permission_required("admin", "supervisor")
def create_wire_code():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name is required."}), 400
    if WireCode.query.filter_by(name=name).first():
        return jsonify({"error": f"Wire code '{name}' already exists."}), 409
    code = WireCode(name=name)
    db.session.add(code)
    db.session.commit()
    return jsonify(code.to_dict()), 201


@wire_bp.route("/codes/<int:code_id>", methods=["PATCH"])
@permission_required("admin", "supervisor")
def update_wire_code(code_id):
    """Rename and/or activate/deactivate a code. Deactivating (rather
    than deleting) is deliberate -- coils and historical transactions
    keep pointing at a valid WireCode row (spec item 16)."""
    code = db.session.get(WireCode, code_id)
    if not code:
        return jsonify({"error": "Wire code not found."}), 404
    data = request.get_json(silent=True) or {}
    if "name" in data:
        name = (data.get("name") or "").strip()
        if not name:
            return jsonify({"error": "name cannot be empty."}), 400
        clash = WireCode.query.filter(WireCode.name == name, WireCode.id != code.id).first()
        if clash:
            return jsonify({"error": f"Wire code '{name}' already exists."}), 409
        code.name = name
    if "is_active" in data:
        code.is_active = bool(data["is_active"])
    db.session.commit()
    return jsonify(code.to_dict()), 200


# ───────────────────────────── Coils (spec item 6) ──────────────────────
@wire_bp.route("/coils", methods=["GET"])
def list_coils():
    """Also opportunistically purges any Empty/Finished coil that's
    past its 30-day retention window, so the list is correct even if
    the hourly background sweep (wire_cleanup_scheduler.py) hasn't run
    yet -- cheap, and this endpoint is polled constantly by the kiosk
    wire tab anyway."""
    from app.wire_cleanup_scheduler import purge_expired_empty_coils
    purge_expired_empty_coils()

    status = request.args.get("status")
    query = WireCoil.query
    if status:
        query = query.filter_by(status=status)
    coils = query.order_by(WireCoil.created_at.desc()).all()
    return jsonify([c.to_dict() for c in coils]), 200


@wire_bp.route("/coils", methods=["POST"])
@permission_required("admin", "supervisor")
def create_coil():
    """Admin 'Add Welding Wire' (spec item 6). Sets the initial/current
    weight for a new spool and its barcode + wire code/type. Barcode
    assignment goes through the same Barcode table + _assign_barcode
    helper items/tools/projects use, so scanning a wire coil's barcode
    works identically through /api/barcode/lookup (spec item 2 step 3)."""
    data = request.get_json(silent=True) or {}

    try:
        weight = float(data.get("initial_weight"))
    except (TypeError, ValueError):
        return jsonify({"error": "initial_weight is required and must be a number."}), 400
    if weight <= 0:
        return jsonify({"error": "initial_weight must be > 0."}), 400

    wire_code_id = data.get("wire_code_id")
    wire_code = db.session.get(WireCode, wire_code_id) if wire_code_id else None
    if wire_code_id and not wire_code:
        return jsonify({"error": "wire_code_id does not match a known wire code."}), 400

    status = data.get("status") or WireCoil.STATUS_AVAILABLE
    if status not in (WireCoil.STATUS_AVAILABLE, WireCoil.STATUS_INACTIVE):
        status = WireCoil.STATUS_AVAILABLE

    coil = WireCoil(
        name=(data.get("name") or "").strip() or None,
        wire_code_id=wire_code.id if wire_code else None,
        status=status,
        initial_weight=weight, current_weight=weight,
    )
    db.session.add(coil)
    db.session.flush()  # populate coil.id for the Barcode row below

    requested_code = (data.get("barcode_code") or "").strip().upper() or None
    code, error = _assign_barcode("wire", coil.id, requested_code)
    if error:
        db.session.rollback()
        return jsonify({"error": error}), 409
    coil.barcode_code = code

    db.session.commit()
    return jsonify(coil.to_dict()), 201


@wire_bp.route("/coils/bulk", methods=["POST"])
@permission_required("admin", "supervisor")
def create_coils_bulk():
    """Bulk 'Add Welding Wire' -- adds N boxes/coils in one go.

    Body:
      count (int, required) -- how many boxes.
      name (optional) -- shared name/description applied to every box.
      wire_code_id (optional) -- shared wire code/type applied to every box.
      status (optional) -- shared initial status (available/inactive).

      Weight -- either:
        total_weight (number) -- split evenly across `count` boxes. Any
          rounding remainder is dropped onto the LAST box so the boxes
          still sum exactly to total_weight.
        per_box_weight (list of numbers, len == count) -- explicit
          weight for each box, used as-is -- this IS the "change per-box
          weight if needed" override.
      Exactly one of total_weight / per_box_weight must be given.

      per_box_barcode (optional list, len == count) -- explicit barcode
        for that box; blank/omitted entries auto-generate, same as the
        single-add form.

    Returns the created coils plus a total_weight echo so the client
    can confirm what got split (the last box may differ slightly from
    the others -- see remainder handling above).
    """
    data = request.get_json(silent=True) or {}

    try:
        count = int(data.get("count"))
    except (TypeError, ValueError):
        return jsonify({"error": "count is required and must be a whole number."}), 400
    if count < 1:
        return jsonify({"error": "count must be at least 1."}), 400
    if count > 200:
        return jsonify({"error": "count can't be more than 200 in one batch."}), 400

    wire_code_id = data.get("wire_code_id")
    wire_code = db.session.get(WireCode, wire_code_id) if wire_code_id else None
    if wire_code_id and not wire_code:
        return jsonify({"error": "wire_code_id does not match a known wire code."}), 400

    status = data.get("status") or WireCoil.STATUS_AVAILABLE
    if status not in (WireCoil.STATUS_AVAILABLE, WireCoil.STATUS_INACTIVE):
        status = WireCoil.STATUS_AVAILABLE

    name = (data.get("name") or "").strip() or None

    # ── Resolve per-box weights ──────────────────────────────────────
    per_box_weight = data.get("per_box_weight")
    total_weight = data.get("total_weight")
    weights = []
    if per_box_weight is not None:
        if not isinstance(per_box_weight, list) or len(per_box_weight) != count:
            return jsonify({"error": f"per_box_weight must be a list of exactly {count} numbers."}), 400
        for i, w in enumerate(per_box_weight):
            try:
                w = float(w)
            except (TypeError, ValueError):
                return jsonify({"error": f"per_box_weight[{i}] must be a number."}), 400
            if w <= 0:
                return jsonify({"error": f"per_box_weight[{i}] must be greater than 0."}), 400
            weights.append(w)
    elif total_weight is not None:
        try:
            total_weight = float(total_weight)
        except (TypeError, ValueError):
            return jsonify({"error": "total_weight must be a number."}), 400
        if total_weight <= 0:
            return jsonify({"error": "total_weight must be greater than 0."}), 400
        share = round(total_weight / count, 4)
        weights = [share] * count
        remainder = round(total_weight - (share * count), 4)
        weights[-1] = round(weights[-1] + remainder, 4)
    else:
        return jsonify({"error": "Either total_weight or per_box_weight is required."}), 400

    # ── Resolve per-box barcodes (optional overrides, else auto) ─────
    per_box_barcode = data.get("per_box_barcode")
    if per_box_barcode is not None and (not isinstance(per_box_barcode, list) or len(per_box_barcode) != count):
        return jsonify({"error": f"per_box_barcode must be a list of exactly {count} entries (blank = auto)."}), 400

    created = []
    for i in range(count):
        coil = WireCoil(
            name=name, wire_code_id=wire_code.id if wire_code else None,
            status=status, initial_weight=weights[i], current_weight=weights[i],
        )
        db.session.add(coil)
        db.session.flush()  # populate coil.id for the Barcode row below

        requested_code = None
        if per_box_barcode:
            requested_code = (per_box_barcode[i] or "").strip().upper() or None
        code, error = _assign_barcode("wire", coil.id, requested_code)
        if error:
            db.session.rollback()
            return jsonify({"error": f"Box {i + 1}: {error}"}), 409
        coil.barcode_code = code
        created.append(coil)

    ActivityEvent.log(
        "wire_bulk_add", name or "Welding wire batch",
        detail=f"{count} boxes added, {sum(weights):.2f}kg total",
    )
    db.session.commit()
    return jsonify({
        "coils": [c.to_dict() for c in created],
        "count": count,
        "total_weight": round(sum(weights), 4),
    }), 201


@wire_bp.route("/coils/barcodes-pdf", methods=["POST"])
@permission_required("admin", "supervisor")
def wire_coils_barcodes_pdf():
    """Printable PDF of individual barcodes for a set of boxes -- the
    "print individual barcodes?" popup after a bulk add. Body:
    {coil_ids: [1, 2, 3, ...]} -- the ids returned by /coils/bulk (or
    any coil ids, so a barcode sheet can be reprinted later too)."""
    from app.wire_barcode_sheet_pdf import build_wire_barcode_sheet_pdf

    data = request.get_json(silent=True) or {}
    coil_ids = data.get("coil_ids")
    if not isinstance(coil_ids, list) or not coil_ids:
        return jsonify({"error": "coil_ids is required and must be a non-empty list."}), 400
    if len(coil_ids) > 200:
        return jsonify({"error": "coil_ids can't be more than 200 at a time."}), 400

    coils = []
    for cid in coil_ids:
        coil = db.session.get(WireCoil, cid)
        if coil:
            coils.append(coil.to_dict())
    if not coils:
        return jsonify({"error": "None of the given coil_ids were found."}), 404

    pdf_bytes = build_wire_barcode_sheet_pdf(coils)
    return send_file(
        io.BytesIO(pdf_bytes), mimetype="application/pdf",
        as_attachment=True, download_name="welding_wire_barcodes.pdf",
    )


@wire_bp.route("/coils/<int:coil_id>", methods=["GET"])
def get_coil(coil_id):
    coil = db.session.get(WireCoil, coil_id)
    if not coil:
        return jsonify({"error": "Coil not found."}), 404
    return jsonify(coil.to_dict()), 200


@wire_bp.route("/coils/<int:coil_id>", methods=["PATCH"])
@permission_required("admin", "supervisor")
def update_coil(coil_id):
    """Admin edits (name/wire code/status/weight top-ups). Deliberately
    does NOT allow setting status to checked_out directly -- that only
    ever happens through the real checkout flow below, which needs a
    user. Marking a coil 'empty' by hand (spec item 9's 'admin marks it
    as finished') is allowed here even if current_weight > 0.

    add_weight (optional, > 0) restocks the box: current_weight AND
    initial_weight both increase by the same amount, so total_used
    (initial - current, i.e. lifetime consumption) stays accurate
    across a refill instead of shrinking. It's always applied on top
    of whatever current_weight already is right now -- never overwrites
    it -- so a coil sitting at 2.5kg remaining plus a 5kg add becomes
    7.5kg, not 5kg. Reviving an Empty/Finished coil this way clears its
    Empty/Finished grouping and 30-day delete clock (empty_at) and
    brings it back to 'available' automatically."""
    coil = db.session.get(WireCoil, coil_id)
    if not coil:
        return jsonify({"error": "Coil not found."}), 404
    data = request.get_json(silent=True) or {}
    if coil.status == WireCoil.STATUS_CHECKED_OUT and ("status" in data or "add_weight" in data):
        return jsonify({"error": "This coil is checked out -- check it in first."}), 409

    if "name" in data:
        coil.name = (data.get("name") or "").strip() or None
    if "barcode_code" in data:
        requested = (data.get("barcode_code") or "").strip().upper() or None
        new_code, error = _reassign_barcode("wire", coil.id, coil.barcode_code, requested)
        if error:
            return jsonify({"error": error}), 409
        coil.barcode_code = new_code
    if "wire_code_id" in data:
        wire_code_id = data.get("wire_code_id")
        wire_code = db.session.get(WireCode, wire_code_id) if wire_code_id else None
        if wire_code_id and not wire_code:
            return jsonify({"error": "wire_code_id does not match a known wire code."}), 400
        coil.wire_code_id = wire_code.id if wire_code else None

    if "add_weight" in data:
        try:
            add_weight = float(data.get("add_weight"))
        except (TypeError, ValueError):
            return jsonify({"error": "add_weight must be a number."}), 400
        if add_weight <= 0:
            return jsonify({"error": "add_weight must be greater than 0."}), 400
        if coil.status == WireCoil.STATUS_INACTIVE:
            return jsonify({"error": "This coil is inactive -- reactivate it before adding weight."}), 409
        # Always computed from the coil's CURRENT weight right now, never
        # a stale/client-supplied figure -- same server-side-only
        # principle checkin_coil() uses for finishing_weight.
        coil.current_weight = round(coil.current_weight + add_weight, 4)
        coil.initial_weight = round(coil.initial_weight + add_weight, 4)
        if coil.status == WireCoil.STATUS_EMPTY:
            coil.status = WireCoil.STATUS_AVAILABLE
            coil.empty_at = None

    if "status" in data:
        new_status = data["status"]
        if new_status not in (WireCoil.STATUS_AVAILABLE, WireCoil.STATUS_EMPTY, WireCoil.STATUS_INACTIVE):
            return jsonify({"error": "status must be one of: available, empty, inactive."}), 400
        coil.status = new_status
        coil.empty_at = _now() if new_status == WireCoil.STATUS_EMPTY else None

    db.session.commit()
    return jsonify(coil.to_dict()), 200


@wire_bp.route("/coils/<int:coil_id>", methods=["DELETE"])
@permission_required("admin")
def delete_coil(coil_id):
    """Manual delete for the Empty/Finished list's Delete button (spec:
    only offered once a coil is Empty/Finished -- the 30-day window is
    just how long it sticks around if nobody deletes it sooner). Also
    removes its Barcode registration so the code can be reused;
    WireTransaction history is left in place, same as the automatic
    30-day sweep in wire_cleanup_scheduler.py."""
    coil = db.session.get(WireCoil, coil_id)
    if not coil:
        return jsonify({"error": "Coil not found."}), 404
    if coil.status != WireCoil.STATUS_EMPTY:
        return jsonify({"error": "Only an Empty/Finished box can be deleted -- mark it finished first."}), 409

    from app.models import Barcode
    Barcode.query.filter_by(entity_type="wire", entity_id=coil.id).delete()
    db.session.delete(coil)
    db.session.commit()
    return jsonify({"deleted": True}), 200


# ───────────────────── Check-out / Check-in (spec items 2, 3, 9, 10) ───
@wire_bp.route("/coils/<int:coil_id>/checkout", methods=["POST"])
def checkout_coil(coil_id):
    """1. Scan user  2. Scan project  3. Scan wire -> this endpoint.
    Rejects if the coil is already checked out (spec item 10), empty,
    or inactive."""
    coil = db.session.get(WireCoil, coil_id)
    if not coil:
        return jsonify({"error": "Coil not found."}), 404

    if coil.status == WireCoil.STATUS_CHECKED_OUT:
        return jsonify({
            "error": (
                f"This welding wire is currently checked out to "
                f"{coil.checked_out_by_name or 'another user'}"
                + (f" on project '{coil.current_project}'" if coil.current_project else "")
                + "."
            ),
            "checked_out_by_name": coil.checked_out_by_name,
            "checked_out_by_badge": coil.checked_out_by_badge,
            "current_project": coil.current_project,
        }), 409
    if coil.status == WireCoil.STATUS_EMPTY:
        return jsonify({"error": "This welding wire spool is empty/finished."}), 409
    if coil.status == WireCoil.STATUS_INACTIVE:
        return jsonify({"error": "This welding wire spool is inactive."}), 409

    data = request.get_json(silent=True) or {}
    user_name = (data.get("user_name") or "").strip()
    if not user_name:
        return jsonify({"error": "user_name is required."}), 400
    user_badge = (data.get("user_badge") or "").strip() or None
    project = (data.get("project") or "").strip() or None

    coil.status = WireCoil.STATUS_CHECKED_OUT
    coil.checked_out_by_name = user_name
    coil.checked_out_by_badge = user_badge
    coil.current_project = project

    txn = WireTransaction(
        coil_id=coil.id, user_name=user_name, user_badge=user_badge, project=project,
        starting_weight=coil.current_weight, checked_out_at=_now(),
    )
    db.session.add(txn)
    ActivityEvent.log(
        ActivityEvent.TYPE_WIRE_CHECKOUT, coil.name or coil.barcode_code or f"coil #{coil.id}",
        actor=user_name, project=project, detail=f"starting weight {coil.current_weight}kg",
    )
    db.session.commit()
    return jsonify({"coil": coil.to_dict(), "transaction": txn.to_dict()}), 200


@wire_bp.route("/coils/<int:coil_id>/checkin", methods=["POST"])
def checkin_coil(coil_id):
    """1. Scan user  2. Scan wire -> prompts for finishing weight (client
    side) -> this endpoint. Weight used is always computed here, never
    trusted from the client (spec item 4)."""
    coil = db.session.get(WireCoil, coil_id)
    if not coil:
        return jsonify({"error": "Coil not found."}), 404
    if coil.status != WireCoil.STATUS_CHECKED_OUT:
        return jsonify({"error": "This welding wire isn't currently checked out."}), 409

    data = request.get_json(silent=True) or {}
    try:
        finishing_weight = float(data.get("finishing_weight"))
    except (TypeError, ValueError):
        return jsonify({"error": "finishing_weight is required and must be a number."}), 400
    if finishing_weight < 0:
        return jsonify({"error": "finishing_weight cannot be negative."}), 400

    open_txn = (WireTransaction.query
                .filter_by(coil_id=coil.id, checked_in_at=None)
                .order_by(WireTransaction.checked_out_at.desc())
                .first())
    if not open_txn:
        return jsonify({"error": "No open checkout found for this coil -- data may be out of sync."}), 409

    if finishing_weight > open_txn.starting_weight:
        return jsonify({
            "error": f"finishing_weight ({finishing_weight}) can't be more than the starting "
                     f"weight ({open_txn.starting_weight})."
        }), 400

    checked_in_by_name = (data.get("user_name") or "").strip() or coil.checked_out_by_name
    checked_in_by_badge = (data.get("user_badge") or "").strip() or None

    consumed = round(open_txn.starting_weight - finishing_weight, 4)
    now = _now()
    open_txn.finishing_weight = finishing_weight
    open_txn.consumed = consumed
    open_txn.checked_in_at = now
    open_txn.checked_in_by_name = checked_in_by_name
    open_txn.checked_in_by_badge = checked_in_by_badge

    coil.current_weight = finishing_weight
    coil.status = WireCoil.STATUS_EMPTY if finishing_weight <= 0 else WireCoil.STATUS_AVAILABLE
    coil.empty_at = _now() if coil.status == WireCoil.STATUS_EMPTY else None
    returned_project = coil.current_project
    coil.checked_out_by_name = None
    coil.checked_out_by_badge = None
    coil.current_project = None

    ActivityEvent.log(
        ActivityEvent.TYPE_WIRE_CHECKIN, coil.name or coil.barcode_code or f"coil #{coil.id}",
        actor=checked_in_by_name, project=returned_project,
        detail=f"-{consumed}kg used (coil now {finishing_weight}kg)",
    )
    db.session.commit()
    return jsonify({"coil": coil.to_dict(), "transaction": open_txn.to_dict()}), 200


@wire_bp.route("/coils/<int:coil_id>/history", methods=["GET"])
def coil_history(coil_id):
    coil = db.session.get(WireCoil, coil_id)
    if not coil:
        return jsonify({"error": "Coil not found."}), 404
    txns = (WireTransaction.query.filter_by(coil_id=coil.id)
            .order_by(WireTransaction.checked_out_at.asc()).all())
    return jsonify({"coil": coil.to_dict(), "transactions": [t.to_dict() for t in txns]}), 200


@wire_bp.route("/coils/<int:coil_id>/history/export", methods=["GET"])
def coil_history_export(coil_id):
    coil = db.session.get(WireCoil, coil_id)
    if not coil:
        return jsonify({"error": "Coil not found."}), 404
    txns = (WireTransaction.query.filter_by(coil_id=coil.id)
            .order_by(WireTransaction.checked_out_at.asc()).all())

    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["Coil Barcode", coil.barcode_code or ""])
    w.writerow(["Wire Code/Type", coil.wire_code.name if coil.wire_code else ""])
    w.writerow(["Initial Weight", coil.initial_weight])
    w.writerow(["Current Weight", coil.current_weight])
    w.writerow([])
    w.writerow(["User", "Badge", "Project", "Starting (kg)", "Finishing (kg)", "Used (kg)",
                "Checked Out", "Checked In"])
    for t in txns:
        w.writerow([
            t.user_name, t.user_badge or "", t.project or "",
            t.starting_weight, t.finishing_weight if t.finishing_weight is not None else "",
            t.consumed if t.consumed is not None else "",
            t.checked_out_at.isoformat() if t.checked_out_at else "",
            t.checked_in_at.isoformat() if t.checked_in_at else "",
        ])

    safe_ref = "".join(c if c.isalnum() or c in "-_" else "_" for c in (coil.barcode_code or str(coil.id)))
    return Response(
        buf.getvalue(), mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="coil_{safe_ref}_history.csv"'},
    )


# ───────────────────────── Reporting (spec items 11-15) ─────────────────
def _resolve_date_range(args):
    """Turns ?range=today|this_week|this_month|last_month or explicit
    ?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD into (start, end) UTC
    datetimes, or (None, None) for no filtering (spec item 14)."""
    preset = args.get("range")
    now = _now()
    if preset == "today":
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        return start, start + timedelta(days=1)
    if preset == "this_week":
        start = (now - timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
        return start, start + timedelta(days=7)
    if preset == "this_month":
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        next_month = (start + timedelta(days=32)).replace(day=1)
        return start, next_month
    if preset == "last_month":
        this_month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        last_month_end = this_month_start
        last_month_start = (this_month_start - timedelta(days=1)).replace(day=1)
        return last_month_start, last_month_end

    date_from, date_to = args.get("date_from"), args.get("date_to")
    start = end = None
    if date_from:
        start = datetime.fromisoformat(date_from).replace(tzinfo=timezone.utc)
    if date_to:
        end = datetime.fromisoformat(date_to).replace(tzinfo=timezone.utc) + timedelta(days=1)
    return start, end


def _filtered_transactions(args):
    """Only CLOSED (checked-in) transactions count toward usage totals
    -- an open checkout hasn't actually consumed anything yet."""
    start, end = _resolve_date_range(args)
    query = WireTransaction.query.filter(WireTransaction.checked_in_at.isnot(None))
    if start:
        query = query.filter(WireTransaction.checked_in_at >= start)
    if end:
        query = query.filter(WireTransaction.checked_in_at < end)
    if args.get("project"):
        query = query.filter(WireTransaction.project == args["project"])
    if args.get("user"):
        query = query.filter(WireTransaction.user_name == args["user"])
    if args.get("coil_id"):
        query = query.filter(WireTransaction.coil_id == args["coil_id"])
    if args.get("wire_code_id"):
        query = query.join(WireCoil).filter(WireCoil.wire_code_id == args["wire_code_id"])
    return query.order_by(WireTransaction.checked_in_at.asc()).all(), start, end


def _build_report(args):
    txns, start, end = _filtered_transactions(args)
    total_used = round(sum(t.consumed or 0 for t in txns), 4)

    def _group_totals(keyfn, label_fn=None):
        totals = {}
        for t in txns:
            key = keyfn(t)
            if key is None:
                continue
            totals[key] = totals.get(key, 0) + (t.consumed or 0)
        rows = [{"label": (label_fn(k) if label_fn else k), "total_used": round(v, 4)}
                for k, v in totals.items()]
        rows.sort(key=lambda r: -r["total_used"])
        return rows

    def _coil_label(coil_id):
        coil = db.session.get(WireCoil, coil_id)
        return (coil.barcode_code or f"coil #{coil_id}") if coil else f"coil #{coil_id}"

    return {
        "date_from": start.date().isoformat() if start else None,
        "date_to": (end - timedelta(days=1)).date().isoformat() if end else None,
        "total_used": total_used,
        "transaction_count": len(txns),
        "by_project": _group_totals(lambda t: t.project or "(no project)"),
        "by_user": _group_totals(lambda t: t.user_name),
        "by_wire_code": _group_totals(
            lambda t: t.coil.wire_code.name if t.coil and t.coil.wire_code else "(no code)"),
        "by_coil": _group_totals(lambda t: t.coil_id, label_fn=_coil_label),
        "transactions": [t.to_dict() for t in txns],
    }


@wire_bp.route("/report", methods=["GET"])
@permission_required("admin", "supervisor")
def wire_report():
    """JSON version of the report -- totals by project/user/wire code/
    coil, plus the raw filtered transactions (spec item 13)."""
    return jsonify(_build_report(request.args)), 200


@wire_bp.route("/report/pdf", methods=["GET"])
@permission_required("admin", "supervisor")
def wire_report_pdf():
    """Generate Report -> PDF (spec items 11, 12, 14, 15)."""
    from app.wire_report_pdf import build_wire_report_pdf
    report = _build_report(request.args)
    pdf_bytes = build_wire_report_pdf(report)
    filename = "welding_wire_report"
    if report["date_from"] or report["date_to"]:
        filename += f"_{report['date_from'] or 'start'}_to_{report['date_to'] or 'end'}"
    return send_file(
        io.BytesIO(pdf_bytes), mimetype="application/pdf",
        as_attachment=True, download_name=f"{filename}.pdf",
    )


# ─────────────────────── Project budgets/variance (extra) ───────────────
@wire_bp.route("/projects/<path:project>/budget", methods=["POST"])
@permission_required("admin", "supervisor")
def set_project_budget(project):
    data = request.get_json(silent=True) or {}
    try:
        target = float(data.get("target_weight"))
    except (TypeError, ValueError):
        return jsonify({"error": "target_weight is required and must be a number."}), 400

    row = db.session.get(WireProjectBudget, project)
    if row:
        row.target_weight = target
    else:
        row = WireProjectBudget(project=project, target_weight=target)
        db.session.add(row)
    db.session.commit()
    return jsonify(row.to_dict()), 200


@wire_bp.route("/projects/variance", methods=["GET"])
@permission_required("admin", "supervisor")
def all_project_variances():
    return jsonify(get_wire_project_variances()), 200
