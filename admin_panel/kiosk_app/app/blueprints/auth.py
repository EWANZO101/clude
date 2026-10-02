from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, session
from flask_login import login_user, logout_user, login_required, current_user

from app.extensions import db
from app.models import LocalUser, RolePermission, ActivityEvent, ActivityFlag

bp = Blueprint("auth", __name__, url_prefix="/auth")

# Session key holding the *previous* last_login_at (ISO string) while a
# person is mid-review — LocalUser.last_login_at itself isn't advanced to
# now() until they finish, so refreshing/re-entering the review page keeps
# showing the same set instead of the window silently shrinking to zero.
_REVIEW_SINCE_KEY = "activity_review_since"


def _role_login_enabled(role: str) -> bool:
    rp = RolePermission.query.get(role)
    return rp.login_enabled if rp else True  # no row yet = enabled by default


@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        identifier = request.form.get("identifier", "").strip()
        password = request.form.get("password", "")

        # Badge match first (case-insensitive, matches scanner input),
        # then username (case-sensitive as typed) — same order as the
        # original StockTool Kiosk (technical doc Section 4.3).
        user = LocalUser.query.filter(
            db.func.lower(LocalUser.badge_code) == identifier.lower()
        ).first()
        if user is None:
            user = LocalUser.query.filter_by(username=identifier).first()

        if user is None or not user.is_active:
            flash("Badge or username not recognized.", "danger")
            return render_template("auth/login.html")

        if not _role_login_enabled(user.role):
            flash("Logins for this role are currently disabled.", "warning")
            return render_template("auth/login.html")

        if not user.check_password(password):
            flash("Incorrect password.", "danger")
            return render_template("auth/login.html")

        login_user(user)

        # "What happened on my account since I was last here?" — a quick
        # login-time check so a mismatch between who's actually logged in
        # and who a scan got recorded for (see ActivityEvent.actor vs
        # .local_user_id) gets caught by the one person who'd actually
        # know it's wrong, not left to silently stand forever. Skipped on
        # a person's very first-ever login (nothing to compare against
        # yet) and whenever there's simply nothing to review.
        previous_login = user.last_login_at
        has_pending_review = False
        if previous_login is not None:
            has_pending_review = ActivityEvent.query.filter(
                ActivityEvent.local_user_id == user.id,
                ActivityEvent.created_at > previous_login,
            ).first() is not None

        if has_pending_review:
            session[_REVIEW_SINCE_KEY] = previous_login.isoformat()
            return redirect(url_for("auth.activity_review"))

        user.last_login_at = datetime.utcnow()
        db.session.commit()
        return redirect(url_for("dashboard.index"))

    return render_template("auth/login.html")


@bp.route("/activity-review", methods=["GET", "POST"])
@login_required
def activity_review():
    """The "2 minute check" — everything recorded under this account since
    the previous login, with a one-tap all-clear or a quick way to flag
    anything that doesn't look right. See the login route above for how a
    person lands here in the first place."""
    # No pending review queued (already completed this login's review, or
    # this URL was opened directly rather than via the login redirect) —
    # bounce to the dashboard instead of falling through to an unbounded
    # "since the beginning of time" query, which would just re-show every
    # event this account has ever had forever.
    if _REVIEW_SINCE_KEY not in session:
        return redirect(url_for("dashboard.index"))

    since = datetime.fromisoformat(session[_REVIEW_SINCE_KEY])
    events = ActivityEvent.query.filter(
        ActivityEvent.local_user_id == current_user.id,
        ActivityEvent.created_at > since,
    ).order_by(ActivityEvent.created_at.desc()).all()

    # Nothing left to show (already confirmed, then the page got reloaded/
    # revisited) — just finish up rather than get stuck with no way out.
    if not events:
        current_user.last_login_at = datetime.utcnow()
        db.session.commit()
        session.pop(_REVIEW_SINCE_KEY, None)
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        flagged_ids = request.form.getlist("flag")
        note = request.form.get("note", "").strip() or None
        event_ids = {e.id for e in events}
        flagged_count = 0
        for raw_id in flagged_ids:
            try:
                event_id = int(raw_id)
            except ValueError:
                continue
            if event_id not in event_ids:
                continue  # not one of the rows actually shown this review
            db.session.add(ActivityFlag(
                activity_event_id=event_id, reported_by_id=current_user.id, note=note,
            ))
            flagged_count += 1

        current_user.last_login_at = datetime.utcnow()
        db.session.commit()
        session.pop(_REVIEW_SINCE_KEY, None)

        if flagged_count:
            flash(f"Thanks — flagged {flagged_count} item(s) for a supervisor to look into.", "warning")
        return redirect(url_for("dashboard.index"))

    from app.blueprints.dashboard import _event_style
    return render_template("auth/activity_review.html", events=events, event_style=_event_style)


@bp.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("auth.login"))
