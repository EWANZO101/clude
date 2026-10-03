"""
layout_columns.py — column metadata for the Items/Tools/Projects
data_table component (see _layout_blocks.html's render_data_table).
Kept in Python, not Jinja, because a Jinja macro can't return a real
dict object — its output is always rendered text. Routes import
COLUMN_META[entity] and pass it into the template context directly.
"""

COLUMN_META = {
    "items": {
        "name":     {"label": "Name", "align": "left", "hide_tablet": False},
        "sku":      {"label": "SKU", "align": "left", "hide_tablet": True},
        "category": {"label": "Category", "align": "left", "hide_tablet": True},
        "location": {"label": "Location", "align": "left", "hide_tablet": False},
        "quantity": {"label": "Qty", "align": "center", "hide_tablet": False},
        "status":   {"label": "Status", "align": "center", "hide_tablet": False},
    },
    "tools": {
        "name":            {"label": "Tool", "align": "left", "hide_tablet": False},
        "brand_model":     {"label": "Brand / Model", "align": "left", "hide_tablet": True},
        "location":        {"label": "Location", "align": "left", "hide_tablet": True},
        "status":          {"label": "Status", "align": "center", "hide_tablet": False},
        "checked_out_by":  {"label": "Checked Out By", "align": "left", "hide_tablet": False},
    },
    "projects": {
        "name":        {"label": "Name", "align": "left", "hide_tablet": False},
        "code":        {"label": "Code", "align": "left", "hide_tablet": True},
        "description": {"label": "Description", "align": "left", "hide_tablet": False},
    },
}
