"""Data export registry. Any module (core or installed) can register an
exporter function; the export page/route discovers what's available and
lets the user download CSV/JSON per-module or a single full-system ZIP.
Same registration pattern as app.core.search.registry — a module calls
register_exporter() once at import time, and this module never imports
any specific module back (keeps the dependency direction one-way).
"""
_exporters = {}


def register_exporter(key, label, fn):
    """fn(user) -> dict[filename] = (content_str_or_bytes, mimetype)"""
    _exporters[key] = {"label": label, "fn": fn}


def available_exporters():
    return _exporters


def run_exporter(key, user):
    entry = _exporters.get(key)
    if not entry:
        return {}
    try:
        return entry["fn"](user) or {}
    except Exception:
        return {}
