# Scheduler — Complete (Phases 1–6)

Self-hosted scheduling/booking app. Every phase from the original plan is
built and tested: foundation, the availability engine, bookings, email
notifications, the public status page, and the admin calendar.

## What's new: the admin calendar

- `/admin/calendar` — a month view of working days, breaks, time off, and
  bookings, built entirely by *reading* the availability engine, time off,
  and bookings — per the plan, "the calendar should NOT be the source of
  truth for availability," so nothing here computes availability
  independently.
- **Desktop/tablet**: a traditional 7-column month grid, with each day
  showing whether it's a working day, a time-off chip, and up to 2 booking
  chips with a "+N more" overflow indicator.
- **Mobile**: the same underlying day data renders as a scrollable agenda
  list instead — one card per day with working hours, time off, and every
  booking listed in full (no truncation, since a list doesn't need it).
  Both views come from one `build_month_grid()` call; only the CSS
  (`hidden lg:block` vs `lg:hidden`) decides which renders.
- Month navigation (prev/today/next) preserves state via `?year=&month=`
  query params — verified across several edge-case months (a leap
  February, months that need 5 vs 6 grid rows) to make sure the grid math
  produces exactly the right number of in-month days every time.

## Setup

```bash
# 1. Python environment
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 2. Environment variables
cp .env.example .env
# edit .env — at minimum set a real SECRET_KEY
# for real email delivery, also set MAIL_SERVER/MAIL_PORT/MAIL_USERNAME/
# MAIL_PASSWORD/MAIL_FROM and set MAIL_SUPPRESS_SEND=false

# 3. Frontend build (only needed if you edit app/static/css/input.css)
npm install
npm run build:css                  # one-off build
npm run watch:css                  # rebuild on change, while developing

# 4. Database
export FLASK_APP=run.py            # Windows (PowerShell): $env:FLASK_APP="run.py"
flask db upgrade

# 5. Create your admin login
flask create-admin

# 6. Run
flask run
```

Visit `http://127.0.0.1:5000/auth/login` and sign in. Working hours default
to Mon–Fri 09:00–17:00 on first login. Create a booking type under Booking
Types. `http://127.0.0.1:5000/status` is the link to share or embed;
`http://127.0.0.1:5000/book` is the direct booking link; `/admin/calendar`
is where it all comes together visually.

## Project structure

```
app/
  models/
    user.py           User (single admin account)
    availability.py   WorkingHours, Break
    time_off.py        TimeOff
    settings.py        Settings (status override, notification prefs)
    booking.py          BookingType, Booking
  routes/
    auth.py    login/logout
    admin.py   everything under /admin
    public.py  /book, /status, /api/status, /widget.js — no login required
  services/
    security.py      login rate limiting
    availability.py  the availability engine
    status.py         current-status computation
    booking.py         slot generation + safe booking creation
    email.py            low-level SMTP sending / suppressed-send outbox
    notifications.py    booking events -> composed emails
    calendar.py          read-only month-grid summaries for the admin view
  templates/
    base.html                 bare HTML shell
    layouts/admin.html        sidebar layout
    auth/login.html
    admin/dashboard.html, availability.html, time_off.html,
          booking_types.html, edit_booking_type.html, bookings.html,
          settings.html, calendar.html
    public/booking_types.html, pick_slot.html, booking_details.html,
           confirmation.html, manage_booking.html, status.html
    email/booking_notification.html   shared layout for all email kinds
    partials/flash.html
    errors/404.html, 500.html
  static/
    css/input.css  Tailwind source — edit this
    css/main.css   built output — run npm run build:css after editing
    js/app.js      mobile nav toggle
    js/widget.js   embeddable status badge
config.py       Dev/Prod/Testing config classes
run.py          Entry point
migrations/     Alembic migration history
```

## Design notes

- `app/services/calendar.py` never queries or computes availability itself
  — it reads `WorkingHours`/`Break`/`TimeOff`/`Booking` directly for
  display, the same tables `app/services/availability.py` reads. If the
  two ever disagreed, that would be a display bug, not two different
  answers to "am I free" — there's only ever one place that question gets
  answered.
- The month grid always renders full weeks (Monday-start), including the
  leading/trailing days from adjacent months, so the grid never looks
  ragged. The mobile agenda filters those out (`if day.in_month`) since a
  list has no layout reason to show padding days.
- Booking chip truncation (`bookings[:2]` + "+N more") is a desktop-grid-
  only concern — cell height is fixed, so overflow has to be handled
  somehow. The mobile agenda has no such constraint and intentionally
  shows every booking in full.

## What's deliberately not here yet

Everything in the original PLAN's phased build-out (Phases 1–8, minus
deployment/Docker packaging which is a hosting concern outside this
codebase) is built. Items explicitly deferred to the plan's own FUTURE
FEATURES list remain out of scope: Google/Outlook calendar sync, recurring
availability, custom booking questions, SMS notifications, webhooks, a
public API, analytics, multi-user support, and automatic reminder emails.
