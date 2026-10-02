"""
Shared code generation for barcodes (items/tools/projects) and badge
codes (users). Factored out so app/routes_admin.py (the web admin
panel) and main.py's run_create_user_inprocess (the CLI path used by
the Setup Wizard and cloud pairing) can't drift out of sync -- both
need the exact same "always guarantee a real code" guarantee, since
badge_code is now the ONLY way to log in (see app/routes_auth.py).
"""
import secrets

from app.models import Barcode, LocalUser, Item

# Unambiguous charset -- no 0/O/1/I, since these may end up hand-typed
# or printed on a label.
_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
_CODE_LENGTH = 8
_MAX_GEN_ATTEMPTS = 20


def _random_code(length: int = _CODE_LENGTH) -> str:
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(length))


def unique_barcode_code() -> str:
    for _ in range(_MAX_GEN_ATTEMPTS):
        code = _random_code()
        if not Barcode.query.filter_by(code=code).first():
            return code
    raise RuntimeError("Could not generate a unique barcode code -- this should be virtually impossible; check _CODE_ALPHABET/_CODE_LENGTH.")


def unique_badge_code() -> str:
    for _ in range(_MAX_GEN_ATTEMPTS):
        code = _random_code()
        if not LocalUser.query.filter_by(badge_code=code).first():
            return code
    raise RuntimeError("Could not generate a unique badge code -- this should be virtually impossible; check _CODE_ALPHABET/_CODE_LENGTH.")


def unique_sku() -> str:
    """Shorter than barcode/badge codes (6 chars, not 8) and prefixed
    so a glance tells a SKU apart from a barcode/badge -- these three
    code families are visually distinct on purpose, since they mean
    different things (a SKU is a catalog identifier admins may already
    have from a supplier; a barcode_code is what a scanner reads)."""
    for _ in range(_MAX_GEN_ATTEMPTS):
        candidate = "SKU-" + _random_code(6)
        if not Item.query.filter_by(sku=candidate).first():
            return candidate
    raise RuntimeError("Could not generate a unique SKU -- this should be virtually impossible; check _CODE_ALPHABET/_CODE_LENGTH.")
