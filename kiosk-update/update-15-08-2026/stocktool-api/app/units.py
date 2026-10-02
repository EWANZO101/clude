"""
units.py — the single source of truth for stock measurement types and the
units available under each. Both app/api/units.py (JSON for the admin
builder's dropdowns) and app/models/item.py (validation) import from here
so the list can never drift between what the UI offers and what the model
accepts.
"""

MEASUREMENT_TYPES = ["count", "weight", "volume", "length"]

MEASUREMENT_LABELS = {
    "count": "Individual count",
    "weight": "Weight",
    "volume": "Volume",
    "length": "Length",
}

# code -> label, per measurement type
UNITS = {
    "count": [
        ("pcs", "Each / pcs"),
    ],
    "weight": [
        ("mg", "Milligrams (mg)"),
        ("g", "Grams (g)"),
        ("kg", "Kilograms (kg)"),
        ("oz", "Ounces (oz)"),
        ("lb", "Pounds (lb)"),
        ("t", "Tonnes (t)"),
    ],
    "volume": [
        ("ml", "Millilitres (ml)"),
        ("l", "Litres (l)"),
        ("fl_oz", "Fluid ounces (fl oz)"),
        ("gal", "Gallons (gal)"),
    ],
    "length": [
        ("mm", "Millimetres (mm)"),
        ("cm", "Centimetres (cm)"),
        ("m", "Metres (m)"),
        ("in", "Inches (in)"),
        ("ft", "Feet (ft)"),
    ],
}

DEFAULT_UNIT = {"count": "pcs", "weight": "g", "volume": "ml", "length": "cm"}

UNIT_LABEL_LOOKUP = {code: label for units in UNITS.values() for code, label in units}
VALID_UNIT_CODES = {code for units in UNITS.values() for code, _label in units}


def is_valid_unit_for(measurement_type: str, unit: str) -> bool:
    if measurement_type not in UNITS:
        return False
    return unit in {code for code, _label in UNITS[measurement_type]}


def normalise_measurement(measurement_type: str, unit: str):
    """Returns (measurement_type, unit) — falls back to 'count'/'pcs' if the
    given pair is missing or invalid, and fills a sensible default unit if
    the type is valid but no unit (or an invalid one) was given."""
    if measurement_type not in MEASUREMENT_TYPES:
        measurement_type = "count"
    if not unit or not is_valid_unit_for(measurement_type, unit):
        unit = DEFAULT_UNIT[measurement_type]
    return measurement_type, unit


def catalog() -> dict:
    """Full catalog for the frontend: types + labels + units per type."""
    return {
        "measurement_types": [
            {"value": t, "label": MEASUREMENT_LABELS[t], "default_unit": DEFAULT_UNIT[t]}
            for t in MEASUREMENT_TYPES
        ],
        "units": {
            t: [{"value": code, "label": label} for code, label in units]
            for t, units in UNITS.items()
        },
    }
