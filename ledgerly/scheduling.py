"""Turns payment-schedule-builder input into a concrete list of instalments."""
from datetime import date, timedelta
import calendar


def add_months(d: date, months: int, day_of_month: int | None = None) -> date:
    month_index = d.month - 1 + months
    year = d.year + month_index // 12
    month = month_index % 12 + 1
    day = day_of_month or d.day
    last_day = calendar.monthrange(year, month)[1]
    day = min(day, last_day)
    return date(year, month, day)


FREQUENCY_STEPS = {
    "weekly": ("days", 7),
    "biweekly": ("days", 14),
    "monthly": ("months", 1),
    "bimonthly": ("months", 2),
    "quarterly": ("months", 3),
}


def build_dates(frequency, start_date, num_instalments, day_of_month=None, custom_dates=None):
    """Return a list of `date` objects, one per instalment."""
    if frequency == "one_time":
        return [start_date]

    if frequency == "custom":
        return sorted(custom_dates or [start_date])

    unit, step = FREQUENCY_STEPS[frequency]
    dates = []
    for i in range(num_instalments):
        if unit == "days":
            dates.append(start_date + timedelta(days=step * i))
        else:
            dates.append(add_months(start_date, step * i, day_of_month))
    return dates


def build_amounts(amount_mode, total_amount, num_instalments, fixed_amount=None,
                   percentage=None, custom_amounts=None):
    """Return a list of Decimal-friendly floats, one per instalment, and any
    remaining balance not covered by the schedule."""
    if amount_mode == "custom":
        amounts = list(custom_amounts or [])
    elif amount_mode == "percentage":
        each = round(total_amount * (percentage / 100.0), 2)
        amounts = [each] * num_instalments
    else:  # fixed
        amt = fixed_amount if fixed_amount is not None else round(total_amount / num_instalments, 2)
        amounts = [amt] * num_instalments
        # push rounding remainder onto the final instalment so totals reconcile
        scheduled = round(amt * num_instalments, 2)
        remainder = round(total_amount - scheduled, 2)
        if amounts and remainder != 0 and fixed_amount is None:
            amounts[-1] = round(amounts[-1] + remainder, 2)

    remaining_balance = round(total_amount - sum(amounts), 2)
    return amounts, remaining_balance


def label_for(index, count):
    if count == 1:
        return "One-off payment"
    if index == 0:
        return "Deposit"
    if index == count - 1:
        return "Final payment"
    return None


def max_months_cutoff(start_date, max_months):
    """The latest a final instalment may fall, given a cap of `max_months`
    from the first payment date."""
    if not max_months:
        return None
    return add_months(start_date, max_months, day_of_month=start_date.day)
