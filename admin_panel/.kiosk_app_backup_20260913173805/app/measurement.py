"""Measurement-kind registry for the generic inventory type system (Track 2
of /root/.claude/plans/sprightly-meandering-whisper.md). A plain Python
constant, not a DB table — new units get added here in code, matching the
"additional units can be added in the future" requirement without needing
its own admin UI.

Duplicated verbatim in /root/admin_panel/app/measurement.py per
OWNERSHIP.md's "duplicate small shared constants, never cross-import"
convention (same as SIDEBAR_ITEMS/EQUIPMENT_* elsewhere in this codebase).
Keep the two files identical if either changes.
"""

MEASUREMENT_KINDS = {
    "count": {
        "label": "Count",
        "base_unit": "ea",
        "units": {
            "ea": {"label": "each", "factor": 1.0},
        },
    },
    "weight": {
        "label": "Weight",
        "base_unit": "g",
        "units": {
            "g": {"label": "grams", "factor": 1.0},
            "kg": {"label": "kilograms", "factor": 1000.0},
            "oz": {"label": "ounces", "factor": 28.349523125},
            "lb": {"label": "pounds", "factor": 453.59237},
        },
    },
    "length": {
        "label": "Length",
        "base_unit": "mm",
        "units": {
            "mm": {"label": "millimeters", "factor": 1.0},
            "cm": {"label": "centimeters", "factor": 10.0},
            "m": {"label": "meters", "factor": 1000.0},
            "in": {"label": "inches", "factor": 25.4},
            "ft": {"label": "feet", "factor": 304.8},
        },
    },
    "volume": {
        "label": "Volume",
        "base_unit": "ml",
        "units": {
            "ml": {"label": "milliliters", "factor": 1.0},
            "l": {"label": "liters", "factor": 1000.0},
            "gal": {"label": "gallons (US)", "factor": 3785.411784},
        },
    },
    "area": {
        "label": "Area",
        "base_unit": "cm2",
        "units": {
            "cm2": {"label": "square cm", "factor": 1.0},
            "m2": {"label": "square meters", "factor": 10000.0},
            "ft2": {"label": "square feet", "factor": 929.0304},
        },
    },
    "custom": {
        "label": "Custom",
        "base_unit": None,
        "units": {},
    },
}


def kind_for_unit(unit):
    """Which measurement kind a given unit key belongs to, or None."""
    for kind, spec in MEASUREMENT_KINDS.items():
        if unit in spec["units"]:
            return kind
    return None


def unit_choices(kind):
    """[(unit_key, label), ...] for a <select>, in registry order."""
    spec = MEASUREMENT_KINDS.get(kind)
    if not spec:
        return []
    return [(key, u["label"]) for key, u in spec["units"].items()]


def convert(value, from_unit, to_unit):
    """Converts `value` from `from_unit` to `to_unit`. Returns None if the
    two units aren't both known units of the same measurement kind — the
    caller's job (per the plan's "existing data should be preserved" rule)
    is to keep the original value/unit visible rather than losing it when
    this returns None, not to raise."""
    if value is None:
        return None
    if from_unit == to_unit:
        return value
    kind = kind_for_unit(from_unit)
    if kind is None or kind_for_unit(to_unit) != kind:
        return None
    units = MEASUREMENT_KINDS[kind]["units"]
    base_value = value * units[from_unit]["factor"]
    return base_value / units[to_unit]["factor"]
