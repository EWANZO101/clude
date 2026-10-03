"""Notifications, the tiered stolen-bike alert engine, and the owner share-pack.

Emails are rendered in a Flowbite-inspired style using email-safe inline CSS and
table layout (email clients strip Tailwind/Flowbite classes and external styles).
No server URLs are printed in the visible body or in the copy-paste social post —
action links only appear when a real public domain is configured.
"""
import ipaddress
import urllib.parse
from html import escape
from flask import current_app, url_for
from ..extensions import db
from ..models import User, Notification, Vehicle
from .geo import haversine_miles
from .mailer import send_email

# ---- Flowbite-style palette (light email) ----
_INK = "#111827"; _MUTE = "#6B7280"; _LINE = "#E5E7EB"
_BG = "#F3F4F6"; _CARD = "#FFFFFF"; _SOFT = "#F9FAFB"
_BRAND = "#F5C518"; _RED = "#DC2626"; _BLUE = "#2563EB"


def notify(user_id, text, url=None):
    n = Notification(user_id=user_id, text=text, url=url)
    db.session.add(n)
    db.session.commit()
    return n


def public_base():
    """Return PUBLIC_BASE_URL only if it's a real public domain (not an IP, not
    localhost, not an internal hostname). Otherwise None — so we never leak the
    server address into emails."""
    raw = (current_app.config.get("PUBLIC_BASE_URL") or "").strip().rstrip("/")
    if not raw:
        return None
    host = (urllib.parse.urlparse(raw).hostname or "").lower()
    if not host or host == "localhost" or "swift" in host or "." not in host:
        return None
    try:
        ipaddress.ip_address(host)
        return None  # bare IP address
    except ValueError:
        pass
    if raw.startswith("http://"):   # always emit https for a public domain
        raw = "https://" + raw[len("http://"):]
    return raw


# ---------------- email building blocks ----------------

def _btn(label, href, bg=_BRAND, color=_INK):
    return (f'<a href="{href}" style="display:inline-block;background:{bg};color:{color};'
            f'font-family:Arial,Helvetica,sans-serif;font-weight:700;font-size:14px;'
            f'text-decoration:none;padding:12px 24px;border-radius:10px;">{label}</a>')


def _rows(pairs):
    cells = ""
    for k, v in pairs:
        if not v:
            continue
        cells += (f'<tr><td style="padding:9px 14px 9px 0;color:{_MUTE};font-size:13px;'
                  f'vertical-align:top;white-space:nowrap;border-bottom:1px solid {_LINE};">{escape(str(k))}</td>'
                  f'<td style="padding:9px 0;color:{_INK};font-size:14px;font-weight:600;'
                  f'border-bottom:1px solid {_LINE};">{escape(str(v))}</td></tr>')
    return (f'<table role="presentation" cellpadding="0" cellspacing="0" '
            f'style="width:100%;border-collapse:collapse;margin:6px 0 20px;">{cells}</table>')


def _shell(title, badge_text, badge_bg, body_html, preheader=""):
    return f"""\
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:{_BG};">
<span style="display:none;max-height:0;overflow:hidden;opacity:0;color:{_BG};">{escape(preheader)}</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{_BG};">
 <tr><td align="center" style="padding:26px 12px;">
  <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;">
   <tr><td style="padding:2px 6px 16px;">
     <span style="display:inline-block;width:14px;height:14px;background:{_BRAND};border-radius:3px;vertical-align:-2px;margin-right:8px;"></span>
     <span style="font-family:Arial,Helvetica,sans-serif;font-weight:800;font-size:19px;color:{_INK};letter-spacing:.5px;">MOTOGUARD</span>
   </td></tr>
   <tr><td style="background:{_CARD};border:1px solid {_LINE};border-radius:16px;padding:30px;">
     <span style="display:inline-block;background:{badge_bg};color:#ffffff;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;padding:6px 13px;border-radius:999px;">{escape(badge_text)}</span>
     <h1 style="font-family:Arial,Helvetica,sans-serif;font-size:23px;line-height:1.25;color:{_INK};margin:16px 0 4px;">{escape(title)}</h1>
     {body_html}
   </td></tr>
   <tr><td style="padding:18px 8px;color:{_MUTE};font-size:12px;line-height:1.6;font-family:Arial,Helvetica,sans-serif;">
     MotoGuard — community bike-theft recovery. You're receiving this because you have a MotoGuard account.
   </td></tr>
  </table>
 </td></tr>
</table></body></html>"""


def _p(text, color=_INK, size=14):
    return (f'<p style="font-family:Arial,Helvetica,sans-serif;color:{color};font-size:{size}px;'
            f'line-height:1.6;margin:0 0 14px;">{text}</p>')


def _photo(vehicle):
    base = public_base()
    if base and vehicle.photos:
        return (f'<img src="{base}/static/uploads/{vehicle.photos[0].filename}" alt="" '
                f'style="display:block;width:100%;max-width:540px;border-radius:12px;margin:6px 0 18px;">')
    return ""


# ---------------- alert email ----------------

def _alert_html(vehicle, reason):
    base = public_base()
    details = _rows([
        ("Bike", vehicle.title), ("Colour", vehicle.color),
        ("Reg", vehicle.reg_number), ("Last seen", vehicle.public_location),
        ("Reported", vehicle.stolen_at.strftime('%d %b %Y, %H:%M') if vehicle.stolen_at else ""),
    ])
    body = _p(reason, color=_MUTE, size=13) + _photo(vehicle) + details
    if vehicle.description:
        body += _p(f'<strong>Identifying features:</strong> {escape(vehicle.description)}')
    if base:
        body += ('<div style="margin:6px 0 4px;">'
                 + _btn("View details", f"{base}/vehicles/{vehicle.id}")
                 + '&nbsp;&nbsp;'
                 + _btn("Report a sighting", f"{base}/sightings/report/{vehicle.id}", bg=_SOFT, color=_INK)
                 + '</div>')
    else:
        body += _p("If you've seen this bike, log in to MotoGuard to report a sighting — do not approach.",
                   color=_MUTE, size=13)
    return _shell(vehicle.title, "Stolen bike alert", _RED, body,
                  preheader=f"{vehicle.title} reported stolen — {vehicle.public_location}")


def _alert_text(vehicle):
    return (f"STOLEN: {vehicle.title} (reg {vehicle.reg_number or 'n/a'}), "
            f"last seen {vehicle.public_location}. "
            f"Log in to MotoGuard to view details or report a sighting. Do not approach.")


def dispatch_stolen_alerts(vehicle):
    """Tiered alert: email opted-in riders in the same town, then the same
    country, then anyone within their radius of the theft. One email per rider,
    capped per stolen event. Returns the number emailed."""
    cap = current_app.config["ALERT_PER_EVENT_CAP"]
    if vehicle.alerts_sent >= cap:
        return 0
    default_radius = current_app.config["ALERT_RADIUS_MILES"]

    vcity = (vehicle.last_city or "").strip().lower()
    vcountry = (getattr(vehicle, "last_country", None) or "").strip().lower()
    if not vcountry and vehicle.owner and vehicle.owner.country:
        vcountry = vehicle.owner.country.strip().lower()

    pool = User.query.filter(User.alerts_opt_in.is_(True), User.is_banned.is_(False),
                             User.id != vehicle.owner_id).all()

    targets = {}
    for u in pool:
        if vcity and (u.city or "").strip().lower() == vcity:
            targets[u.id] = (u, f"A bike was reported stolen in {vehicle.last_city}.")
            continue
        if vcountry and (u.country or "").strip().lower() == vcountry:
            targets.setdefault(u.id, (u, "A bike was reported stolen in your country."))
            continue
        if vehicle.last_lat is not None and u.lat is not None:
            radius = u.alert_radius_miles or default_radius
            d = haversine_miles(vehicle.last_lat, vehicle.last_lng, u.lat, u.lng)
            if d is not None and d <= radius:
                targets.setdefault(u.id, (u, f"A bike was reported stolen within {round(d)} miles of you."))

    text = _alert_text(vehicle)
    for u, reason in targets.values():
        send_email(u.email, f"Stolen bike alert: {vehicle.title}", _alert_html(vehicle, reason), text)
        notify(u.id, f"Stolen bike alert near you: {vehicle.title}",
               url_for("vehicles.detail", vehicle_id=vehicle.id))

    vehicle.alerts_sent += 1
    db.session.commit()
    sent = len(targets)
    current_app.logger.info("Dispatched %s tiered stolen alerts for vehicle %s", sent, vehicle.id)
    return sent


# ---------------- social post (no URLs — clean to copy-paste) ----------------

def build_social_post(vehicle):
    """Ready-to-paste social post with everything the owner registered. Links are
    included only when a real public domain is configured — never an IP or the
    internal server hostname."""
    base = public_base()
    lines = ["\U0001F6A8 STOLEN \u2014 PLEASE SHARE \U0001F6A8", ""]
    lines.append(vehicle.title + (f" \u2014 {vehicle.color}" if vehicle.color else ""))
    if vehicle.reg_number:
        lines.append(f"Reg: {vehicle.reg_number}")
    if vehicle.vin:
        lines.append(f"VIN / frame: {vehicle.vin}")
    if vehicle.description:
        lines.append(f"Identifying features: {vehicle.description}")
    if vehicle.public_location and vehicle.public_location != "Unknown":
        lines.append(f"Last seen: {vehicle.public_location}")
    if vehicle.stolen_at:
        lines.append(f"Stolen around: {vehicle.stolen_at.strftime('%d %b %Y, %H:%M')}")
    lines += ["",
              "If you see this bike, do NOT approach. Note the location and call the "
              "police \u2014 quote the registration above."]
    if base:
        lines += ["",
                  f"Report a sighting: {base}/sightings/report/{vehicle.id}",
                  f"Full details & photos: {base}/vehicles/{vehicle.id}"]
    lines += ["", "Please share to help get it home."]
    tags = ["#StolenBike", "#MotoGuard"]
    if vehicle.last_city:
        tags.append("#" + "".join(vehicle.last_city.split()))
    if vehicle.make:
        tags.append("#" + "".join(vehicle.make.split()))
    lines += ["", " ".join(tags)]
    return "\n".join(lines)


# ---------------- owner pack email ----------------

def email_owner_stolen_pack(vehicle):
    owner = vehicle.owner
    if not owner:
        return
    base = public_base()
    post = build_social_post(vehicle)
    details = _rows([
        ("Make", vehicle.make), ("Model", vehicle.model), ("Year", vehicle.year),
        ("Colour", vehicle.color), ("Reg", vehicle.reg_number), ("VIN / frame", vehicle.vin),
        ("Identifying features", vehicle.description), ("Last seen", vehicle.public_location),
        ("Reported", vehicle.stolen_at.strftime('%d %b %Y, %H:%M') if vehicle.stolen_at else ""),
    ])
    copybox = (f'<div style="background:{_SOFT};border:1px solid {_LINE};border-radius:12px;padding:18px;margin:4px 0 6px;">'
               f'<pre style="margin:0;white-space:pre-wrap;word-break:break-word;'
               f'font-family:Consolas,Menlo,Monaco,monospace;font-size:13px;line-height:1.6;color:{_INK};">'
               f'{escape(post)}</pre></div>')
    body = (_p("We've alerted riders in your area. Here's everything on file, plus a "
               "post you can copy and paste straight onto Facebook, Instagram or X.")
            + _photo(vehicle) + details
            + f'<p style="font-family:Arial,Helvetica,sans-serif;font-size:13px;font-weight:700;'
              f'color:{_INK};margin:0 0 8px;">Ready-to-share post \u2014 copy the box below</p>'
            + copybox)
    if base:
        body += '<div style="margin-top:18px;">' + _btn("Open your bike page", f"{base}/vehicles/{vehicle.id}") + '</div>'
    html = _shell("Your stolen-bike pack", "Stolen bike alert", _RED, body,
                  preheader="Your bike details and a ready-to-share post")
    text = "Your stolen-bike pack.\n\nReady-to-share post (copy & paste):\n\n" + post
    send_email(owner.email, f"Your stolen-bike pack \u2014 {vehicle.title}", html, text)


# ---------------- password reset email ----------------

def reset_email_html(link):
    body = (_p("We received a request to reset your MotoGuard password. "
               "Tap the button below to choose a new one.")
            + '<div style="margin:6px 0 18px;">' + _btn("Reset password", link) + '</div>'
            + _p("This link expires in 1 hour. If you didn't request it, you can safely "
                 "ignore this email \u2014 your password won't change.", color=_MUTE, size=13))
    return _shell("Reset your password", "Account security", _BLUE, body,
                  preheader="Reset your MotoGuard password (expires in 1 hour)")
