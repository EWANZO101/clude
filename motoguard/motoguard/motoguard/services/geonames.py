"""GeoNames place-search client (proxied server-side so the username stays put).

Returns towns/cities (feature class P) plus regions and countries (class A),
normalised into city / region / country / lat / lng for the location picker.
"""
import json
import urllib.request
import urllib.parse
from flask import current_app


def is_configured():
    return bool(current_app.config.get("GEONAMES_USERNAME"))


def _norm(g):
    fcl = g.get("fcl")
    fcode = g.get("fcode") or ""
    name = g.get("name") or ""
    country = g.get("countryName") or ""
    region = g.get("adminName1") or ""
    city = ""
    if fcl == "P":                       # populated place: town/city
        city = name
    elif fcode.startswith("PCL"):        # a country
        country, region = name, ""
    else:                                # admin area: region/county/state
        region = name
    parts = [name]
    if region and region != name:
        parts.append(region)
    if country and country != name:
        parts.append(country)
    try:
        lat = round(float(g.get("lat")), 5)
        lng = round(float(g.get("lng")), 5)
    except (TypeError, ValueError):
        lat = lng = None
    return {"label": ", ".join(parts), "city": city, "region": region,
            "country": country, "lat": lat, "lng": lng}


def search(q, max_rows=8):
    """Return (results_list, None) or (None, error_message)."""
    if not is_configured():
        return None, "Place search not configured"
    q = (q or "").strip()
    if len(q) < 2:
        return [], None
    params = [
        ("name_startsWith", q), ("maxRows", str(max_rows)),
        ("featureClass", "P"), ("featureClass", "A"),
        ("orderby", "relevance"), ("style", "MEDIUM"),
        ("username", current_app.config["GEONAMES_USERNAME"]),
    ]
    url = current_app.config["GEONAMES_BASE"].rstrip("/") + "/searchJSON?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=12) as r:
            data = json.loads(r.read().decode())
    except Exception as exc:  # noqa: BLE001
        current_app.logger.error("GeoNames error: %s", exc)
        return None, "Place search failed"
    if isinstance(data, dict) and data.get("status"):
        msg = data["status"].get("message", "GeoNames error")
        current_app.logger.error("GeoNames status: %s", msg)
        return None, msg
    return [_norm(g) for g in (data.get("geonames") or [])], None
