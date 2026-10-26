"""Shared helpers for community-hosted evidence video storage (webhooks.py's upload endpoint,
views.py's serving route) - the portal-hosting alternative to self-hosting the media/ folder
yourself (see opslabs-bodycam/README.md). Experimental: FXServer never pushes bytes here itself
(sending video through its own HTTP client crashed the game server before) - only an independent
companion script running outside the game server process does."""

import os
import re
from urllib.parse import urlsplit

from flask import current_app, g

from .live_tokens import sign_viewer_token

FILENAME_RE = re.compile(r"^[A-Za-z0-9_-]{22}\.webm$")
SLUG_RE = re.compile(r"^[a-z0-9_-]{1,64}$")
WEBM_MAGIC = b"\x1a\x45\xdf\xa3"
MAX_UPLOAD_BYTES = 64 * 1024 * 1024

# A real-looking http(s) URL with no whitespace/control characters and no literal '*' - catches both
# "forgot to set it" (blank) and "pasted something wrong" (e.g. a copy-paste that left '**.webm' in a
# Storage.PublicUrl, which happened once and stored unplayable links for days before anyone noticed -
# see fivem-resource/opslabs-bodycam/server/main.lua's matching Lua-side check at startup).
_PLAUSIBLE_URL_RE = re.compile(r"^https?://[^\s*]+$")


def is_plausible_video_url(url):
    return bool(url) and bool(_PLAUSIBLE_URL_RE.match(url))


def _safe_slug(slug):
    return slug if slug and SLUG_RE.match(slug) else "shared"


def media_dir_for_slug(slug, create=True):
    path = os.path.join(current_app.instance_path, "media_uploads", _safe_slug(slug))
    if create:
        os.makedirs(path, exist_ok=True)
    return path


def signed_media_url(video_url):
    """A portal-hosted videoUrl (served by views.py's /media/<filename>, not a web server the
    community runs themselves) needs a short-lived signed token to actually play - that route sits
    behind this app's own login, which a bare <video src> can never satisfy itself (no interactive
    redirect, and a different host than the one the viewer is logged into won't even carry the
    session cookie - the exact reason community-hosted video showed "unavailable" even when the file
    was right there). Anything else (self-hosted on the operator's own web server, e.g. the original
    production bodycam's ops-phone.opslabsystems.cloud alias) passes through unchanged - it was never
    behind Xon Sight's login to begin with, and never needed to be.

    Computed fresh on every render (template global + evidence_detail's item_json), never stored -
    evidence has to stay playable indefinitely, a baked-in token with a TTL would not."""
    if not video_url:
        return video_url
    path = urlsplit(video_url).path
    if not path.startswith("/media/"):
        return video_url
    filename = path.rsplit("/", 1)[-1]
    slug = g.tenant.slug if getattr(g, "tenant", None) else ""
    token = sign_viewer_token(f"media:{slug}:{filename}")
    sep = "&" if "?" in video_url else "?"
    return f"{video_url}{sep}slug={slug}&xs_token={token}"
