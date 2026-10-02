"""
Stock audit generation -- the actual "count everything and record what
changed" logic. Kept separate from audit_scheduler.py (the timing/
when-to-run-it logic) so both are independently testable, and so a
financial user's "run now" button can call the exact same function the
scheduler uses rather than a parallel code path.

Discrepancy definition (documented here since it's a judgment call,
not something the kiosk has an "expected stock level" to check
against): a day audit's discrepancy for an item is simply
current_quantity - quantity_at_previous_day_audit. Any change --
up or down -- is recorded as a discrepancy for a human to review;
this system has no purchase-order/restock-expectation data to
distinguish "expected" restocking from "unexplained" loss, so it
surfaces every change rather than silently assuming increases are
fine and only flagging decreases.

Month/year audits don't re-snapshot quantities directly -- they roll
up the day audits that fall inside that period: total_quantity is
the snapshot from the LAST day audit in the period, discrepancy_count
and net_quantity_change are summed from every day audit's own numbers
within that period. A month/year audit is therefore only as complete
as the day audits under it -- a month with gaps in its daily coverage
still produces a rollup, just from whatever days were actually run.
"""
from datetime import date

from app.models import db, Item, AuditRun, AuditItemRecord


def _previous_quantities(before_period_key):
    """Returns {item_id: quantity_at_audit} from the most recent DAY
    audit strictly before the given period_key, or {} if there isn't
    one yet (e.g. this is the very first audit ever)."""
    prior_run = (
        AuditRun.query
        .filter(AuditRun.period_type == AuditRun.PERIOD_DAY, AuditRun.period_key < before_period_key)
        .order_by(AuditRun.period_key.desc())
        .first()
    )
    if not prior_run:
        return {}
    return {r.item_id: r.quantity_at_audit for r in prior_run.records if r.item_id is not None}


def run_day_audit(day: date, is_backfill: bool = False) -> AuditRun:
    """Generates (or returns the existing) day audit for the given
    date. Idempotent -- calling this twice for the same day returns
    the already-recorded run rather than duplicating it, since the
    unique constraint on (period_type, period_key) backs that up."""
    period_key = day.isoformat()
    existing = AuditRun.query.filter_by(period_type=AuditRun.PERIOD_DAY, period_key=period_key).first()
    if existing:
        return existing

    previous = _previous_quantities(period_key)
    items = Item.query.all()

    run = AuditRun(period_type=AuditRun.PERIOD_DAY, period_key=period_key, is_backfill=is_backfill)
    db.session.add(run)
    db.session.flush()

    total_quantity = 0
    discrepancy_count = 0
    net_change = 0
    for item in items:
        prev_qty = previous.get(item.id)
        discrepancy = (item.quantity - prev_qty) if prev_qty is not None else None
        record = AuditItemRecord(
            audit_run_id=run.id, item_id=item.id, item_name=item.name, sku=item.sku,
            quantity_at_audit=item.quantity, previous_quantity=prev_qty, discrepancy=discrepancy,
        )
        db.session.add(record)
        total_quantity += item.quantity
        if discrepancy:
            discrepancy_count += 1
            net_change += discrepancy

    run.total_items = len(items)
    run.total_quantity = total_quantity
    run.discrepancy_count = discrepancy_count
    run.net_quantity_change = net_change
    db.session.commit()
    return run


def _rollup_period(period_type: str, period_key: str, day_runs: list[AuditRun]) -> AuditRun:
    existing = AuditRun.query.filter_by(period_type=period_type, period_key=period_key).first()
    if existing:
        return existing
    if not day_runs:
        return None

    run = AuditRun(period_type=period_type, period_key=period_key, is_backfill=False)
    db.session.add(run)
    db.session.flush()

    # Net discrepancy per item, summed across every day audit in the period.
    per_item_net = {}
    per_item_name_sku = {}
    for day_run in day_runs:
        for rec in day_run.records:
            if rec.discrepancy:
                per_item_net[rec.item_id] = per_item_net.get(rec.item_id, 0) + rec.discrepancy
            per_item_name_sku[rec.item_id] = (rec.item_name, rec.sku)

    last_day_run = max(day_runs, key=lambda r: r.period_key)
    last_quantities = {r.item_id: r.quantity_at_audit for r in last_day_run.records}
    first_day_run = min(day_runs, key=lambda r: r.period_key)
    first_quantities = {r.item_id: r.previous_quantity for r in first_day_run.records}

    for item_id, (name, sku) in per_item_name_sku.items():
        db.session.add(AuditItemRecord(
            audit_run_id=run.id, item_id=item_id, item_name=name, sku=sku,
            quantity_at_audit=last_quantities.get(item_id, 0),
            previous_quantity=first_quantities.get(item_id),
            discrepancy=per_item_net.get(item_id, 0) or None,
        ))

    run.total_items = len(per_item_name_sku)
    run.total_quantity = sum(last_quantities.values())
    run.discrepancy_count = sum(1 for v in per_item_net.values() if v)
    run.net_quantity_change = sum(per_item_net.values())
    db.session.commit()
    return run


def run_month_audit(year: int, month: int) -> AuditRun | None:
    """Rolls up every day audit within the given month. Returns None
    (creates nothing) if there are no day audits for that month yet --
    a month rollup with zero underlying data isn't meaningful."""
    period_key = f"{year:04d}-{month:02d}"
    prefix = period_key + "-"
    day_runs = AuditRun.query.filter(
        AuditRun.period_type == AuditRun.PERIOD_DAY,
        AuditRun.period_key.like(prefix + "%"),
    ).all()
    return _rollup_period(AuditRun.PERIOD_MONTH, period_key, day_runs)


def run_year_audit(year: int) -> AuditRun | None:
    """Rolls up every month audit within the given year."""
    period_key = f"{year:04d}"
    month_runs = AuditRun.query.filter(
        AuditRun.period_type == AuditRun.PERIOD_MONTH,
        AuditRun.period_key.like(period_key + "-%"),
    ).all()
    # Reuse the same rollup helper by treating month runs as the input
    # "day_runs" list -- it only relies on .records/.period_key/.id,
    # which month runs have identically.
    return _rollup_period(AuditRun.PERIOD_YEAR, period_key, month_runs)
