import re
import json
from flask import render_template, redirect, url_for, flash, request, current_app, session
from flask_login import login_user, logout_user, login_required, current_user

from app.auth import auth_bp
from app.auth.tokens import generate_reset_token, verify_reset_token
from app.auth.mailer import send_email
from app.extensions import db, limiter
from app.models.user import User, SupportAuditLog
from app.utils import (
    generate_user_id,
    generate_support_id,
    generate_api_identifier,
    generate_recovery_pin,
    generate_temp_password,
    generate_totp_secret,
    generate_backup_codes,
    encrypt_secret,
    decrypt_secret,
    hash_secret,
    verify_secret,
)

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _link_purchases_to_account(user):
    """Any license bought with this email before they had an account (or
    from a different account context) gets linked automatically - this is
    what makes purchases 'just show up' in the portal with no claim step.

    Gated on email_verified: without this check, registering with someone
    else's email would auto-link THEIR future purchases to the attacker's
    account before the real owner ever signs up. Verification is what
    makes trusting the email match here actually safe."""
    if not user.email_verified:
        return
    from app.models.developer import License
    License.query.filter_by(customer_email=user.email, customer_user_id=None).update(
        {"customer_user_id": user.id}
    )
    db.session.commit()


def _send_verification_email(user):
    from app.auth.tokens import generate_verify_email_token
    token = generate_verify_email_token(user.id, user.email)
    verify_url = url_for("auth.verify_email", token=token, _external=True)
    send_email(
        to=user.email,
        subject=f"Verify your email — {current_app.config['SITE_NAME']}",
        body=(
            f"Hi {user.username},\n\n"
            f"Confirm this is your email address so purchases made with it "
            f"show up in your account automatically:\n\n{verify_url}\n\n"
            "This link expires in 24 hours. If you didn't create this account, "
            "you can ignore this email."
        ),
    )


def _unique_user_id():
    while True:
        candidate = generate_user_id()
        if not User.query.filter_by(user_id=candidate).first():
            return candidate


def _unique_support_id():
    while True:
        candidate = generate_support_id()
        if not User.query.filter_by(support_id=candidate).first():
            return candidate


def _unique_api_identifier():
    while True:
        candidate = generate_api_identifier()
        if not User.query.filter_by(api_identifier=candidate).first():
            return candidate


# ---------------------------------------------------------------- register
@auth_bp.route("/register", methods=["GET", "POST"])
@limiter.limit("10 per hour")
def register():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        confirm = request.form.get("confirm_password", "")

        errors = []
        if not (3 <= len(username) <= 64):
            errors.append("Username must be between 3 and 64 characters.")
        if not EMAIL_RE.match(email):
            errors.append("Enter a valid email address.")
        if len(password) < 10:
            errors.append("Password must be at least 10 characters.")
        if password != confirm:
            errors.append("Passwords do not match.")
        if User.query.filter_by(username=username).first():
            errors.append("That username is already taken.")
        if User.query.filter_by(email=email).first():
            errors.append("An account with that email already exists.")

        if errors:
            for e in errors:
                flash(e, "error")
            return render_template("auth/register.html", username=username, email=email)

        recovery_pin_raw = generate_recovery_pin()

        user = User(
            user_id=_unique_user_id(),
            support_id=_unique_support_id(),
            api_identifier=_unique_api_identifier(),
            username=username,
            email=email,
            password_hash=hash_secret(password),
            recovery_pin_hash=hash_secret(recovery_pin_raw),
        )
        db.session.add(user)
        db.session.commit()

        _send_verification_email(user)
        _link_purchases_to_account(user)  # no-op until they verify - see the gate above

        login_user(user)

        # Recovery PIN is shown exactly once, right after creation.
        return render_template(
            "auth/registration_complete.html",
            user=user,
            recovery_pin=recovery_pin_raw,
        )

    return render_template("auth/register.html")


# ------------------------------------------------------------------- login
@auth_bp.route("/login", methods=["GET", "POST"])
@limiter.limit("20 per hour")
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        remember = bool(request.form.get("remember"))

        user = User.query.filter_by(email=email).first()

        if not user or not verify_secret(password, user.password_hash):
            flash("Incorrect email or password.", "error")
            return render_template("auth/login.html", email=email)

        if user.is_suspended:
            flash("This account has been suspended. Contact support.", "error")
            return render_template("auth/login.html", email=email)

        if user.totp_enabled:
            # Don't log in yet - stash a pending identity in the session
            # and require a second factor first.
            session["pending_2fa_user_id"] = user.id
            session["pending_2fa_remember"] = remember
            session["pending_2fa_next"] = request.args.get("next")
            return redirect(url_for("auth.verify_2fa"))

        from datetime import datetime, timezone

        user.last_login_at = datetime.now(timezone.utc)
        user.last_login_ip = request.remote_addr
        db.session.commit()

        _link_purchases_to_account(user)

        login_user(user, remember=remember)
        next_url = request.args.get("next")
        return redirect(next_url or url_for("dashboard.index"))

    return render_template("auth/login.html")


@auth_bp.route("/login/2fa", methods=["GET", "POST"])
@limiter.limit("15 per hour")
def verify_2fa():
    import pyotp

    user_id = session.get("pending_2fa_user_id")
    if not user_id:
        return redirect(url_for("auth.login"))

    user = User.query.get(user_id)
    if not user or not user.totp_enabled:
        session.pop("pending_2fa_user_id", None)
        return redirect(url_for("auth.login"))

    if request.method == "POST":
        code = request.form.get("code", "").strip()

        valid = False
        if user.totp_secret_encrypted:
            secret = decrypt_secret(user.totp_secret_encrypted)
            valid = pyotp.TOTP(secret).verify(code.replace(" ", ""), valid_window=1)

        # Fall back to a backup code (single use - consumed on success).
        if not valid and user.backup_codes_hashed:
            hashes = json.loads(user.backup_codes_hashed)
            for i, h in enumerate(hashes):
                if verify_secret(code.upper(), h):
                    valid = True
                    hashes.pop(i)
                    user.backup_codes_hashed = json.dumps(hashes)
                    break

        if not valid:
            flash("Invalid code. Try again.", "error")
            return render_template("auth/verify_2fa.html")

        from datetime import datetime, timezone

        user.last_login_at = datetime.now(timezone.utc)
        user.last_login_ip = request.remote_addr
        db.session.commit()

        _link_purchases_to_account(user)

        remember = session.pop("pending_2fa_remember", False)
        next_url = session.pop("pending_2fa_next", None)
        session.pop("pending_2fa_user_id", None)

        login_user(user, remember=remember)
        return redirect(next_url or url_for("dashboard.index"))

    return render_template("auth/verify_2fa.html")


@auth_bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("You've been logged out.", "info")
    return redirect(url_for("auth.login"))


# ------------------------------------------------------- forgot / reset pw
@auth_bp.route("/forgot-password", methods=["GET", "POST"])
@limiter.limit("5 per hour")
def forgot_password():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        user = User.query.filter_by(email=email).first()

        # Always show the same message, whether or not the account exists,
        # so the form can't be used to enumerate registered emails.
        if user:
            token = generate_reset_token(user.id)
            reset_url = url_for("auth.reset_password", token=token, _external=True)
            send_email(
                to=user.email,
                subject=f"Reset your {current_app.config['SITE_NAME']} password",
                body=(
                    f"Hi {user.username},\n\n"
                    f"Click the link below to reset your password. This link expires in "
                    f"{current_app.config['RESET_TOKEN_MAX_AGE'] // 60} minutes.\n\n"
                    f"{reset_url}\n\n"
                    "If you didn't request this, you can ignore this email."
                ),
            )

        flash("If that email is registered, a reset link has been sent.", "info")
        return redirect(url_for("auth.login"))

    return render_template("auth/forgot_password.html")


@auth_bp.route("/reset-password/<token>", methods=["GET", "POST"])
def reset_password(token):
    user_id, error = verify_reset_token(token)

    if error == "expired":
        flash("That reset link has expired. Request a new one.", "error")
        return redirect(url_for("auth.forgot_password"))
    if error == "invalid" or not user_id:
        flash("That reset link is invalid.", "error")
        return redirect(url_for("auth.forgot_password"))

    user = User.query.get(user_id)
    if not user:
        flash("That reset link is invalid.", "error")
        return redirect(url_for("auth.forgot_password"))

    if request.method == "POST":
        password = request.form.get("password", "")
        confirm = request.form.get("confirm_password", "")

        if len(password) < 10:
            flash("Password must be at least 10 characters.", "error")
            return render_template("auth/reset_password.html", token=token)
        if password != confirm:
            flash("Passwords do not match.", "error")
            return render_template("auth/reset_password.html", token=token)

        user.password_hash = hash_secret(password)
        db.session.commit()
        flash("Your password has been reset. Log in with your new password.", "success")
        return redirect(url_for("auth.login"))

    return render_template("auth/reset_password.html", token=token)


# ------------------------------------------------------- recovery pin mgmt
@auth_bp.route("/settings/recovery-pin/reset", methods=["POST"])
@login_required
def reset_recovery_pin():
    """Lets a logged-in user regenerate their recovery PIN. Old PIN is
    invalidated immediately; new one is shown exactly once."""
    new_pin = generate_recovery_pin()
    current_user.recovery_pin_hash = hash_secret(new_pin)
    db.session.commit()
    return render_template("auth/recovery_pin_reset.html", recovery_pin=new_pin)


# --------------------------------------------------- support account tools
def _require_support():
    if not (current_user.is_authenticated and (current_user.is_support or current_user.is_admin)):
        flash("Support access required.", "error")
        return False
    return True


@auth_bp.route("/support/lookup", methods=["GET", "POST"])
@login_required
def support_lookup():
    """Support staff look up an account by Support ID + the customer's
    recovery PIN to verify ownership, then can issue a temporary password.
    Passwords and recovery PINs themselves are never shown to support."""
    if not _require_support():
        return redirect(url_for("dashboard.index"))

    result = None
    if request.method == "POST":
        support_id = request.form.get("support_id", "").strip().upper()
        recovery_pin = request.form.get("recovery_pin", "").strip()

        user = User.query.filter_by(support_id=support_id).first()

        if not user or not verify_secret(recovery_pin, user.recovery_pin_hash):
            flash("Support ID / recovery PIN did not match any account.", "error")
        else:
            log = SupportAuditLog(
                support_user_id=current_user.id,
                target_user_id=user.id,
                action="lookup",
            )
            db.session.add(log)
            db.session.commit()
            result = user

    return render_template("auth/support_lookup.html", result=result)


@auth_bp.route("/support/issue-temp-password/<int:user_id>", methods=["POST"])
@login_required
def issue_temp_password(user_id):
    if not _require_support():
        return redirect(url_for("dashboard.index"))

    user = User.query.get_or_404(user_id)
    temp_password = generate_temp_password()
    user.password_hash = hash_secret(temp_password)

    log = SupportAuditLog(
        support_user_id=current_user.id,
        target_user_id=user.id,
        action="temp_password_issued",
    )
    db.session.add(log)
    db.session.commit()

    flash(f"Temporary password issued for {user.username}.", "success")
    return render_template("auth/temp_password_issued.html", user=user, temp_password=temp_password)


# ------------------------------------------------------------------- 2FA
@auth_bp.route("/settings/2fa/setup", methods=["GET", "POST"])
@login_required
def setup_2fa():
    import pyotp

    if current_user.totp_enabled:
        flash("2FA is already enabled. Disable it first to set up a new device.", "info")
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        code = request.form.get("code", "").strip()
        pending_secret = session.get("pending_totp_secret")

        if not pending_secret:
            flash("Setup session expired. Start again.", "error")
            return redirect(url_for("auth.setup_2fa"))

        if not pyotp.TOTP(pending_secret).verify(code.replace(" ", ""), valid_window=1):
            flash("That code didn't match. Check your authenticator app and try again.", "error")
            return render_template("auth/setup_2fa.html", secret=pending_secret, otpauth_url=_otpauth_url(pending_secret))

        raw_codes = generate_backup_codes()
        current_user.totp_secret_encrypted = encrypt_secret(pending_secret)
        current_user.totp_enabled = True
        current_user.backup_codes_hashed = json.dumps([hash_secret(c) for c in raw_codes])
        db.session.commit()

        session.pop("pending_totp_secret", None)
        return render_template("auth/backup_codes_shown.html", codes=raw_codes)

    pending_secret = generate_totp_secret()
    session["pending_totp_secret"] = pending_secret
    return render_template("auth/setup_2fa.html", secret=pending_secret, otpauth_url=_otpauth_url(pending_secret))


def _otpauth_url(secret):
    import pyotp
    issuer = current_app.config["SITE_NAME"]
    return pyotp.totp.TOTP(secret).provisioning_uri(name=current_user.email, issuer_name=issuer)


@auth_bp.route("/settings/2fa/disable", methods=["POST"])
@login_required
def disable_2fa():
    password = request.form.get("password", "")
    if not verify_secret(password, current_user.password_hash):
        flash("Incorrect password.", "error")
        return redirect(url_for("dashboard.index"))

    current_user.totp_enabled = False
    current_user.totp_secret_encrypted = None
    current_user.backup_codes_hashed = None
    db.session.commit()
    flash("2FA disabled.", "info")
    return redirect(url_for("dashboard.index"))


@auth_bp.route("/settings/2fa/regenerate-backup-codes", methods=["POST"])
@login_required
def regenerate_backup_codes():
    if not current_user.totp_enabled:
        flash("Enable 2FA first.", "error")
        return redirect(url_for("dashboard.index"))

    raw_codes = generate_backup_codes()
    current_user.backup_codes_hashed = json.dumps([hash_secret(c) for c in raw_codes])
    db.session.commit()
    return render_template("auth/backup_codes_shown.html", codes=raw_codes)


@auth_bp.route("/settings/password", methods=["GET", "POST"])
@login_required
def change_password():
    if request.method == "POST":
        current_password = request.form.get("current_password", "")
        new_password = request.form.get("new_password", "")
        confirm_password = request.form.get("confirm_password", "")

        if not verify_secret(current_password, current_user.password_hash):
            flash("Current password is incorrect.", "error")
            return render_template("auth/change_password.html")

        if len(new_password) < 10:
            flash("New password must be at least 10 characters.", "error")
            return render_template("auth/change_password.html")

        if new_password != confirm_password:
            flash("New passwords do not match.", "error")
            return render_template("auth/change_password.html")

        if verify_secret(new_password, current_user.password_hash):
            flash("New password must be different from your current password.", "error")
            return render_template("auth/change_password.html")

        current_user.password_hash = hash_secret(new_password)
        db.session.commit()
        flash("Password changed.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("auth/change_password.html")


@auth_bp.route("/settings/delete-account", methods=["GET", "POST"])
@login_required
def delete_account():
    from app.models.developer import Product, TeamMember, License, WorkspaceActivityLog, DeveloperProfile
    from app.models.portal import FivemServer

    # Block deletion if it would orphan anyone depending on this account -
    # customers with licenses tied to a product this person owns, or
    # teammates in a workspace they own. Erasing yourself shouldn't be
    # able to break someone else's paying customers or team.
    owns_products = Product.query.filter_by(developer_id=current_user.id).count() > 0
    owns_team = TeamMember.query.filter_by(developer_id=current_user.id).count() > 0

    if request.method == "POST":
        if owns_products or owns_team:
            flash(
                "You own a developer workspace with products or team members - "
                "deleting your account would break things for your customers or "
                "team. Contact support to transfer or wind down your workspace first.",
                "error",
            )
            return redirect(url_for("dashboard.index"))

        password = request.form.get("password", "")
        confirm_text = request.form.get("confirm_text", "")

        if not verify_secret(password, current_user.password_hash):
            flash("Incorrect password.", "error")
            return render_template("auth/delete_account.html", owns_products=owns_products, owns_team=owns_team)

        if confirm_text.strip().upper() != "DELETE":
            flash('Type "DELETE" to confirm.', "error")
            return render_template("auth/delete_account.html", owns_products=owns_products, owns_team=owns_team)

        user_id = current_user.id

        # Servers they own (and attached licenses) go with them.
        FivemServer.query.filter_by(owner_id=user_id).delete(synchronize_session=False)

        # Licenses stay - they're the developer's business record - but
        # unlink this account from them.
        License.query.filter_by(customer_user_id=user_id).update(
            {"customer_user_id": None}, synchronize_session=False
        )

        # Team memberships elsewhere, in either direction.
        TeamMember.query.filter_by(member_user_id=user_id).delete(synchronize_session=False)

        # Audit/activity trail referencing this account - can't leave these
        # as dangling foreign keys, and keeping a log entry about someone
        # who no longer exists isn't meaningful erasure.
        SupportAuditLog.query.filter_by(target_user_id=user_id).delete(synchronize_session=False)
        SupportAuditLog.query.filter_by(support_user_id=user_id).delete(synchronize_session=False)
        WorkspaceActivityLog.query.filter_by(actor_user_id=user_id).delete(synchronize_session=False)

        from app.models.user import AdminActionLog
        AdminActionLog.query.filter_by(admin_user_id=user_id).delete(synchronize_session=False)

        DeveloperProfile.query.filter_by(user_id=user_id).delete(synchronize_session=False)

        user = User.query.get(user_id)
        logout_user()
        db.session.delete(user)
        db.session.commit()

        flash("Your account has been deleted.", "info")
        return redirect(url_for("auth.login"))

    return render_template("auth/delete_account.html", owns_products=owns_products, owns_team=owns_team)


@auth_bp.route("/verify-email/<token>")
def verify_email(token):
    from app.auth.tokens import verify_verify_email_token

    user_id, email, error = verify_verify_email_token(token)

    if error == "expired":
        flash("That verification link expired. Log in and request a new one.", "error")
        return redirect(url_for("auth.login"))
    if error == "invalid" or not user_id:
        flash("That verification link is invalid.", "error")
        return redirect(url_for("auth.login"))

    user = User.query.get(user_id)
    if not user or user.email != email:
        flash("That verification link is invalid.", "error")
        return redirect(url_for("auth.login"))

    if not user.email_verified:
        user.email_verified = True
        db.session.commit()
        _link_purchases_to_account(user)  # now safe to trust - catches up on anything bought before verifying
        flash("Email verified. Any purchases made with this email now show up automatically.", "success")
    else:
        flash("Already verified.", "info")

    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))
    return redirect(url_for("auth.login"))


@auth_bp.route("/settings/resend-verification", methods=["POST"])
@login_required
def resend_verification():
    if current_user.email_verified:
        flash("Your email is already verified.", "info")
        return redirect(url_for("dashboard.index"))

    _send_verification_email(current_user)
    flash("Verification email sent.", "success")
    return redirect(url_for("dashboard.index"))
