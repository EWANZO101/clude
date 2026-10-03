from datetime import datetime, date


def hydrate(obj: dict, fields: list, date_fields: list = None):
    """Mutates obj in place, converting the given ISO-8601 string fields
    (as returned by the API's to_dict() methods) back into real datetime
    objects, so Jinja templates can keep calling .strftime()/.isoformat()
    on them exactly like they did back when this app queried the DB
    directly. `date_fields` are parsed as date-only (e.g. Tool.purchase_date)
    rather than full datetimes."""
    if not obj:
        return obj
    for field in fields:
        value = obj.get(field)
        if isinstance(value, str):
            try:
                obj[field] = datetime.fromisoformat(value)
            except ValueError:
                pass
    for field in date_fields or []:
        value = obj.get(field)
        if isinstance(value, str):
            try:
                obj[field] = date.fromisoformat(value)
            except ValueError:
                pass
    return obj


def hydrate_list(items: list, fields: list, date_fields: list = None):
    for item in items or []:
        hydrate(item, fields, date_fields)
    return items
