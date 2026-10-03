"""A deliberately simple, explainable categorisation suggester. This is NOT
a black-box ML model — it's a transparent keyword-matching heuristic so
every suggestion can be explained in one sentence, which matters more than
raw accuracy for a first version of an "AI feature" that must never
silently change financial records (rule #53 in the spec: AI suggestions
must be reviewable and require confirmation).

A real version would swap this function's body for a model call while
keeping the exact same contract: return a ranked list of
(account, confidence, reason), never write anything to the database itself.
"""

KEYWORD_RULES = [
    (["uber", "lyft", "taxi", "gas station", "fuel", "parking"], "6000", "Travel-related keyword matched"),
    (["aws", "azure", "google cloud", "hosting", "server"], "6000", "Cloud/hosting keyword matched"),
    (["payroll", "salary", "wages"], "6100", "Payroll keyword matched"),
    (["bank fee", "wire fee", "overdraft", "service charge"], "6200", "Bank fee keyword matched"),
    (["office", "supplies", "staples", "paper"], "6000", "Office supplies keyword matched"),
    (["rent", "lease"], "6000", "Rent/lease keyword matched"),
]


def suggest_category(description, business_id):
    """Returns a list of {account_code, confidence, reason} suggestions,
    highest confidence first. Confidence here is intentionally coarse
    (matched/not matched) rather than a fabricated precise-looking number,
    since the underlying method genuinely can't support more precision."""
    if not description:
        return []

    text = description.lower()
    matches = []
    for keywords, account_code, reason in KEYWORD_RULES:
        if any(k in text for k in keywords):
            matches.append({"account_code": account_code, "confidence": "likely", "reason": reason})

    return matches


def suggest_category_for_business(description, business):
    """Resolves suggested account codes to real Account rows for this
    business (a code might not exist if the chart of accounts was
    customised), and never returns an account from another business."""
    from app.models.accounting import Account

    suggestions = suggest_category(description, business.id)
    resolved = []
    for s in suggestions:
        account = Account.query.filter_by(business_id=business.id, code=s["account_code"], is_archived=False).first()
        if account:
            resolved.append({"account": account, "confidence": s["confidence"], "reason": s["reason"]})
    return resolved
