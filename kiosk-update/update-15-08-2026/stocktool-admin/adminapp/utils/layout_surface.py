"""
layout_surface.py — one shared helper admin list-page routes call to
check whether a published Builder Mode layout exists for their surface.
Returns None if nothing's published yet (or the API call fails), in
which case the route falls back to that page's original hard-coded
template exactly as before -- same safety pattern as the kiosk side.
"""
from adminapp.utils.api_client import api_get, APIError


def get_published_layout(surface: str):
    try:
        data = api_get(f"/api/layouts/resolve?surface={surface}")
    except APIError:
        return None
    layout = data.get("layout")
    if not layout:
        return None
    return layout["components"]
