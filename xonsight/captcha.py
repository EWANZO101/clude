"""Shared CAPTCHA helper for public, unauthenticated forms (community_signup.py's
/get-started - community.py's /report and /r/<code> keep their own inline copy
of this, untouched, since they're already live and working). hCaptcha if the
deployment has keys configured, else a session-backed math challenge so
there's still some bot resistance with zero external signup."""

import json
import random
import urllib.error
import urllib.parse
import urllib.request

from flask import current_app, request, session


def hcaptcha_configured():
    cfg = current_app.config
    return bool(cfg.get("HCAPTCHA_SITE_KEY")) and bool(cfg.get("HCAPTCHA_SECRET_KEY"))


def new_math_challenge():
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


def verify_captcha():
    if hcaptcha_configured():
        return _verify_hcaptcha(request.form.get("h-captcha-response"))

    try:
        expected = session.get("captcha_a", 0) + session.get("captcha_b", 0)
        given = int((request.form.get("captcha_answer") or "").strip())
    except (TypeError, ValueError):
        return False
    return given == expected
