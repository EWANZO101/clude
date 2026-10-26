import json
import os
import random
import urllib.error
import urllib.parse
import urllib.request
import uuid

from flask import Blueprint, abort, current_app, g, render_template, request, session

from .extensions import db, limiter
from . import realtime
from .models import CommunityRequest, CommunitySubmission

community_bp = Blueprint("community_public", __name__)

# Images and short clips a community member might realistically have on
# hand (a phone screenshot, a doorbell-cam export, a dashcam clip) - not
# the full matrix of video containers, to keep the upload surface narrow.
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".mp4", ".webm", ".mov"}


def _ext_ok(filename):
    _, ext = os.path.splitext(filename.lower())
    return ext if ext in ALLOWED_EXTENSIONS else None


def _hcaptcha_configured():
    cfg = current_app.config
    return bool(cfg.get("HCAPTCHA_SITE_KEY")) and bool(cfg.get("HCAPTCHA_SECRET_KEY"))


def _new_math_challenge():
    """Session-backed fallback CAPTCHA used when no hCaptcha keys are
    configured - no external signup needed to get some bot resistance."""
    a, b = random.randint(2, 9), random.randint(2, 9)
    session["captcha_a"] = a
    session["captcha_b"] = b
    return a, b


def _verify_hcaptcha(token):
    if not token:
        return False
    secret = current_app.config.get("HCAPTCHA_SECRET_KEY")
    data = urllib.parse.urlencode({"secret": secret, "response": token}).encode()
    try:
        with urllib.request.urlopen("https://hcaptcha.com/siteverify", data=data, timeout=5) as resp:
            result = json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError, ValueError):
        current_app.logger.warning("hCaptcha verification request failed")
        return False
    return bool(result.get("success"))


def _verify_captcha():
    if _hcaptcha_configured():
        return _verify_hcaptcha(request.form.get("h-captcha-response"))

    try:
        expected = session.get("captcha_a", 0) + session.get("captcha_b", 0)
        given = int((request.form.get("captcha_answer") or "").strip())
    except (TypeError, ValueError):
        return False
    return given == expected


@community_bp.route("/report", methods=["GET", "POST"])
@limiter.limit("8 per hour", methods=["POST"])
def report_general():
    """The permanent, no-account tip line linked from the homepage - unlike
    /r/<code>, this doesn't need an officer to generate anything first.

    Tenant-aware: on a community's own subdomain/custom domain (g.tenant
    set by tenant_resolve.py), this is that community's own tip line, a
    separate CommunityRequest row (community_id=g.tenant.id) from the
    control-plane site's own (community_id=None). Lazily created on first
    visit rather than at community-creation time, so a community created
    before this existed still gets one automatically."""
    req = CommunityRequest.query.filter_by(is_general=True, community_id=g.tenant.id if g.tenant else None).first()
    if req is None:
        if g.tenant is None:
            abort(404)
        req = CommunityRequest(
            reference_code=CommunityRequest.generate_reference_code(),
            title="Report evidence or a tip",
            category="General",
            requires_consent=True,
            is_general=True,
            community_id=g.tenant.id,
        )
        db.session.add(req)
        db.session.commit()
    return _render_submit(req)


@community_bp.route("/r/<code>", methods=["GET", "POST"])
@limiter.limit("8 per hour", methods=["POST"])
def submit(code):
    """Public, unauthenticated - the per-case link an investigator
    generates and shares with whoever they're asking for evidence/tips
    from. No portal account needed, matching Axon's community-member
    flow."""
    req = CommunityRequest.query.filter_by(reference_code=code).first()
    if req is None:
        abort(404)
    return _render_submit(req)


def _render_submit(req):
    """Shared GET/POST handling for both /report and /r/<code> - rate-
    limited per IP on POST by the route decorators above, and gated by a
    CAPTCHA (hCaptcha if configured, else a built-in math challenge) on
    top of the honeypot field below."""
    error = None
    done = False

    if request.method == "POST":
        # Honeypot - a real visitor never sees or fills this hidden field.
        # Pretend success without saving anything.
        if (request.form.get("website") or "").strip():
            done = True
        elif req.status != "open":
            error = "This request is no longer accepting submissions."
        elif not _verify_captcha():
            error = "That CAPTCHA wasn't right - try again."
        elif req.requires_consent and not request.form.get("consent"):
            error = "You need to agree to the consent statement to submit."
        else:
            message = (request.form.get("message") or "").strip()
            external_link = (request.form.get("external_link") or "").strip()
            upload = request.files.get("file")

            file_path = ""
            file_original_name = ""
            if upload and upload.filename:
                ext = _ext_ok(upload.filename)
                if ext is None:
                    error = "That file type isn't supported - use an image (jpg/png/webp) or a short video (mp4/webm/mov)."
                else:
                    folder = os.path.join(current_app.instance_path, "community_uploads", req.reference_code)
                    os.makedirs(folder, exist_ok=True)
                    stored_name = f"{uuid.uuid4().hex}{ext}"
                    upload.save(os.path.join(folder, stored_name))
                    file_path = os.path.join(req.reference_code, stored_name)
                    file_original_name = upload.filename[:255]

            if error is None and not message and not external_link and not file_path:
                error = "Add a message, a link to footage, or upload a file - at least one is required."

            if error is None:
                submission = CommunitySubmission(
                    request_id=req.id,
                    submitter_name=(request.form.get("submitter_name") or "").strip()[:128],
                    submitter_contact=(request.form.get("submitter_contact") or "").strip()[:128],
                    store_contact_consent=bool(request.form.get("store_contact_consent")),
                    consent_given=bool(request.form.get("consent")),
                    message=message[:4000],
                    external_link=external_link[:1024],
                    file_path=file_path,
                    file_original_name=file_original_name,
                )
                db.session.add(submission)
                db.session.commit()
                realtime.publish(
                    "submission.created",
                    submission={"id": submission.id, "requestId": req.id, "requestTitle": req.title},
                )
                done = True

    hcaptcha_site_key = None
    captcha_a = captcha_b = None
    if _hcaptcha_configured():
        hcaptcha_site_key = current_app.config.get("HCAPTCHA_SITE_KEY")
    else:
        captcha_a, captcha_b = _new_math_challenge()

    agency_name = current_app.config.get("AGENCY_NAME", "")
    if agency_name == "Unconfigured Agency":
        agency_name = ""  # placeholder default - don't show it on a public-facing page

    return render_template(
        "community_public.html",
        req=req,
        done=done,
        error=error,
        hcaptcha_site_key=hcaptcha_site_key,
        captcha_a=captcha_a,
        captcha_b=captcha_b,
        agency_name=agency_name,
    )
