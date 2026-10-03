"""SSO login flow:  /auth/sso/<provider>  ->  /auth/sso/<provider>/callback"""
import secrets
from urllib.parse import urlparse

from flask import (redirect, url_for, request, flash, session, current_app)
from flask_login import login_user

from . import sso_bp, oauth, ENABLED
from .providers import PROVIDERS, parse_identity
from .. import db
from ..models import User
from ..models_business import OAuthAccount, AuditLog


def _safe_next(target):
    if target and target.startswith("/") and not target.startswith("//"):
        return target
    return None


@sso_bp.route("/<provider>")
def start(provider):
    if provider not in ENABLED:
        flash("That sign-in method isn't available.", "error")
        return redirect(url_for("auth.login"))
    client = oauth.create_client(provider)
    if client is None:
        flash("That sign-in method isn't configured.", "error")
        return redirect(url_for("auth.login"))
    nxt = _safe_next(request.args.get("next"))
    if nxt:
        session["sso_next"] = nxt
    redirect_uri = url_for("sso.callback", provider=provider, _external=True)
    return client.authorize_redirect(redirect_uri)


@sso_bp.route("/<provider>/callback")
def callback(provider):
    if provider not in ENABLED:
        flash("That sign-in method isn't available.", "error")
        return redirect(url_for("auth.login"))
    client = oauth.create_client(provider)
    try:
        token = client.authorize_access_token()
    except Exception:
        flash("Sign-in was cancelled or failed. Please try again.", "error")
        return redirect(url_for("auth.login"))

    # ---- fetch userinfo ----
    meta = ENABLED[provider]
    userinfo = None
    if meta.get("kind") == "oidc" or provider == "oidc":
        userinfo = token.get("userinfo")
        if not userinfo:
            try:
                userinfo = client.userinfo()
            except Exception:
                userinfo = None
    else:
        try:
            resp = client.get(PROVIDERS[provider]["userinfo"], token=token)
            userinfo = resp.json()
        except Exception:
            userinfo = None
        # GitHub can hide the email — pull the primary verified one
        if provider == "github" and userinfo is not None and not userinfo.get("email"):
            try:
                emails = client.get(PROVIDERS[provider]["emails_url"], token=token).json()
                primary = next((e for e in emails if e.get("primary") and e.get("verified")), None)
                if primary:
                    userinfo["email"] = primary.get("email")
            except Exception:
                pass

    sub, email, name = parse_identity(provider if provider in PROVIDERS else "oidc", userinfo)
    if not sub:
        flash("Couldn't read your account from that provider.", "error")
        return redirect(url_for("auth.login"))

    # ---- find or create the user ----
    link = OAuthAccount.query.filter_by(provider=provider, sub=sub).first()
    user = link.user if link else None

    if user is None and email:
        user = User.query.filter(db.func.lower(User.email) == email.lower()).first()

    if user is None:
        if not email:
            flash("That provider didn't share an email, so we can't create an account.", "error")
            return redirect(url_for("auth.login"))
        user = User(
            username=_unique_username(email, name),
            email=email,
            role="user",
            is_active=True,
        )
        user.set_password(secrets.token_urlsafe(24))  # random; they log in via SSO
        db.session.add(user)
        db.session.flush()

    if link is None:
        db.session.add(OAuthAccount(provider=provider, sub=sub, user_id=user.id, email=email))

    if not user.is_active:
        flash("Your account is disabled. Please contact support.", "error")
        return redirect(url_for("auth.login"))

    db.session.commit()
    try:
        AuditLog.log("auth.sso_login", actor=user, target_type="user", target_id=user.id,
                     meta={"provider": provider}, ip=request.remote_addr)
        db.session.commit()
    except Exception:
        db.session.rollback()

    login_user(user, remember=True)
    nxt = _safe_next(session.pop("sso_next", None))
    dest = nxt or (url_for("portal.dashboard") if _has_portal() else url_for("main.index"))
    return redirect(dest)


def _has_portal():
    return "portal.dashboard" in current_app.view_functions


def _unique_username(email, name):
    base = (email.split("@")[0] if email else (name or "user")).strip().lower()
    base = "".join(c for c in base if c.isalnum() or c in "._-") or "user"
    base = base[:50]
    candidate = base
    n = 1
    while User.query.filter_by(username=candidate).first():
        n += 1
        candidate = f"{base}{n}"
    return candidate
