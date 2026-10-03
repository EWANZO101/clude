"""Geo utilities. Precise coords are used only for radius targeting."""
from math import radians, sin, cos, asin, sqrt


def to_float(val):
    """Parse user input to float; return None on blank/garbage (never raises)."""
    try:
        s = (val or "").strip()
        return float(s) if s else None
    except (TypeError, ValueError):
        return None


def haversine_miles(lat1, lng1, lat2, lng2):
    if None in (lat1, lng1, lat2, lng2):
        return None
    lat1, lng1, lat2, lng2 = map(radians, (lat1, lng1, lat2, lng2))
    dlat = lat2 - lat1
    dlng = lng2 - lng1
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlng / 2) ** 2
    return 3958.7613 * 2 * asin(sqrt(a))
