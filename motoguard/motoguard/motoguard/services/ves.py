"""DVLA Vehicle Enquiry Service client — tax status and MOT status.

Simple POST with an x-api-key header (stdlib only). Returns the live tax/MOT
status DVLA holds for a registration. Requires a free VES API key, separate
from the MOT History API key.
"""
import json
import urllib.request
import urllib.error
from flask import current_app


def is_configured():
    return bool(current_app.config.get("VES_API_KEY"))


def lookup(reg):
    """Return (info_dict, None) on success or (None, error_message)."""
    if not is_configured():
        return None, "Tax lookup not configured"
    reg_clean = "".join((reg or "").split()).upper()
    if not reg_clean:
        return None, "Enter a registration."

    cfg = current_app.config
    body = json.dumps({"registrationNumber": reg_clean}).encode()
    req = urllib.request.Request(cfg["VES_API_URL"], data=body, headers={
        "x-api-key": cfg["VES_API_KEY"],
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, "No DVLA record for that registration."
        current_app.logger.error("VES HTTP %s for %s", e.code, reg_clean)
        return None, f"Tax service error ({e.code})."
    except Exception as exc:  # noqa: BLE001
        current_app.logger.error("VES error: %s", exc)
        return None, "Tax lookup failed."

    return {
        "tax_status": d.get("taxStatus"),       # Taxed | Untaxed | SORN | ...
        "tax_due": d.get("taxDueDate"),
        "mot_status": d.get("motStatus"),        # Valid | Not valid | No details held by DVLA
        "mot_expiry": d.get("motExpiryDate"),
        "make": d.get("make"),
        "year": d.get("yearOfManufacture"),
        "colour": d.get("colour"),
        "fuel": d.get("fuelType"),
        "engine_cc": d.get("engineCapacity"),
    }, None
