"""Authentication + profile/alert preferences."""
from flask import (Blueprint, render_template, redirect, url_for, request,
                   flash, abort, current_app)
from flask_login import login_user, logout_user, login_required, current_user
from ..extensions import db
from ..models import User
from ..services.geo import to_float

bp = Blueprint("auth", __name__)


@bp.route("/register", methods=["GET", "POST"])
def register():
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))
    if request.method == "POST":
        # honeypot anti-spam
        if request.form.get("website"):
            abort(400)
        email = (request.form.get("email") or "").strip().lower()
        username = (request.form.get("username") or "").strip()
        pw = request.form.get("password") or ""
        if not (email and username and len(pw) >= 8):
            flash("Email, username and an 8+ char password are required.", "error")
            return render_template("auth/register.html")
        if not request.form.get("consent"):
            flash("Please accept the Terms and Privacy Policy to register.", "error")
            return render_template("auth/register.html")
        if User.query.filter((User.email == email) | (User.username == username)).first():
            flash("Email or username already in use.", "error")
            return render_template("auth/register.html")
        from ..models import utcnow
        u = User(email=email, username=username, consented_at=utcnow())
        u.set_password(pw)
        db.session.add(u)
        db.session.commit()
        login_user(u)
        flash("Welcome aboard. Add your location to receive local alerts.", "success")
        return redirect(url_for("auth.profile"))
    return render_template("auth/register.html")


@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))
    if request.method == "POST":
        email = (request.form.get("email") or "").strip().lower()
        pw = request.form.get("password") or ""
        u = User.query.filter_by(email=email).first()
        if not u or not u.check_password(pw):
            flash("Invalid credentials.", "error")
            return render_template("auth/login.html")
        if u.is_banned:
            flash("This account is suspended.", "error")
            return render_template("auth/login.html")
        login_user(u, remember=True)
        nxt = request.args.get("next")
        return redirect(nxt or url_for("main.dashboard"))
    return render_template("auth/login.html")


@bp.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("main.index"))


@bp.route("/profile", methods=["GET", "POST"])
@login_required
def profile():
    if request.method == "POST":
        u = current_user
        u.city = (request.form.get("city") or "").strip() or None
        u.region = (request.form.get("region") or "").strip() or None
        u.country = (request.form.get("country") or "").strip() or None
        for fld in ("lat", "lng", "alert_radius_miles"):
            setattr(u, fld, to_float(request.form.get(fld)))
        u.alerts_opt_in = bool(request.form.get("alerts_opt_in"))
        db.session.commit()
        flash("Profile updated.", "success")
        return redirect(url_for("auth.profile"))
    return render_template("auth/profile.html")


@bp.route("/change-email", methods=["POST"])
@login_required
def change_email():
    pw = request.form.get("current_password") or ""
    new = (request.form.get("new_email") or "").strip().lower()
    if not current_user.check_password(pw):
        flash("Current password is incorrect.", "error")
    elif "@" not in new or "." not in new:
        flash("Enter a valid email address.", "error")
    elif User.query.filter(User.email == new, User.id != current_user.id).first():
        flash("That email is already in use.", "error")
    else:
        current_user.email = new
        db.session.commit()
        flash("Email address updated.", "success")
    return redirect(url_for("auth.profile"))


@bp.route("/change-password", methods=["POST"])
@login_required
def change_password():
    pw = request.form.get("current_password") or ""
    new = request.form.get("new_password") or ""
    if not current_user.check_password(pw):
        flash("Current password is incorrect.", "error")
    elif len(new) < 8:
        flash("New password must be at least 8 characters.", "error")
    else:
        current_user.set_password(new)
        db.session.commit()
        flash("Password updated.", "success")
    return redirect(url_for("auth.profile"))


@bp.route("/forgot", methods=["GET", "POST"])
def forgot():
    if current_user.is_authenticated:
        return redirect(url_for("auth.profile"))
    if request.method == "POST":
        import secrets
        from datetime import timedelta
        from ..models import PasswordReset, utcnow
        from ..services.mailer import send_email
        email = (request.form.get("email") or "").strip().lower()
        user = User.query.filter_by(email=email).first()
        if user:
            token = secrets.token_urlsafe(32)
            db.session.add(PasswordReset(user_id=user.id, token=token,
                                         expires_at=utcnow() + timedelta(hours=1)))
            db.session.commit()
            link = (current_app.config["PUBLIC_BASE_URL"].rstrip("/")
                    + url_for("auth.reset", token=token))
            from ..services import reset_email_html
            send_email(
                user.email, "Reset your MotoGuard password",
                reset_email_html(link),
                f"Reset your MotoGuard password using this link (expires in 1 hour):\n{link}")
        flash("If that email is registered, a reset link is on its way.", "success")
        return redirect(url_for("auth.login"))
    return render_template("auth/forgot.html")


@bp.route("/reset/<token>", methods=["GET", "POST"])
def reset(token):
    from ..models import PasswordReset
    pr = PasswordReset.query.filter_by(token=token).first()
    if not pr or not pr.is_valid():
        flash("That reset link is invalid or has expired.", "error")
        return redirect(url_for("auth.forgot"))
    if request.method == "POST":
        new = request.form.get("new_password") or ""
        if len(new) < 8:
            flash("Password must be at least 8 characters.", "error")
            return render_template("auth/reset.html", token=token)
        user = db.session.get(User, pr.user_id)
        user.set_password(new)
        pr.used = True
        db.session.commit()
        flash("Password reset. You can log in now.", "success")
        return redirect(url_for("auth.login"))
    return render_template("auth/reset.html", token=token)


@bp.route("/export")
@login_required
def export_data():
    """Right of access / portability — download everything we hold as JSON."""
    import json
    from flask import Response
    from ..services.gdpr import export_user_data
    data = json.dumps(export_user_data(current_user), indent=2, ensure_ascii=False)
    return Response(
        data, mimetype="application/json",
        headers={"Content-Disposition": "attachment; filename=motoguard-my-data.json"})


@bp.route("/delete-account", methods=["POST"])
@login_required
def delete_account():
    """Right to erasure — verify password, wipe the account, log out."""
    pw = request.form.get("current_password") or ""
    if not current_user.check_password(pw):
        flash("Password incorrect — account not deleted.", "error")
        return redirect(url_for("auth.profile"))
    if request.form.get("confirm") != "DELETE":
        flash("Type DELETE to confirm account deletion.", "error")
        return redirect(url_for("auth.profile"))
    from ..services.gdpr import delete_user
    user = current_user._get_current_object()
    logout_user()
    delete_user(user)
    flash("Your account and personal data have been permanently deleted.", "success")
    return redirect(url_for("main.index"))
