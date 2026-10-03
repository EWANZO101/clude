"""Merchant matching pipeline, in the order specified: exact -> alias ->
normalised -> identifier -> MCC -> fuzzy -> historical user mapping ->
optional AI. MCC and external merchant identifiers aren't available from
CSV imports (no such column), so those stages are structural pass-throughs
today — they activate automatically once a data source that provides them
(a bank API sync, for instance) is wired in. AI matching is deliberately
not implemented here; see REMAINING_WORK.txt.

Performance note (Part 10): the merchant/alias lookup tables are small and
mostly-static (seed data + occasional corrections), so the full alias and
merchant lists are cached in-process rather than re-queried on every single
transaction match. invalidate_merchant_cache() is called wherever an alias
or merchant is added/edited. This is a single-process cache — a
multi-worker deployment needs a shared cache (e.g. Redis) to stay
consistent across workers, same limitation as the rate limiter.
"""
import difflib
import re
import time

from app.extensions import db
from .models import Merchant, MerchantAlias, MerchantUserMapping

_CACHE_TTL_SECONDS = 300
_cache = {"aliases": None, "merchants": None, "loaded_at": 0}


def invalidate_merchant_cache():
    _cache["aliases"] = None
    _cache["merchants"] = None
    _cache["loaded_at"] = 0


def _cached_aliases():
    now = time.time()
    if _cache["aliases"] is None or now - _cache["loaded_at"] > _CACHE_TTL_SECONDS:
        _cache["aliases"] = MerchantAlias.query.all()
        _cache["merchants"] = Merchant.query.filter_by(active=True).all()
        _cache["loaded_at"] = now
    return _cache["aliases"]


def _cached_active_merchants():
    _cached_aliases()  # ensures both are loaded together and share one TTL window
    return _cache["merchants"]


def normalise(text):
    text = (text or "").upper()
    text = re.sub(r"\d{4,}", "", text)  # strip long reference/card numbers
    text = re.sub(r"[^A-Z0-9 ]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def match_description(user_id, description, mcc=None, external_merchant_id=None):
    """Returns (merchant, stage) or (None, None). Runs the pipeline stages in
    spec order; the first stage to produce a confident match wins."""
    normalised = normalise(description)
    if not normalised:
        return None, None

    # 1. Exact merchant display name match
    exact = Merchant.query.filter(db.func.upper(Merchant.display_name) == normalised).first()
    if exact:
        return exact, "exact"

    # 2. Alias matching (exact alias text)
    alias_row = MerchantAlias.query.filter_by(alias_text=normalised).first()
    if not alias_row:
        # description often contains the alias as a substring (e.g. "TESCO STORES 2931 LONDON")
        candidates = _cached_aliases()
        for a in candidates:
            if a.alias_text and a.alias_text in normalised:
                alias_row = a
                break
    if alias_row:
        return db.session.get(Merchant, alias_row.merchant_id), "alias"

    # 3. Normalised matching against merchant display names (substring, both directions)
    for merchant in _cached_active_merchants():
        merchant_norm = normalise(merchant.display_name)
        if merchant_norm and (merchant_norm in normalised or normalised in merchant_norm):
            return merchant, "normalised"

    # 4. Merchant identifier — no external id available from CSV import; structural pass-through
    if external_merchant_id:
        pass  # would look up a MerchantExternalId table once a provider supplies one

    # 5. MCC — no MCC available from CSV import; structural pass-through
    if mcc:
        pass  # would look up a category/merchant-type mapping from MCC once available

    # 6. Fuzzy matching
    all_names = {m.display_name: m for m in _cached_active_merchants()}
    close = difflib.get_close_matches(normalised.title(), list(all_names.keys()), n=1, cutoff=0.75)
    if close:
        return all_names[close[0]], "fuzzy"

    # 7. Historical user mapping (this user's own past corrections)
    mapping = MerchantUserMapping.query.filter_by(user_id=user_id, description_text=normalised).first()
    if mapping:
        return db.session.get(Merchant, mapping.merchant_id), "user_mapping"

    # 8. Optional AI — not implemented; see REMAINING_WORK.txt
    return None, None


def remember_user_mapping(user_id, description, merchant_id):
    normalised = normalise(description)
    if not normalised:
        return
    existing = MerchantUserMapping.query.filter_by(user_id=user_id, description_text=normalised).first()
    if existing:
        existing.merchant_id = merchant_id
    else:
        db.session.add(MerchantUserMapping(user_id=user_id, description_text=normalised, merchant_id=merchant_id))
    db.session.commit()
