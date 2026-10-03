"""DVSA MOT History API client (stdlib only).

OAuth2 client-credentials against Microsoft Entra, then a registration lookup.
Access tokens are valid 60 min and cached in-process. Secrets come from config
(env) and never reach the browser — views proxy this server-side.
"""
import json
import time
import threading
import urllib.parse
import urllib.request
import urllib.error
from flask import current_app

_token = {"value": None, "exp": 0.0}
_lock = threading.Lock()


def is_configured():
    cfg = current_app.config
    return bool(cfg.get("MOT_CLIENT_ID") and cfg.get("MOT_CLIENT_SECRET")
               and cfg.get("MOT_API_KEY") and cfg.get("MOT_TOKEN_URL"))


def _get_token():
    cfg = current_app.config
    with _lock:
        if _token["value"] and time.time() < _token["exp"] - 60:
            return _token["value"]
        data = urllib.parse.urlencode({
            "grant_type": "client_credentials",
            "client_id": cfg["MOT_CLIENT_ID"],
            "client_secret": cfg["MOT_CLIENT_SECRET"],
            "scope": cfg["MOT_SCOPE"],
        }).encode()
        req = urllib.request.Request(
            cfg["MOT_TOKEN_URL"], data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=20) as r:
            tok = json.loads(r.read().decode())
        _token["value"] = tok["access_token"]
        _token["exp"] = time.time() + int(tok.get("expires_in", 1199))
        return _token["value"]


def _year_of(*vals):
    for v in vals:
        s = str(v or "")
        if len(s) >= 4 and s[:4].isdigit():
            return s[:4]
    return ""


def lookup_registration(reg):
    """Return (vehicle_dict, None) on success or (None, error_message)."""
    if not is_configured():
        return None, "MOT lookup is not configured on the server."
    cfg = current_app.config
    reg_clean = "".join((reg or "").split()).upper()
    if not reg_clean:
        return None, "Enter a registration."

    try:
        token = _get_token()
    except Exception as exc:  # noqa: BLE001
        current_app.logger.error("MOT token error: %s", exc)
        return None, "Could not authenticate with the MOT service."

    url = (f"{cfg['MOT_API_BASE'].rstrip('/')}"
           f"/v1/trade/vehicles/registration/{urllib.parse.quote(reg_clean)}")
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "X-API-Key": cfg["MOT_API_KEY"],
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, "No vehicle found for that registration."
        if e.code == 429:
            return None, "Too many lookups — try again shortly."
        current_app.logger.error("MOT API HTTP %s for %s", e.code, reg_clean)
        return None, f"MOT service error ({e.code})."
    except Exception as exc:  # noqa: BLE001
        current_app.logger.error("MOT API error: %s", exc)
        return None, "Lookup failed — try again."

    if isinstance(data, list):  # some responses wrap in a list
        data = data[0] if data else {}

    # Parse full MOT test history
    from datetime import date
    tests = []
    for t in (data.get("motTests") or []):
        defects = t.get("defects") or []
        adv, fails = [], []
        for dft in defects:
            typ = (dft.get("type") or "").upper()
            txt = dft.get("text") or ""
            if not txt:
                continue
            if typ in ("ADVISORY", "MINOR") and not dft.get("dangerous"):
                adv.append(txt)
            else:
                fails.append(txt)
        tests.append({
            "date": (t.get("completedDate") or "")[:10],
            "result": t.get("testResult"),
            "mileage": t.get("odometerValue"),
            "unit": (t.get("odometerUnit") or "").lower(),
            "expiry": t.get("expiryDate"),
            "advisories": adv,
            "failures": fails,
        })
    expiries = [t["expiry"] for t in tests if t.get("expiry")]
    mot_expiry = max(expiries) if expiries else None
    mot_valid = (mot_expiry[:10] >= date.today().isoformat()) if mot_expiry else None

    vehicle = {
        "make": (data.get("make") or "").title() if data.get("make") else "",
        "model": (data.get("model") or "").title() if data.get("model") else "",
        "color": (data.get("primaryColour") or "").title() if data.get("primaryColour") else "",
        "year": _year_of(data.get("manufactureDate"), data.get("firstUsedDate"),
                         data.get("registrationDate")),
        "reg_number": (data.get("registration") or reg_clean).upper(),
        "fuel": data.get("fuelType") or "",
        "mot_valid": mot_valid,
        "mot_expiry": mot_expiry,
        "first_mot_due": data.get("motTestDueDate") or data.get("firstMotDueDate"),
        "tests": tests,
    }
    return vehicle, None
