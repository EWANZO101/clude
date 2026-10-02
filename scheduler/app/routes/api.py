"""JSON API for the mobile app (ios/ — an Expo app).

Mirrors the admin pages' behaviour for the owner account, but authenticates
with a bearer token instead of the session cookie, so it's exempt from CSRF
(there's no ambient cookie credential for another site to ride on).

Tokens are stateless: signed with SECRET_KEY and tied to a slice of the
user's password hash, so changing the password invalidates every token
already issued, without needing a tokens table.

All datetimes are naive local time in the user's timezone — the same
convention the rest of the app stores them in (see the TimeOff model) — and
are serialized as "YYYY-MM-DDTHH:MM" with no offset, so the app displays
them as-is instead of shifting them into the phone's timezone.
"""

from datetime import date, datetime, time as dt_time, timedelta, timezone as dt_timezone
from functools import wraps

from flask import Blueprint, current_app, g, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from app import csrf, db
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking
from app.models.push_device import PushDevice
from app.models.settings import MANUAL_STATUSES, Settings
from app.models.time_off import TimeOff
from app.models.user import User
from app.services.availability import ensure_working_hours_rows
from app.services.calendar import build_month_grid
from app.services.notifications import notify_cancelled_booking
from app.services.push import send_push
from app.services.security import clear_attempts, is_locked_out, record_failed_attempt
from app.services.status import get_current_status, local_now

api_bp = Blueprint("api", __name__, url_prefix="/api/v1")
csrf.exempt(api_bp)

TOKEN_MAX_AGE = 60 * 60 * 24 * 30  # 30 days


# --- helpers -----------------------------------------------------------------


def _serializer():
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"], salt="api-token")


def _password_fingerprint(user):
    return user.password_hash[-16:]


def _issue_token(user):
    return _serializer().dumps({"uid": user.id, "pw": _password_fingerprint(user)})


def _error(message, status):
    return jsonify({"error": message}), status


def _fmt_dt(dt):
    return dt.isoformat(timespec="minutes") if dt else None


def _fmt_time(t):
    return t.strftime("%H:%M") if t else None


def _user_json(user):
    return {"id": user.id, "name": user.name, "email": user.email, "timezone": user.timezone}


def _booking_json(b):
    return {
        "id": b.id,
        "name": b.name,
        "email": b.email,
        "phone": b.phone,
        "notes": b.notes,
        "start": _fmt_dt(b.start_datetime),
        "end": _fmt_dt(b.end_datetime),
        "status": b.status,
        "booking_type": b.booking_type.name if b.booking_type else None,
        "is_out_of_hours": b.is_out_of_hours,
        "out_of_hours_fee_shown": b.out_of_hours_fee_shown,
    }


def _time_off_json(t):
    return {
        "id": t.id,
        "start": _fmt_dt(t.start_datetime),
        "end": _fmt_dt(t.end_datetime),
        "all_day": t.all_day,
        "reason": t.reason,
    }


def _parse_date(value):
    try:
        return date.fromisoformat(value)
    except (TypeError, ValueError):
        return None


def _parse_time(value):
    try:
        return dt_time.fromisoformat(value)
    except (TypeError, ValueError):
        return None


def token_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return _error("Missing token.", 401)
        try:
            data = _serializer().loads(header[len("Bearer "):], max_age=TOKEN_MAX_AGE)
        except SignatureExpired:
            return _error("Session expired — please sign in again.", 401)
        except BadSignature:
            return _error("Invalid token.", 401)

        user = db.session.get(User, data.get("uid"))
        if user is None or data.get("pw") != _password_fingerprint(user):
            return _error("Session expired — please sign in again.", 401)

        g.api_user = user
        # Same guarantee the admin blueprint gives its pages: all 7
        # WorkingHours rows exist before anything reads the schedule.
        ensure_working_hours_rows(user)
        return view(*args, **kwargs)

    return wrapped


# --- CORS (only matters for the Expo web preview; native fetch ignores it) ---


@api_bp.before_request
def handle_preflight():
    if request.method == "OPTIONS":
        return "", 204


@api_bp.after_request
def add_cors_headers(response):
    # "*" is safe here because auth is a bearer token, never a cookie.
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
    response.headers["Cache-Control"] = "no-store"
    return response


@api_bp.errorhandler(404)
def api_not_found(e):
    return _error("Not found.", 404)


# --- auth --------------------------------------------------------------------


@api_bp.route("/auth/login", methods=["POST"])
def login():
    body = request.get_json(silent=True) or {}
    email = (body.get("email") or "").lower().strip()
    password = body.get("password") or ""
    if not email or not password:
        return _error("Enter your email and password.", 400)

    # Keyed per account rather than per IP: behind nginx every request's
    # remote_addr is 127.0.0.1, so an IP key would lock everyone out at once.
    throttle_key = f"api:{email}"
    if is_locked_out(throttle_key):
        return _error("Too many attempts. Please wait a few minutes and try again.", 429)

    user = User.query.filter_by(email=email).first()
    if not user or not user.check_password(password):
        record_failed_attempt(throttle_key)
        return _error("Incorrect email or password.", 401)

    clear_attempts(throttle_key)
    return jsonify({"token": _issue_token(user), "user": _user_json(user)})


@api_bp.route("/me")
@token_required
def me():
    return jsonify({"user": _user_json(g.api_user)})


# --- dashboard / status --------------------------------------------------------


@api_bp.route("/dashboard")
@token_required
def dashboard():
    user = g.api_user
    now = local_now(user)
    today = datetime.combine(now.date(), dt_time.min)

    active = Booking.query.filter(Booking.user_id == user.id, Booking.status.in_(ACTIVE_BOOKING_STATUSES))
    todays = (
        active.filter(Booking.start_datetime >= today, Booking.start_datetime < today + timedelta(days=1))
        .order_by(Booking.start_datetime.asc())
        .all()
    )
    week_count = active.filter(
        Booking.start_datetime >= today, Booking.start_datetime < today + timedelta(days=7)
    ).count()
    next_booking = active.filter(Booking.start_datetime >= now).order_by(Booking.start_datetime.asc()).first()

    return jsonify(
        {
            "user": _user_json(user),
            "now": _fmt_dt(now),
            "status": get_current_status(user),
            "manual_statuses": MANUAL_STATUSES,
            "current_task": Settings.for_user(user).current_task,
            "stats": {"todays_bookings": len(todays), "week_bookings": week_count},
            "todays_bookings": [_booking_json(b) for b in todays],
            "next_booking": _booking_json(next_booking) if next_booking else None,
        }
    )


@api_bp.route("/status", methods=["POST"])
@token_required
def update_status():
    body = request.get_json(silent=True) or {}
    chosen = body.get("status") or None
    if chosen is not None and chosen not in MANUAL_STATUSES:
        return _error("Unknown status.", 400)

    settings = Settings.for_user(g.api_user)
    settings.manual_status = chosen
    settings.manual_status_message = ((body.get("message") or "").strip()[:255] or None) if chosen else None
    settings.manual_status_expires_at = None
    db.session.commit()
    return jsonify({"status": get_current_status(g.api_user)})


@api_bp.route("/current-task", methods=["POST"])
@token_required
def update_current_task():
    body = request.get_json(silent=True) or {}
    settings = Settings.for_user(g.api_user)
    settings.current_task = (body.get("current_task") or "").strip()[:255] or None
    db.session.commit()
    return jsonify({"current_task": settings.current_task})


# --- bookings ------------------------------------------------------------------


@api_bp.route("/bookings")
@token_required
def bookings():
    user = g.api_user
    filter_ = request.args.get("filter", "upcoming")
    now = local_now(user)
    query = Booking.query.filter_by(user_id=user.id)

    if filter_ == "upcoming":
        query = query.filter(
            Booking.start_datetime >= now, Booking.status.in_(ACTIVE_BOOKING_STATUSES)
        ).order_by(Booking.start_datetime.asc())
    elif filter_ == "past":
        query = query.filter(Booking.start_datetime < now).order_by(Booking.start_datetime.desc())
    elif filter_ == "cancelled":
        query = query.filter(Booking.status == "cancelled").order_by(Booking.start_datetime.desc())
    else:
        query = query.order_by(Booking.start_datetime.desc())

    return jsonify({"bookings": [_booking_json(b) for b in query.limit(200).all()]})


@api_bp.route("/bookings/<int:booking_id>")
@token_required
def booking_detail(booking_id):
    booking = Booking.query.filter_by(id=booking_id, user_id=g.api_user.id).first_or_404()
    return jsonify({"booking": _booking_json(booking)})


@api_bp.route("/bookings/<int:booking_id>/cancel", methods=["POST"])
@token_required
def cancel_booking(booking_id):
    booking = Booking.query.filter_by(id=booking_id, user_id=g.api_user.id).first_or_404()
    if booking.status != "cancelled":
        booking.status = "cancelled"
        booking.cancelled_at = datetime.now(dt_timezone.utc).replace(tzinfo=None)
        db.session.commit()
        notify_cancelled_booking(booking, cancelled_by="admin")
    return jsonify({"booking": _booking_json(booking)})


@api_bp.route("/bookings/<int:booking_id>/complete", methods=["POST"])
@token_required
def complete_booking(booking_id):
    booking = Booking.query.filter_by(id=booking_id, user_id=g.api_user.id).first_or_404()
    booking.status = "completed"
    db.session.commit()
    return jsonify({"booking": _booking_json(booking)})


@api_bp.route("/bookings/<int:booking_id>/no-show", methods=["POST"])
@token_required
def mark_no_show(booking_id):
    booking = Booking.query.filter_by(id=booking_id, user_id=g.api_user.id).first_or_404()
    booking.status = "no_show"
    db.session.commit()
    return jsonify({"booking": _booking_json(booking)})


# --- calendar ------------------------------------------------------------------


@api_bp.route("/calendar")
@token_required
def calendar_month():
    user = g.api_user
    today = local_now(user).date()
    year = request.args.get("year", type=int) or today.year
    month = request.args.get("month", type=int) or today.month
    if not 1 <= month <= 12:
        return _error("Invalid month.", 400)

    days, meta = build_month_grid(user, year, month)
    return jsonify(
        {
            "year": year,
            "month": month,
            "month_label": meta["month_label"],
            "today": today.isoformat(),
            "days": [
                {
                    "date": d["date"].isoformat(),
                    "is_working_day": d["is_working_day"],
                    "working_hours": (
                        {"start": _fmt_time(d["working_hours"].start_time), "end": _fmt_time(d["working_hours"].end_time)}
                        if d["working_hours"]
                        else None
                    ),
                    "breaks": [
                        {"label": b.label, "start": _fmt_time(b.start_time), "end": _fmt_time(b.end_time)}
                        for b in d["breaks"]
                    ],
                    "time_offs": [_time_off_json(t) for t in d["time_offs"]],
                    "bookings": [_booking_json(b) for b in d["bookings"]],
                }
                # Only in-month days: the app renders an agenda list, not the
                # desktop 7-column grid that needs the padding days.
                for d in days
                if d["in_month"]
            ],
        }
    )


# --- time off --------------------------------------------------------------------


@api_bp.route("/time-off")
@token_required
def time_off_list():
    entries = TimeOff.query.filter_by(user_id=g.api_user.id).order_by(TimeOff.start_datetime.desc()).all()
    return jsonify({"time_off": [_time_off_json(t) for t in entries]})


@api_bp.route("/time-off", methods=["POST"])
@token_required
def time_off_create():
    body = request.get_json(silent=True) or {}
    start_date = _parse_date(body.get("start_date"))
    end_date = _parse_date(body.get("end_date"))
    all_day = bool(body.get("all_day", True))
    if not start_date or not end_date:
        return _error("Enter a valid start and end date.", 400)

    if all_day:
        start_dt = datetime.combine(start_date, dt_time.min)
        end_dt = datetime.combine(end_date, dt_time.max)
    else:
        start_time = _parse_time(body.get("start_time"))
        end_time = _parse_time(body.get("end_time"))
        if not start_time or not end_time:
            return _error("Enter a valid start and end time.", 400)
        start_dt = datetime.combine(start_date, start_time)
        end_dt = datetime.combine(end_date, end_time)

    if end_dt <= start_dt:
        return _error("The end must be after the start.", 400)

    entry = TimeOff(
        user_id=g.api_user.id,
        start_datetime=start_dt,
        end_datetime=end_dt,
        all_day=all_day,
        reason=(body.get("reason") or "").strip()[:255] or None,
    )
    db.session.add(entry)
    db.session.commit()
    return jsonify({"time_off": _time_off_json(entry)}), 201


@api_bp.route("/time-off/<int:time_off_id>", methods=["DELETE"])
@token_required
def time_off_delete(time_off_id):
    entry = TimeOff.query.filter_by(id=time_off_id, user_id=g.api_user.id).first_or_404()
    db.session.delete(entry)
    db.session.commit()
    return "", 204


# --- push notifications ------------------------------------------------------------


def _valid_expo_token(token):
    return token.startswith(("ExponentPushToken[", "ExpoPushToken[")) and token.endswith("]") and len(token) <= 255


@api_bp.route("/push-devices", methods=["POST"])
@token_required
def register_push_device():
    token = ((request.get_json(silent=True) or {}).get("token") or "").strip()
    if not _valid_expo_token(token):
        return _error("Invalid push token.", 400)

    now = datetime.now(dt_timezone.utc).replace(tzinfo=None)
    device = PushDevice.query.filter_by(token=token).first()
    if device:
        # Same phone signing in to a different account moves the token over.
        device.user_id = g.api_user.id
        device.last_seen_at = now
    else:
        db.session.add(PushDevice(user_id=g.api_user.id, token=token, last_seen_at=now))
    db.session.commit()
    return jsonify({"registered": True})


@api_bp.route("/push-devices", methods=["DELETE"])
@token_required
def unregister_push_device():
    token = ((request.get_json(silent=True) or {}).get("token") or "").strip()
    PushDevice.query.filter_by(token=token, user_id=g.api_user.id).delete(synchronize_session=False)
    db.session.commit()
    return "", 204


@api_bp.route("/push-devices/test", methods=["POST"])
@token_required
def test_push():
    if not PushDevice.query.filter_by(user_id=g.api_user.id).first():
        return _error("This account has no phones registered for notifications yet.", 400)
    send_push(g.api_user, "Test notification", "Notifications from Scheduler are working.", {"kind": "test"})
    return jsonify({"sent": True})
