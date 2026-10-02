"""
Single source of truth for this build's version. Bump this before
publishing a new release via POST /api/updates (see Part 2).
"""
__version__ = "2.3.0"
__release_date__ = "2026-08-25"


def parse_version(v: str) -> tuple:
    """'2.1.3' -> (2, 1, 3). Non-numeric/malformed parts sort as 0 rather
    than raising, so a weird version string can't crash a comparison."""
    parts = []
    for p in v.strip().split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def is_newer(candidate: str, current: str) -> bool:
    return parse_version(candidate) > parse_version(current)
