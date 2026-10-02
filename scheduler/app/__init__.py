import os

from flask import Flask
from flask_login import LoginManager
from flask_migrate import Migrate
from flask_sqlalchemy import SQLAlchemy
from flask_wtf import CSRFProtect

from config import config_by_name

db = SQLAlchemy()
migrate = Migrate()
login_manager = LoginManager()
csrf = CSRFProtect()


def create_app(config_name=None):
    config_name = config_name or os.environ.get("FLASK_ENV", "development")

    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config_by_name[config_name])

    os.makedirs(app.instance_path, exist_ok=True)

    if config_name == "production":
        config_by_name["production"].validate()

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    csrf.init_app(app)

    from app.services.crypto import init_encryption
    init_encryption(app.instance_path)

    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please sign in to continue."
    login_manager.login_message_category = "info"

    from app import models  # noqa: F401 - ensures every model is registered before migrations run
    from app.models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    from app.routes.auth import auth_bp
    from app.routes.admin import admin_bp
    from app.routes.public import public_bp
    from app.routes.calendarmaker import calendarmaker_bp
    from app.routes.isp_support import isp_support_bp
    from app.routes.timeoff_share import timeoff_share_bp
    from app.routes.api import api_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(public_bp)
    app.register_blueprint(calendarmaker_bp)
    app.register_blueprint(isp_support_bp)
    app.register_blueprint(timeoff_share_bp)
    app.register_blueprint(api_bp)

    register_cli(app)
    register_error_handlers(app)

    @app.context_processor
    def inject_globals():
        return {"app_name": "Scheduler"}

    return app


def register_error_handlers(app):
    from flask import flash, redirect, render_template, request, url_for
    from flask_login import current_user
    from flask_wtf.csrf import CSRFError

    @app.errorhandler(404)
    def not_found(e):
        return render_template("errors/404.html"), 404

    @app.errorhandler(500)
    def server_error(e):
        return render_template("errors/500.html"), 500

    @app.errorhandler(CSRFError)
    def csrf_error(e):
        # Without this, Flask-WTF's default is a bare, unstyled "400 Bad
        # Request" page with no nav and no way back — indistinguishable from
        # the app being broken. This turns it into a normal flash message and
        # sends the person back to the page they were on, so a save that
        # fails because a session expired reads as "try that again", not
        # "the site is down".
        flash("Your session expired — please try that again.", "error")
        if current_user.is_authenticated:
            fallback = url_for("admin.dashboard")
        else:
            fallback = url_for("public.booking_types")
        return redirect(request.referrer or fallback)


def register_cli(app):
    import click

    @app.cli.command("create-admin")
    @click.option("--email", prompt=True)
    @click.option("--name", prompt=True)
    @click.option("--password", prompt=True, hide_input=True, confirmation_prompt=True)
    def create_admin(email, name, password):
        """Create the admin user (this app supports a single admin account)."""
        from app.models.user import User

        if User.query.filter_by(email=email.lower().strip()).first():
            click.echo(f"A user with email {email} already exists.")
            return

        user = User(email=email.lower().strip(), name=name)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        click.echo(f"Admin user '{name}' <{email}> created.")

    @app.cli.command("seed-review-account")
    @click.option("--email", required=True)
    @click.option("--password", required=True)
    def seed_review_account(email, password):
        """Create (or refresh) a demo account with fake bookings, for App Store review.

        A separate user, never the primary owner: its bookings don't appear on
        the public pages (those use User.get_primary()) and it has no Discord
        recipients, so nothing notifies the real owner. Re-run before each
        App Store submission to move the fake bookings to upcoming dates.
        """
        from datetime import datetime as dt, time, timedelta

        from app.models.booking import Booking, BookingType
        from app.models.time_off import TimeOff
        from app.models.user import User
        from app.services.availability import ensure_working_hours_rows

        email = email.lower().strip()
        primary = User.get_primary()
        user = User.query.filter_by(email=email).first()
        if user is not None and primary is not None and user.id == primary.id:
            raise click.ClickException("That's the primary owner account — refusing to fill it with demo data.")
        if primary is None:
            raise click.ClickException("Create the real admin first (flask create-admin); the demo account must not be the primary user.")

        if user is None:
            user = User(email=email, name="Alex Morgan", timezone=primary.timezone)
            db.session.add(user)
        user.set_password(password)
        db.session.commit()
        ensure_working_hours_rows(user)

        Booking.query.filter_by(user_id=user.id).delete()
        TimeOff.query.filter_by(user_id=user.id).delete()
        BookingType.query.filter_by(user_id=user.id).delete()
        db.session.commit()

        call = BookingType(user_id=user.id, name="Support Call", duration=30)
        visit = BookingType(user_id=user.id, name="Home Visit", duration=60)
        db.session.add_all([call, visit])
        db.session.commit()

        today = dt.now().date()

        def weekday(offset):
            d = today + timedelta(days=offset)
            while d.weekday() >= 5:
                d += timedelta(days=1)
            return d

        demo = [
            (0, 10, 0, call, "Priya Shah", "Router drops out every evening around 8pm.", "confirmed"),
            (0, 14, 30, visit, "Tom Becker", "New mesh Wi-Fi setup, three-bedroom house.", "confirmed"),
            (1, 9, 30, call, "Hannah Lee", None, "confirmed"),
            (2, 11, 0, visit, "Marcus Green", "Printer won't connect to the new network.", "confirmed"),
            (3, 15, 0, call, "Sofia Rossi", "Switching broadband provider — wants advice.", "confirmed"),
            (6, 10, 30, call, "James Carter", None, "confirmed"),
            (9, 13, 0, visit, "Aisha Khan", "Smart TV and soundbar setup.", "confirmed"),
            (4, 16, 0, call, "Daniel Wu", None, "cancelled"),
            (-3, 10, 0, call, "Emma Wilson", "Email not syncing on phone.", "completed"),
            (-2, 14, 0, visit, "Oliver Hughes", None, "completed"),
        ]
        for offset, h, m, bt, name, notes, status in demo:
            # Today's bookings stay on today even at weekends, so the reviewer always sees some.
            day = weekday(offset) if offset > 0 else today + timedelta(days=offset)
            start = dt.combine(day, time(h, m))
            db.session.add(Booking(
                user_id=user.id, booking_type_id=bt.id, name=name,
                email=name.split()[0].lower() + "@example.com",
                phone="07700 900" + str(100 + len(name)), notes=notes,
                start_datetime=start, end_datetime=start + timedelta(minutes=bt.duration), status=status,
                cancelled_at=dt.utcnow() if status == "cancelled" else None,
                # Mark every Discord flag as done so the bot never picks these up.
                discord_new_notified=True, discord_cancel_notified=True, discord_day_reminder_sent=True,
                discord_hour_reminder_sent=True, discord_15min_reminder_sent=True,
            ))
        off = weekday(12)
        db.session.add(TimeOff(user_id=user.id, start_datetime=dt.combine(off, time.min),
                               end_datetime=dt.combine(off + timedelta(days=2), time.max), all_day=True, reason="Holiday"))
        db.session.commit()
        click.echo(f"Review account {email} ready with {len(demo)} demo bookings.")

    @app.cli.command("discord-bootstrap")
    def discord_bootstrap():
        """Run once, right after deploying the Discord bot.

        Marks every existing booking as already-notified for the "new
        booking" DM, so the bot's first poll doesn't flood you with a DM
        for every booking that already existed. Bookings still get their
        day-start / 1-hour / 15-minute reminder DMs as normal — this only
        skips the one-off "new booking" ping for pre-existing bookings.
        """
        from app.models.booking import Booking

        updated_new = Booking.query.filter_by(discord_new_notified=False).update(
            {"discord_new_notified": True}, synchronize_session=False
        )
        updated_cancel = Booking.query.filter_by(discord_cancel_notified=False).update(
            {"discord_cancel_notified": True}, synchronize_session=False
        )
        db.session.commit()
        click.echo(f"Marked {updated_new} existing booking(s) as already-notified, {updated_cancel} as already-notified of cancellation.")
