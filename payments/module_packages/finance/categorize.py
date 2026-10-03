"""Deterministic categorisation: user rules -> keyword defaults. Corrections
create/update a rule automatically so the same merchant is remembered next time.
AI-assisted categorisation is an optional later layer (Part 9) — this
rules-based pass runs first per the matching-order principle in the spec.
"""
from app.extensions import db
from .models import FinanceCategory, FinanceCategoryRule

DEFAULT_CATEGORY_KEYWORDS = {
    "Groceries": ["tesco", "sainsbury", "asda", "aldi", "lidl", "morrisons", "waitrose", "co-op", "coop"],
    "Restaurants": ["restaurant", "deliveroo", "just eat", "uber eats", "nando", "mcdonald", "kfc", "burger king"],
    # Kept in sync with fuel.stats.UK_FUEL_KEYWORDS (duplicated deliberately --
    # that module can't import this one, and this one shouldn't depend on an
    # optional module -- but the brand list should match so a transaction
    # that fuel.stats recognises as a forecourt purchase also lands in the
    # Fuel category here, not just gets pulled into the Fuel module unlabelled).
    "Fuel": [
        "shell", "esso", " bp ", "bp fuel", "texaco", "petrol", "diesel", "fuel",
        "gulf", "murco", "applegreen", "moto services", "moto motorway", "jet garage",
        "asda fuel", "asda petrol", "tesco fuel", "tesco petrol",
        "sainsburys fuel", "sainsburys petrol", "morrisons fuel", "morrisons petrol",
        "costco fuel", "m&s fuel",
    ],
    "Transport": ["uber", "trainline", "tfl", "bus", "taxi", "parking"],
    "Bills": ["direct debit", "council tax", "water board", "energy", "octopus", "british gas"],
    "Entertainment": ["netflix", "spotify", "disney", "cinema", "prime video"],
    "Shopping": ["amazon", "ebay", "argos", "next", "ikea"],
    "Income": ["salary", "payroll", "wages"],
}


def ensure_default_categories(user_id):
    existing = {c.name for c in FinanceCategory.query.filter(
        (FinanceCategory.user_id == user_id) | (FinanceCategory.user_id.is_(None))
    ).all()}
    created = False
    for name in list(DEFAULT_CATEGORY_KEYWORDS.keys()) + ["Other"]:
        if name not in existing:
            db.session.add(FinanceCategory(user_id=user_id, name=name))
            created = True
    if created:
        db.session.commit()


def suggest_category(user_id, description):
    description_lower = (description or "").lower()

    rule = FinanceCategoryRule.query.filter_by(user_id=user_id).filter(
        FinanceCategoryRule.match_text.isnot(None)
    ).all()
    for r in rule:
        if r.match_text.lower() in description_lower:
            return r.category_id

    for category_name, keywords in DEFAULT_CATEGORY_KEYWORDS.items():
        if any(k in description_lower for k in keywords):
            category = FinanceCategory.query.filter_by(user_id=user_id, name=category_name).first()
            if category:
                return category.id
    return None


def remember_correction(user_id, description, category_id):
    match_text = (description or "").strip().lower()[:100]
    if not match_text:
        return
    existing = FinanceCategoryRule.query.filter_by(user_id=user_id, match_text=match_text).first()
    if existing:
        existing.category_id = category_id
    else:
        db.session.add(FinanceCategoryRule(
            user_id=user_id, match_text=match_text, category_id=category_id, created_from_correction=True
        ))
    db.session.commit()
