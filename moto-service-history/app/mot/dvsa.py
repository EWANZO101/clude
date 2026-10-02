"""
DVSA MOT History API client.

Uses the UK Government "MOT History" trade API (api.gov.uk / DVSA).
Credentials are read from admin-configurable AppSetting rows first,
falling back to environment variables. Configure these in
Admin > Settings > MOT API without touching code.

The DVSA API requires an OAuth2 client-credentials token exchange
(tenant/client id/secret + scope) plus a static subscription API key
header. Endpoint/scope URLs vary by DVSA's current API version, so
they are also admin-configurable rather than hardcoded.
"""
import json
import os
from datetime import datetime, date

import requests

from app.models import AppSetting, ApiLog
from app.extensions import db

_token_cache = {"access_token": None, "expires_at": 0}


class MOTLookupError(Exception):
    pass


def _setting(key, env_fallback=None):
    val = AppSetting.get(key)
    if val:
        return val
    return os.environ.get(env_fallback) if env_fallback else None


def _get_access_token():
    import time

    if _token_cache["access_token"] and _token_cache["expires_at"] > time.time() + 30:
        return _token_cache["access_token"]

    token_url = _setting("dvsa_token_url", "DVSA_MOT_TOKEN_URL")
    client_id = _setting("dvsa_client_id", "DVSA_MOT_CLIENT_ID")
    client_secret = _setting("dvsa_client_secret", "DVSA_MOT_CLIENT_SECRET")
    scope_url = _setting("dvsa_scope_url", "DVSA_MOT_SCOPE_URL")

    if not all([token_url, client_id, client_secret, scope_url]):
        raise MOTLookupError(
            "MOT API is not configured yet. Add DVSA credentials in Admin > Settings."
        )

    resp = requests.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": scope_url,
        },
        timeout=15,
    )
    if resp.status_code != 200:
        raise MOTLookupError(f"Could not authenticate with DVSA (status {resp.status_code}).")
    data = resp.json()
    _token_cache["access_token"] = data["access_token"]
    _token_cache["expires_at"] = time.time() + int(data.get("expires_in", 3300))
    return _token_cache["access_token"]


def lookup_mot_history(registration):
    """Look up a registration against the DVSA MOT History API.

    Returns a dict: {"vehicle": {...vehicle details...}, "tests": [...MOT test records...]}
    """
    registration = (registration or "").replace(" ", "").upper()
    if not registration:
        raise MOTLookupError("Enter a registration number.")

    api_base = _setting("dvsa_api_base", None) or "https://history.mot.api.gov.uk/v1/trade/vehicles/registration"
    api_key = _setting("dvsa_api_key", "DVSA_MOT_API_KEY")

    if not api_key:
        raise MOTLookupError(
            "MOT API is not configured yet. Add the DVSA API key in Admin > Settings."
        )

    try:
        token = _get_access_token()
    except MOTLookupError:
        raise
    except Exception as e:
        _log("error", registration, f"Token error: {e}")
        raise MOTLookupError("Could not authenticate with the DVSA MOT service.")

    headers = {
        "Authorization": f"Bearer {token}",
        "X-API-Key": api_key,
        "Accept": "application/json",
    }

    try:
        resp = requests.get(f"{api_base}/{registration}", headers=headers, timeout=15)
    except requests.RequestException as e:
        _log("error", registration, str(e))
        raise MOTLookupError("Could not reach the DVSA MOT service.")

    if resp.status_code == 404:
        _log("error", registration, "Not found")
        raise MOTLookupError("No MOT history found for that registration.")
    if resp.status_code != 200:
        _log("error", registration, f"HTTP {resp.status_code}: {resp.text[:300]}")
        raise MOTLookupError(f"DVSA service returned an error (status {resp.status_code}).")

    payload = resp.json()
    _log("success", registration, f"{len(payload.get('motTests', []))} test(s) retrieved")

    records = []
    for test in payload.get("motTests", []):
        records.append({
            "test_date": _parse_date(test.get("completedDate")),
            "expiry_date": _parse_date(test.get("expiryDate")),
            "result": test.get("testResult"),
            "mileage": _safe_int(test.get("odometerValue")),
            "mileage_unit": test.get("odometerUnit"),
            "test_number": test.get("motTestNumber"),
            "advisories": json.dumps([
                d.get("text") for d in test.get("rfrAndComments", [])
                if d.get("type") in ("ADVISORY", "USER_ENTERED")
            ]),
            "failures": json.dumps([
                d.get("text") for d in test.get("rfrAndComments", [])
                if d.get("type") in ("FAIL", "MAJOR", "DANGEROUS")
            ]),
        })

    vehicle = {
        "registration": payload.get("registration"),
        "make": payload.get("make"),
        "model": payload.get("model"),
        "colour": payload.get("primaryColour"),
        "fuel_type": payload.get("fuelType"),
        "engine_size": payload.get("engineSize"),
        "year": _year_from_dates(
            payload.get("manufactureDate") or payload.get("firstUsedDate") or payload.get("registrationDate")
        ),
    }
    return {"vehicle": vehicle, "tests": records}


def _year_from_dates(value):
    d = _parse_date(value)
    return d.year if d else None


def _parse_date(value):
    if not value:
        return None
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(value[:19], fmt).date()
        except (ValueError, TypeError):
            continue
    return None


def _safe_int(value):
    try:
        return int(value)
    except (ValueError, TypeError):
        return None


def _log(status, registration, message):
    try:
        db.session.add(ApiLog(source="dvsa_mot", status=status, registration=registration, message=message))
        db.session.commit()
    except Exception:
        db.session.rollback()
