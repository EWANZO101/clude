"""Self-serve onboarding for a brand new FiveM community/server - distinct
from auth.signup, which adds an *officer* account to a community that
already exists. This is the other end: turning a stranger with no account
at all into a fresh Community (its own dedicated MySQL database - see
tenancy.py) plus a first admin account scoped to just that community.

Provisions a live database per submission, so this is rate-limited and
CAPTCHA-gated like community.py's public forms - without that, anyone could
script repeated POSTs here and exhaust MySQL connections/disk with empty
databases nobody will ever use.
"""

from flask import Blueprint, current_app, jsonify, redirect, render_template, request, url_for
from flask_login import current_user, login_required, login_user

from . import captcha, tenancy
from .audit import log_audit
from .extensions import db, limiter
from .models import ActiveRecorder, Community, Evidence, User

community_signup_bp = Blueprint("community_signup", __name__)


@community_signup_bp.route("/get-started", methods=["GET", "POST"])
@limiter.limit("5 per hour", methods=["POST"])
def new_community():
    if current_user.is_authenticated:
        return redirect(url_for("community_signup.integration"))

    mysql_enabled = bool(current_app.config.get("MYSQL_PROVISIONER_PASSWORD"))
    error = None

    if request.method == "POST":
        # Honeypot - a real visitor never sees or fills this hidden field.
        if (request.form.get("website") or "").strip():
            return redirect(url_for("site.welcome"))

        name = (request.form.get("name") or "").strip()
        slug = (request.form.get("slug") or "").strip()
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        confirm = request.form.get("confirm") or ""

        if not captcha.verify_captcha():
            error = "That CAPTCHA wasn't right - try again."
        elif not name:
            error = "Server/community name is required."
        elif len(username) < 3:
            error = "Admin username must be at least 3 characters."
        elif len(password) < 8:
            error = "Password must be at least 8 characters."
        elif password != confirm:
            error = "Passwords don't match."
        elif User.query.filter_by(username=username).first() is not None:
            error = "That username is already taken - pick another."

        if error is None:
            try:
                community = tenancy.create_community(name, requested_slug=slug or None)
            except tenancy.ProvisioningError as e:
                error = str(e)
            else:
                user = User(username=username, role="admin", community_id=community.id, is_active_account=True)
                user.set_password(password)
                db.session.add(user)
                log_audit("community.self_signup", f"{community.name} ({community.slug}) by {username}")
                db.session.commit()
                login_user(user)
                return redirect(url_for("community_signup.integration", just_created=1))

    hcaptcha_site_key = None
    captcha_a = captcha_b = None
    if captcha.hcaptcha_configured():
        hcaptcha_site_key = current_app.config.get("HCAPTCHA_SITE_KEY")
    else:
        captcha_a, captcha_b = captcha.new_math_challenge()

    return render_template(
        "community_signup.html",
        error=error,
        mysql_enabled=mysql_enabled,
        hcaptcha_site_key=hcaptcha_site_key,
        captcha_a=captcha_a,
        captcha_b=captcha_b,
    )


@community_signup_bp.route("/integration", methods=["GET", "POST"])
@login_required
def integration():
    if not current_user.community_id:
        return redirect(url_for("views.dashboard"))
    community = Community.query.get_or_404(current_user.community_id)
    tenant_base_domain = current_app.config.get("TENANT_BASE_DOMAIN", "")
    domain_error = None

    if request.method == "POST":
        if not current_user.is_admin:
            return redirect(url_for("community_signup.integration"))
        domain = (request.form.get("custom_domain") or "").strip().lower()
        if domain and not tenancy._DOMAIN_RE.match(domain):
            domain_error = f"'{domain}' doesn't look like a valid domain."
        elif domain and Community.query.filter(Community.custom_domain == domain, Community.id != community.id).first() is not None:
            domain_error = f"'{domain}' is already in use by another community."
        else:
            community.custom_domain = domain or None
            db.session.commit()
            log_audit("community.set_custom_domain", f"{community.name} ({community.slug}) -> {domain or '(cleared)'}")
            return redirect(url_for("community_signup.integration"))

    # Same check integration_status() polls - computed here too so the page's first paint already shows
    # the truth instead of a "waiting..." spinner that would otherwise flash on every reload of an
    # already-connected community until the JS poll below resolves a moment later.
    session = tenancy.get_tenant_session(community)
    evidence_count = session.query(Evidence).count()
    recorder_count = session.query(ActiveRecorder).count()
    connected = evidence_count > 0 or recorder_count > 0

    return render_template(
        "integration.html",
        community=community,
        just_created=request.args.get("just_created") == "1",
        tenant_base_domain=tenant_base_domain,
        can_manage=current_user.is_admin,
        domain_error=domain_error,
        connected=connected,
        evidence_count=evidence_count,
        recorder_count=recorder_count,
    )


@community_signup_bp.route("/integration/regenerate-token", methods=["POST"])
@login_required
def regenerate_token():
    if not current_user.community_id or not current_user.is_admin:
        return redirect(url_for("views.dashboard"))
    community = Community.query.get_or_404(current_user.community_id)
    tenancy.regenerate_token(community)
    log_audit("community.regenerate_token", f"{community.name} ({community.slug})")
    db.session.commit()
    return redirect(url_for("community_signup.integration"))


@community_signup_bp.route("/integration/status")
@login_required
def integration_status():
    """Polled by integration.html's setup checklist - reports whether this
    community's bodycam resource has actually reached the portal yet, by
    checking its own tenant database directly (tenancy.get_tenant_session),
    not g.tenant/g.tenant_session - this page is reached by a login-based
    admin on the portal's primary URL, which tenant_resolve.py only
    resolves to a subdomain/custom-domain request, not this one."""
    if not current_user.community_id:
        return jsonify({"error": "not a community account"}), 403
    community = Community.query.get_or_404(current_user.community_id)
    session = tenancy.get_tenant_session(community)

    evidence_count = session.query(Evidence).count()
    recorder_count = session.query(ActiveRecorder).count()
    last_recorder_seen = session.query(db.func.max(ActiveRecorder.last_seen_at)).scalar()
    last_evidence_received = session.query(db.func.max(Evidence.received_at)).scalar()

    connected = evidence_count > 0 or recorder_count > 0
    return jsonify(
        {
            "tokenConfigured": True,  # the token exists the moment the community does - nothing to check
            "connected": connected,
            "evidenceCount": evidence_count,
            "activeRecorders": recorder_count,
            "lastRecorderSeenAt": (last_recorder_seen.isoformat() + "Z") if last_recorder_seen else None,
            "lastEvidenceReceivedAt": (last_evidence_received.isoformat() + "Z") if last_evidence_received else None,
        }
    )
