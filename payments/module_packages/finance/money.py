"""Decimal-safe money helpers. All storage is integer minor units (pence).
Never use floats for money anywhere in this module.
"""
import re
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation


def to_minor(amount) -> int:
    """Convert a Decimal/str/float major-unit amount (e.g. '12.50') to
    integer minor units (1250). Tolerant of the messy strings real HTML
    forms actually submit: blank/whitespace-only treated as 0, currency
    symbols and thousands separators stripped, leading '+' allowed.
    Raises ValueError (not a raw decimal exception) on genuinely invalid
    input, so callers can catch one clear exception type and show the
    user a message instead of a 500.
    """
    if amount is None:
        return 0
    text = str(amount).strip()
    if text == "":
        return 0
    text = re.sub(r"[£$€,\s]", "", text)
    if text in ("", "+", "-"):
        return 0
    try:
        d = Decimal(text).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    except InvalidOperation:
        raise ValueError(f"'{amount}' isn't a valid amount — enter a number like 12.50")
    return int(d * 100)


def to_major(amount_minor: int) -> Decimal:
    """Convert integer minor units back to a Decimal major-unit amount."""
    return (Decimal(amount_minor) / 100).quantize(Decimal("0.01"))


def format_money(amount_minor: int, currency: str = "GBP") -> str:
    symbols = {"GBP": "£", "USD": "$", "EUR": "€"}
    symbol = symbols.get(currency, currency + " ")
    major = to_major(amount_minor)
    sign = "-" if major < 0 else ""
    return f"{sign}{symbol}{abs(major):,.2f}"
