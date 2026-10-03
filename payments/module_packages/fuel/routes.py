import json
import time
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash, request, jsonify, Response
from flask_login import login_required, current_user

from app.extensions import db
from app.core.events.bus import on, emit
from app.core.live import broadcaster
from app.core.search.registry import register_search_provider, SearchResult
from app.core.export.registry import register_exporter

from .models import FuelVehicle, FuelEntry
from . import calculations
from . import stats
from . import ocr

bp = Blueprint("fuel", __name__, url_prefix="/fuel", template_folder="templates")


def money(amount_minor, currency="GBP"):
    symbols = {"GBP": "£", "USD": "$", "EUR": "€"}
    symbol = symbols.get(currency, currency + " ")
    sign = "-" if amount_minor < 0 else ""
    return f"{sign}{symbol}{abs(amount_minor) / 100:,.2f}"


bp.add_app_template_filter(money, "money")


def _parse_cost_to_minor(raw):
    raw = (raw or "0").strip().replace("£", "")
    try:
        return round(float(raw) * 100)
    except ValueError:
        return 0


def _user_vehicles():
    return FuelVehicle.query.filter_by(user_id=current_user.id).order_by(FuelVehicle.name).all()


# ---- React to finance transactions changing elsewhere ----
#
# Without this, fuel-purchase detection (stats.detect_fuel_purchases) only
# ran when the user happened to load /fuel/. Finance now emits
# "transactions.changed" after any import (CSV or bank sync) or bulk/auto
# categorisation, so a fill-up shows up here without that extra visit.
# Best-effort and defensive per the event-handler convention used
# throughout this app -- a failure here must never break the request that
# triggered the event.

@on("transactions.changed")
def _on_transactions_changed(**payload):
    user_id = payload.get("user_id")
    if not user_id:
        return
    try:
        vehicle = FuelVehicle.query.filter_by(user_id=user_id, active=True).order_by(FuelVehicle.name).first()
        if vehicle:
            stats.detect_fuel_purchases(user_id, vehicle.id)
    except Exception:
        db.session.rollback()


@on("transaction.deleted")
def _on_transaction_deleted(**payload):
    """A finance transaction was deleted (manually, or by the dedupe sweep).
    A fuel entry's transaction_id is just an optional back-reference to a
    matched bank transaction -- clear it rather than deleting the fuel log
    entry itself, which the user logged by hand and still owns."""
    transaction_id = payload.get("transaction_id")
    superseded_by = payload.get("superseded_by")
    if not transaction_id:
        return
    try:
        FuelEntry.query.filter_by(transaction_id=transaction_id).update({"transaction_id": superseded_by})
        db.session.commit()
    except Exception:
        db.session.rollback()


# ---- Overview ----

@bp.route("/")
@login_required
def index():
    vehicles = _user_vehicles()

    default_vehicle = next((v for v in vehicles if v.active), vehicles[0] if vehicles else None)
    newly_detected = 0
    if default_vehicle:
        newly_detected = stats.detect_fuel_purchases(current_user.id, default_vehicle.id)
        if newly_detected:
            db.session.refresh(default_vehicle)
    elif stats.available():
        flash("Fuel purchases were spotted in your transactions, but there\'s no vehicle to log them "
              "against yet -- add one and they\'ll be pulled in automatically.", "warning")

    summary_by_vehicle = {}
    for v in vehicles:
        summary_by_vehicle[v.id] = calculations.vehicle_summary(v.entries)

    recent_entries = FuelEntry.query.filter_by(user_id=current_user.id).order_by(
        FuelEntry.date.desc()
    ).limit(10).all()

    fuel_stats_available = stats.available()
    spending = stats.fuel_spending_summary(current_user.id) if fuel_stats_available else {}

    if newly_detected:
        flash(f"Found {newly_detected} new fuel purchase(s) in your transactions and added "
              f"them to {default_vehicle.name}.", "success")

    return render_template(
        "fuel/index.html", vehicles=vehicles, summary_by_vehicle=summary_by_vehicle,
        recent_entries=recent_entries, spending=spending, fuel_stats_available=fuel_stats_available,
    )


# ---- Vehicles ----

@bp.route("/vehicles")
@login_required
def vehicles():
    return render_template("fuel/vehicles.html", vehicles=_user_vehicles())


@bp.route("/vehicles/new", methods=["GET", "POST"])
@login_required
def new_vehicle():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Vehicle name is required.", "error")
            return render_template("fuel/vehicle_form.html", vehicle=None)

        year_raw = request.form.get("year", "").strip()
        vehicle = FuelVehicle(
            user_id=current_user.id, name=name,
            make=request.form.get("make", "").strip(),
            model=request.form.get("model", "").strip(),
            year=int(year_raw) if year_raw.isdigit() else None,
            registration=request.form.get("registration", "").strip().upper(),
            fuel_type=request.form.get("fuel_type", "petrol"),
        )
        db.session.add(vehicle)
        db.session.commit()
        flash("Vehicle added.", "success")
        return redirect(url_for("fuel.vehicle_detail", vehicle_id=vehicle.id))

    return render_template("fuel/vehicle_form.html", vehicle=None)


def _group_entries_by_month(entries):
    """entries must already be sorted newest-first. Returns
    [(month_label, [entries in that month]), ...] in the same order."""
    groups = []
    current_label = None
    for e in entries:
        label = e.date.strftime("%B %Y")
        if label != current_label:
            groups.append((label, []))
            current_label = label
        groups[-1][1].append(e)
    return groups


@bp.route("/vehicles/<vehicle_id>")
@login_required
def vehicle_detail(vehicle_id):
    vehicle = FuelVehicle.query.filter_by(id=vehicle_id, user_id=current_user.id).first_or_404()
    summary = calculations.vehicle_summary(vehicle.entries)
    entries = sorted(vehicle.entries, key=lambda e: e.date, reverse=True)
    entries_by_month = _group_entries_by_month(entries)
    return render_template("fuel/vehicle_detail.html", vehicle=vehicle, summary=summary,
                            entries=entries, entries_by_month=entries_by_month)


def _vehicle_summary_json(vehicle):
    """Same data as vehicle_detail's template context, shaped for the
    live-update JS to re-render the page in place after an SSE event."""
    summary = calculations.vehicle_summary(vehicle.entries)
    entries = sorted(vehicle.entries, key=lambda e: e.date, reverse=True)
    return {
        "summary": {
            "average_mpg": summary["average_mpg"],
            "average_cost_per_mile_minor": summary["average_cost_per_mile_minor"],
            "total_spent_minor": summary["total_spent_minor"],
            "total_litres": summary["total_litres"],
            "fills": [
                {
                    "date": f["date"].isoformat(), "distance_miles": f["distance_miles"],
                    "litres_used": f["litres_used"], "mpg": f["mpg"],
                    "cost_per_mile_minor": f["cost_per_mile_minor"],
                }
                for f in summary["fills"]
            ],
        },
        "entries": [
            {
                "id": e.id, "date": e.date.isoformat(), "odometer": e.odometer, "litres": e.litres,
                "full_tank": e.full_tank, "cost_minor": e.cost_minor, "edit_url": url_for("fuel.edit_entry", entry_id=e.id),
            }
            for e in entries
        ],
    }


@bp.route("/vehicles/<vehicle_id>/summary.json")
@login_required
def vehicle_summary_json(vehicle_id):
    vehicle = FuelVehicle.query.filter_by(id=vehicle_id, user_id=current_user.id).first_or_404()
    return jsonify(_vehicle_summary_json(vehicle))


@bp.route("/vehicles/<vehicle_id>/stream")
@login_required
def vehicle_stream(vehicle_id):
    """Server-Sent Events stream: pushes a 'changed' message whenever this
    vehicle's fuel entries change, or a fuel-relevant bank transaction comes
    in (see the app-wide event bus -> broadcaster wiring in
    app/core/events/bus.py). Reconnects every ~50s on its own (well inside
    gunicorn's request timeout) -- EventSource on the client transparently
    reconnects, so this behaves like a long-lived stream without ever
    holding one open indefinitely."""
    vehicle = FuelVehicle.query.filter_by(id=vehicle_id, user_id=current_user.id).first_or_404()
    topics = [f"fuel_vehicle:{vehicle.id}", f"user:{current_user.id}"]
    relevant_events = {"fuel_entry.created", "fuel_entry.updated", "fuel_entry.deleted", "transactions.changed"}

    def generate():
        subs = [(t, broadcaster.subscribe(t)) for t in topics]
        try:
            deadline = time.time() + 50
            yield "retry: 2000\n\n"
            while time.time() < deadline:
                fired = False
                for _, q in subs:
                    try:
                        msg = q.get(timeout=1)
                    except Exception:
                        continue
                    if msg["event"] in relevant_events:
                        yield f"event: changed\ndata: {json.dumps({'reason': msg['event']})}\n\n"
                        fired = True
                if fired:
                    break
                yield ": heartbeat\n\n"
        finally:
            for topic, q in subs:
                broadcaster.unsubscribe(topic, q)

    return Response(generate(), mimetype="text/event-stream", headers={
        "Cache-Control": "no-cache", "X-Accel-Buffering": "no",
    })


@bp.route("/vehicles/<vehicle_id>/edit", methods=["GET", "POST"])
@login_required
def edit_vehicle(vehicle_id):
    vehicle = FuelVehicle.query.filter_by(id=vehicle_id, user_id=current_user.id).first_or_404()
    if request.method == "POST":
        vehicle.name = request.form.get("name", vehicle.name).strip() or vehicle.name
        vehicle.make = request.form.get("make", "").strip()
        vehicle.model = request.form.get("model", "").strip()
        year_raw = request.form.get("year", "").strip()
        vehicle.year = int(year_raw) if year_raw.isdigit() else None
        vehicle.registration = request.form.get("registration", "").strip().upper()
        vehicle.fuel_type = request.form.get("fuel_type", vehicle.fuel_type)
        db.session.commit()
        flash("Vehicle updated.", "success")
        return redirect(url_for("fuel.vehicle_detail", vehicle_id=vehicle.id))
    return render_template("fuel/vehicle_form.html", vehicle=vehicle)


@bp.route("/vehicles/<vehicle_id>/archive", methods=["POST"])
@login_required
def archive_vehicle(vehicle_id):
    vehicle = FuelVehicle.query.filter_by(id=vehicle_id, user_id=current_user.id).first_or_404()
    vehicle.active = not vehicle.active
    db.session.commit()
    flash("Vehicle archived." if not vehicle.active else "Vehicle reactivated.", "success")
    return redirect(url_for("fuel.vehicles"))


@bp.route("/vehicles/<vehicle_id>/delete", methods=["POST"])
@login_required
def delete_vehicle(vehicle_id):
    vehicle = FuelVehicle.query.filter_by(id=vehicle_id, user_id=current_user.id).first_or_404()
    db.session.delete(vehicle)
    db.session.commit()
    flash("Vehicle and its fuel entries deleted.", "success")
    return redirect(url_for("fuel.vehicles"))


# ---- Fuel entries ----

@bp.route("/vehicles/<vehicle_id>/entries/new", methods=["GET", "POST"])
@login_required
def new_entry(vehicle_id):
    vehicle = FuelVehicle.query.filter_by(id=vehicle_id, user_id=current_user.id).first_or_404()
    if request.method == "POST":
        date_raw = request.form.get("date", "").strip()
        try:
            entry_date = datetime.strptime(date_raw, "%Y-%m-%d").date()
        except ValueError:
            flash("A valid date is required.", "error")
            return render_template("fuel/entry_form.html", vehicle=vehicle, entry=None)

        odometer_raw = request.form.get("odometer", "").strip()
        litres_raw = request.form.get("litres", "").strip()

        entry = FuelEntry(
            user_id=current_user.id, vehicle_id=vehicle.id, date=entry_date,
            odometer=int(odometer_raw) if odometer_raw.isdigit() else None,
            litres=float(litres_raw) if litres_raw else None,
            cost_minor=_parse_cost_to_minor(request.form.get("cost")),
            full_tank=request.form.get("full_tank") == "on",
            notes=request.form.get("notes", "").strip(),
        )
        db.session.add(entry)
        db.session.commit()
        emit("fuel_entry.created", user_id=current_user.id, vehicle_id=vehicle.id, entry_id=entry.id)
        flash("Fuel entry added.", "success")
        return redirect(url_for("fuel.vehicle_detail", vehicle_id=vehicle.id))

    return render_template("fuel/entry_form.html", vehicle=vehicle, entry=None)


@bp.route("/scan/odometer", methods=["POST"])
@login_required
def scan_odometer():
    photo = request.files.get("photo")
    if not photo:
        return jsonify({"error": "No photo received."}), 400
    try:
        result = ocr.read_odometer(photo.read())
    except Exception as e:
        return jsonify({"error": "Could not read that photo: " + str(e)}), 500
    return jsonify(result)


@bp.route("/scan/fillup", methods=["POST"])
@login_required
def scan_fillup():
    photo = request.files.get("photo")
    if not photo:
        return jsonify({"error": "No photo received."}), 400
    try:
        result = ocr.read_fillup(photo.read())
    except Exception as e:
        return jsonify({"error": "Could not read that photo: " + str(e)}), 500
    return jsonify(result)


@bp.route("/entries/<entry_id>/edit", methods=["GET", "POST"])
@login_required
def edit_entry(entry_id):
    entry = FuelEntry.query.filter_by(id=entry_id, user_id=current_user.id).first_or_404()
    vehicle = entry.vehicle
    if request.method == "POST":
        date_raw = request.form.get("date", "").strip()
        try:
            entry.date = datetime.strptime(date_raw, "%Y-%m-%d").date()
        except ValueError:
            flash("A valid date is required.", "error")
            return render_template("fuel/entry_form.html", vehicle=vehicle, entry=entry)

        odometer_raw = request.form.get("odometer", "").strip()
        litres_raw = request.form.get("litres", "").strip()
        entry.odometer = int(odometer_raw) if odometer_raw.isdigit() else None
        entry.litres = float(litres_raw) if litres_raw else None
        entry.cost_minor = _parse_cost_to_minor(request.form.get("cost"))
        entry.full_tank = request.form.get("full_tank") == "on"
        entry.notes = request.form.get("notes", "").strip()
        db.session.commit()
        emit("fuel_entry.updated", user_id=current_user.id, vehicle_id=vehicle.id, entry_id=entry.id)
        flash("Fuel entry updated.", "success")
        return redirect(url_for("fuel.vehicle_detail", vehicle_id=vehicle.id))

    return render_template("fuel/entry_form.html", vehicle=vehicle, entry=entry)


@bp.route("/entries/<entry_id>/delete", methods=["POST"])
@login_required
def delete_entry(entry_id):
    entry = FuelEntry.query.filter_by(id=entry_id, user_id=current_user.id).first_or_404()
    vehicle_id = entry.vehicle_id
    db.session.delete(entry)
    db.session.commit()
    emit("fuel_entry.deleted", user_id=current_user.id, vehicle_id=vehicle_id, entry_id=entry_id)
    flash("Fuel entry deleted.", "success")
    return redirect(url_for("fuel.vehicle_detail", vehicle_id=vehicle_id))


# ---- Search provider registration ----

def _search_provider(query, user):
    results = []
    matches = FuelVehicle.query.filter(
        FuelVehicle.user_id == user.id, FuelVehicle.name.ilike(f"%{query}%")
    ).limit(10).all()
    for v in matches:
        results.append(SearchResult(title=v.name, url=f"/fuel/vehicles/{v.id}",
                                     category="Vehicle", snippet=v.registration or ""))
    return results


register_search_provider("fuel", _search_provider)


# ---- Full-system export registration (Part 10) ----

def _export_fuel(user):
    import csv as _csv
    import io as _io
    import json as _json

    vehicles = FuelVehicle.query.filter_by(user_id=user.id).all()
    buf = _io.StringIO()
    writer = _csv.writer(buf)
    writer.writerow(["vehicle", "date", "odometer", "litres", "cost", "full_tank", "notes"])
    payload = []
    for v in vehicles:
        entries = sorted(v.entries, key=lambda e: e.date)
        for e in entries:
            writer.writerow([v.name, e.date.isoformat(), e.odometer or "", e.litres or "",
                              money(e.cost_minor).replace("£", ""), "yes" if e.full_tank else "no", e.notes or ""])
        payload.append({
            "name": v.name, "make": v.make, "model": v.model, "year": v.year,
            "registration": v.registration, "fuel_type": v.fuel_type,
            "entries": [{"date": e.date.isoformat(), "odometer": e.odometer, "litres": e.litres,
                         "cost_minor": e.cost_minor, "full_tank": e.full_tank} for e in entries],
        })

    return {
        "fuel_entries.csv": (buf.getvalue(), "text/csv"),
        "fuel_vehicles.json": (_json.dumps(payload, indent=2, default=str), "application/json"),
    }


register_exporter("fuel", "Fuel (vehicles & fill-up log)", _export_fuel)
