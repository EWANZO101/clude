"""MPG and cost-per-mile calculations.

Uses the standard "fill-to-full" method, since it's the only way to get an
accurate figure from pump receipts alone: a partial fill's litres don't
tell you how much fuel was actually burned since the previous fill, only a
full tank does. For each full-tank entry, we look back to the previous
full-tank entry and sum the litres of every entry in between (inclusive of
the current one) against the odometer distance covered — that total litre
figure represents everything burned over that distance, regardless of how
many partial top-ups happened along the way.

UK gallon = 4.54609 litres. MPG here always means UK ("imperial") MPG.
"""
LITRES_PER_UK_GALLON = 4.54609


def litres_to_uk_gallons(litres):
    return litres / LITRES_PER_UK_GALLON


def fill_to_full_stats(entries):
    """entries: FuelEntry list for one vehicle, already ordered by date then
    odometer ascending. Returns a list of dicts, one per full-tank entry
    (after the first with a known odometer), each with distance_miles,
    litres_used, mpg, cost_minor, cost_per_mile_minor."""
    entries = [e for e in entries if e.odometer is not None]
    if len(entries) < 2:
        return []

    results = []
    last_full_index = None
    for idx, e in enumerate(entries):
        if last_full_index is None:
            if e.full_tank:
                last_full_index = idx
            continue

        if not e.full_tank:
            continue  # accumulate — this entry's litres/cost get folded in when we hit the next full tank

        previous = entries[last_full_index]
        distance = e.odometer - previous.odometer
        interval_entries = entries[last_full_index + 1: idx + 1]
        litres_used = sum(x.litres or 0 for x in interval_entries)
        cost_minor = sum(x.cost_minor for x in interval_entries)

        if distance > 0 and litres_used > 0:
            gallons = litres_to_uk_gallons(litres_used)
            mpg = round(distance / gallons, 1)
            cost_per_mile_minor = round(cost_minor / distance, 1)
        else:
            mpg = None
            cost_per_mile_minor = None

        results.append({
            "date": e.date,
            "distance_miles": distance,
            "litres_used": round(litres_used, 2),
            "cost_minor": cost_minor,
            "mpg": mpg,
            "cost_per_mile_minor": cost_per_mile_minor,
        })
        last_full_index = idx

    return results


def vehicle_summary(entries):
    """Aggregate MPG/cost-per-mile averages plus total spend/litres for a vehicle."""
    fills = fill_to_full_stats(entries)
    valid_mpg = [f["mpg"] for f in fills if f["mpg"] is not None]
    valid_cpm = [f["cost_per_mile_minor"] for f in fills if f["cost_per_mile_minor"] is not None]

    return {
        "average_mpg": round(sum(valid_mpg) / len(valid_mpg), 1) if valid_mpg else None,
        "average_cost_per_mile_minor": round(sum(valid_cpm) / len(valid_cpm), 1) if valid_cpm else None,
        "total_spent_minor": sum(e.cost_minor for e in entries),
        "total_litres": round(sum(e.litres or 0 for e in entries), 2),
        "entry_count": len(entries),
        "fills": list(reversed(fills)),  # most recent first for display
    }
