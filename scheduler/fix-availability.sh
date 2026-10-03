#!/usr/bin/env bash
# Fix: Availability page rejected valid hours, wiped ALL days on one bad
# day, and re-showed stale DB values on error instead of what you typed.
# Run from anywhere on the box (as the user that owns the app / with sudo
# for the systemctl restart). Edit APP_DIR / SERVICE below if they differ.
set -euo pipefail

APP_DIR="/root/scheduler"        # <-- change if scheduler lives elsewhere
SERVICE="scheduler"             # <-- systemd unit name for the app

ROUTE="$APP_DIR/app/routes/admin.py"
TEMPLATE="$APP_DIR/app/templates/admin/availability.html"

for f in "$ROUTE" "$TEMPLATE"; do
  [ -f "$f" ] || { echo "Missing: $f — fix APP_DIR at top of this script." >&2; exit 1; }
done

ts=$(date +%Y%m%d%H%M%S)
cp "$ROUTE" "$ROUTE.bak.$ts"
cp "$TEMPLATE" "$TEMPLATE.bak.$ts"
echo "Backed up to *.bak.$ts"

python3 - "$ROUTE" "$TEMPLATE" << 'PYEOF'
import sys, re

route_path, tmpl_path = sys.argv[1], sys.argv[2]

# ---------- app/routes/admin.py ----------
with open(route_path, "r", encoding="utf-8") as f:
    route = f.read()

old_route = '''        rows = WorkingHours.query.filter_by(user_id=current_user.id).all()
        by_day = {wh.day_of_week: wh for wh in rows}
        errors = []

        for day in range(7):
            wh = by_day[day]
            enabled = request.form.get(f"day_{day}_enabled") == "on"
            start_raw = request.form.get(f"day_{day}_start", "")
            end_raw = request.form.get(f"day_{day}_end", "")

            wh.enabled = enabled
            if not enabled:
                continue

            try:
                start_time = dt_time.fromisoformat(start_raw)
                end_time = dt_time.fromisoformat(end_raw)
            except ValueError:
                errors.append(f"{DAY_NAMES[day]}: enter valid start and end times.")
                continue

            if end_time <= start_time:
                errors.append(f"{DAY_NAMES[day]}: end time must be after start time.")
                continue

            wh.start_time = start_time
            wh.end_time = end_time

        if errors:
            for e in errors:
                flash(e, "error")
        else:
            db.session.commit()
            flash("Working hours updated.", "success")
        return redirect(url_for("admin.availability"))

    working_hours = (
        WorkingHours.query.filter_by(user_id=current_user.id).order_by(WorkingHours.day_of_week).all()
    )
    return render_template(
        "admin/availability.html",
        working_hours=working_hours,
        csrf_form=csrf_form,
        break_form=break_form,
        active_page="availability",
    )'''

new_route = '''        rows = WorkingHours.query.filter_by(user_id=current_user.id).all()
        by_day = {wh.day_of_week: wh for wh in rows}
        errors = []
        # Snapshot of exactly what was submitted, keyed by day, so that if we
        # bounce back to the form with errors we re-render what the person
        # actually typed — not stale DB values that happen to look "fine"
        # and make the error message look wrong.
        submitted = {}

        for day in range(7):
            wh = by_day[day]
            enabled = request.form.get(f"day_{day}_enabled") == "on"
            start_raw = request.form.get(f"day_{day}_start", "").strip()
            end_raw = request.form.get(f"day_{day}_end", "").strip()
            submitted[day] = {"enabled": enabled, "start": start_raw, "end": end_raw}

            wh.enabled = enabled
            if not enabled:
                continue

            try:
                start_time = dt_time.fromisoformat(start_raw)
                end_time = dt_time.fromisoformat(end_raw)
            except ValueError:
                errors.append(f"{DAY_NAMES[day]}: enter valid start and end times.")
                continue

            if end_time <= start_time:
                errors.append(
                    f"{DAY_NAMES[day]}: end time must be after start time "
                    f"({start_raw or '?'}\\u2013{end_raw or '?'} given)."
                )
                continue

            wh.start_time = start_time
            wh.end_time = end_time

        # Commit whatever validated cleanly regardless of errors on other
        # days — a typo on Saturday shouldn't discard edits you made to
        # every other day. Days that failed validation keep their previous
        # saved times untouched.
        db.session.commit()

        if errors:
            for e in errors:
                flash(e, "error")
            flash(
                "Days without an error above were saved. Fix the "
                "highlighted day(s) and save again.",
                "info",
            )
            working_hours = (
                WorkingHours.query.filter_by(user_id=current_user.id)
                .order_by(WorkingHours.day_of_week)
                .all()
            )
            return render_template(
                "admin/availability.html",
                working_hours=working_hours,
                csrf_form=csrf_form,
                break_form=break_form,
                active_page="availability",
                form_state=submitted,
            )

        flash("Working hours updated.", "success")
        return redirect(url_for("admin.availability"))

    working_hours = (
        WorkingHours.query.filter_by(user_id=current_user.id).order_by(WorkingHours.day_of_week).all()
    )
    return render_template(
        "admin/availability.html",
        working_hours=working_hours,
        csrf_form=csrf_form,
        break_form=break_form,
        active_page="availability",
        form_state=None,
    )'''

if old_route not in route:
    print("ERROR: admin.py doesn't match expected content — route not patched. "
          "File may already be patched or has diverged; check manually.", file=sys.stderr)
    sys.exit(1)

route = route.replace(old_route, new_route, 1)
with open(route_path, "w", encoding="utf-8") as f:
    f.write(route)
print("Patched", route_path)

# ---------- app/templates/admin/availability.html ----------
with open(tmpl_path, "r", encoding="utf-8") as f:
    tmpl = f.read()

old_tmpl = '''  {% for wh in working_hours %}
  <div class="p-5 sm:p-6">
    <div class="flex flex-col gap-4 sm:flex-row sm:items-center">
      <label class="flex w-40 shrink-0 items-center gap-3">
        <input
          type="checkbox"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_enabled"
          {{ 'checked' if wh.enabled }}
          class="h-4 w-4 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base day-toggle"
          data-day="{{ wh.day_of_week }}"
        >
        <span class="font-medium text-ink">{{ wh.day_name }}</span>
      </label>

      <div
        class="flex flex-1 flex-wrap items-center gap-3"
        id="day-{{ wh.day_of_week }}-times"
      >
        <input
          type="time"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_start"
          value="{{ wh.start_time.strftime('%H:%M') if wh.start_time else '09:00' }}"
          class="field-input w-32"
          {{ 'disabled' if not wh.enabled }}
        >

        <span class="text-ink-faint">to</span>

        <input
          type="time"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_end"
          value="{{ wh.end_time.strftime('%H:%M') if wh.end_time else '17:00' }}"
          class="field-input w-32"
          {{ 'disabled' if not wh.enabled }}
        >
      </div>
    </div>'''

new_tmpl = '''  {% for wh in working_hours %}
  {% set fs = form_state[wh.day_of_week] if form_state and wh.day_of_week in form_state else None %}
  {% set day_enabled = fs.enabled if fs else wh.enabled %}
  {% set day_start = fs.start if (fs and fs.start) else (wh.start_time.strftime('%H:%M') if wh.start_time else '09:00') %}
  {% set day_end = fs.end if (fs and fs.end) else (wh.end_time.strftime('%H:%M') if wh.end_time else '17:00') %}
  <div class="p-5 sm:p-6">
    <div class="flex flex-col gap-4 sm:flex-row sm:items-center">
      <label class="flex w-40 shrink-0 items-center gap-3">
        <input
          type="checkbox"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_enabled"
          {{ 'checked' if day_enabled }}
          class="h-4 w-4 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base day-toggle"
          data-day="{{ wh.day_of_week }}"
        >
        <span class="font-medium text-ink">{{ wh.day_name }}</span>
      </label>

      <div
        class="flex flex-1 flex-wrap items-center gap-3"
        id="day-{{ wh.day_of_week }}-times"
      >
        <input
          type="time"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_start"
          value="{{ day_start }}"
          class="field-input w-32"
          {{ 'disabled' if not day_enabled }}
        >

        <span class="text-ink-faint">to</span>

        <input
          type="time"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_end"
          value="{{ day_end }}"
          class="field-input w-32"
          {{ 'disabled' if not day_enabled }}
        >
      </div>
    </div>'''

if old_tmpl not in tmpl:
    print("ERROR: availability.html doesn't match expected content — template "
          "not patched. File may already be patched or has diverged.", file=sys.stderr)
    sys.exit(1)

tmpl = tmpl.replace(old_tmpl, new_tmpl, 1)
with open(tmpl_path, "w", encoding="utf-8") as f:
    f.write(tmpl)
print("Patched", tmpl_path)
PYEOF

python3 -m py_compile "$ROUTE"
echo "Syntax OK"

echo "Restarting $SERVICE..."
sudo systemctl restart "$SERVICE"
sudo systemctl --no-pager status "$SERVICE" | head -5

echo "Done. Backups: $ROUTE.bak.$ts / $TEMPLATE.bak.$ts"
