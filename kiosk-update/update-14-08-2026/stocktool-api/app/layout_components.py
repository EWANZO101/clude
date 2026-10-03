"""
layout_components.py — the catalog of block types Builder Mode can place
on a kiosk dashboard, plus validation for a saved layout. Single source of
truth shared by:
  - app/api/layouts.py       (serves the catalog to the admin builder,
                               validates before publish)
  - app/kiosk/routes.py      (renders a published layout's components)
"""

SIZES = ["sm", "md", "lg", "full"]

# Every component type an admin can drop onto a layout. `settings` describes
# the editable fields Builder Mode's property panel renders for that block —
# kept data-driven so adding a new setting to a component never needs a
# matching hand-written form in the admin templates.
COMPONENT_TYPES = {
    "header": {
        "label": "Header",
        "icon": "fa-solid fa-heading",
        "description": "Welcome banner with a title, subtitle, and optional log-out button.",
        "settings": [
            {"key": "title", "type": "text", "label": "Title", "default": "Welcome"},
            {"key": "subtitle", "type": "text", "label": "Subtitle", "default": ""},
            {"key": "show_logout", "type": "bool", "label": "Show log-out button", "default": True},
        ],
    },
    "scan_panel": {
        "label": "Scan Panel",
        "icon": "fa-solid fa-barcode",
        "description": "The barcode-scan box used for quick stock removal.",
        "settings": [
            {"key": "hint", "type": "text", "label": "Placeholder text", "default": "Waiting for scan…"},
        ],
    },
    "category_grid": {
        "label": "Category Grid",
        "icon": "fa-solid fa-grip",
        "description": "Tappable tiles for chosen categories, showing item counts.",
        "settings": [
            {"key": "title", "type": "text", "label": "Section title", "default": "Browse Categories"},
            {"key": "category_ids", "type": "category_multi", "label": "Categories to show", "default": []},
            {"key": "columns", "type": "select", "label": "Columns", "default": "3",
             "options": ["2", "3", "4"]},
            {"key": "show_item_count", "type": "bool", "label": "Show item count", "default": True},
        ],
    },
    "item_grid": {
        "label": "Item Grid",
        "icon": "fa-solid fa-boxes-stacked",
        "description": "Cards for items in the chosen categories (or all items).",
        "settings": [
            {"key": "title", "type": "text", "label": "Section title", "default": "Items"},
            {"key": "category_ids", "type": "category_multi", "label": "Limit to categories (blank = all)", "default": []},
            {"key": "columns", "type": "select", "label": "Columns", "default": "3", "options": ["2", "3", "4", "5"]},
            {"key": "show_sku", "type": "bool", "label": "Show SKU", "default": False},
            {"key": "show_stock", "type": "bool", "label": "Show stock level", "default": True},
            {"key": "show_low_stock_badge", "type": "bool", "label": "Show low-stock badge", "default": True},
            {"key": "tap_action", "type": "select", "label": "Tap action", "default": "quick_remove",
             "options": ["quick_remove", "view_only"]},
        ],
    },
    "tool_grid": {
        "label": "Tool Grid",
        "icon": "fa-solid fa-wrench",
        "description": "Cards for tools in the chosen categories, showing checkout status.",
        "settings": [
            {"key": "title", "type": "text", "label": "Section title", "default": "Tools"},
            {"key": "category_ids", "type": "category_multi", "label": "Limit to categories (blank = all)", "default": []},
            {"key": "columns", "type": "select", "label": "Columns", "default": "3", "options": ["2", "3", "4", "5"]},
            {"key": "show_status", "type": "bool", "label": "Show status badge", "default": True},
        ],
    },
    "stock_summary": {
        "label": "Stock Summary",
        "icon": "fa-solid fa-chart-simple",
        "description": "KPI band: total items, low-stock count, out-of-stock count.",
        "settings": [
            {"key": "show_total_items", "type": "bool", "label": "Show total items", "default": True},
            {"key": "show_low_stock", "type": "bool", "label": "Show low-stock count", "default": True},
            {"key": "show_out_of_stock", "type": "bool", "label": "Show out-of-stock count", "default": True},
        ],
    },
    "button_row": {
        "label": "Button Row",
        "icon": "fa-solid fa-table-cells",
        "description": "A row of custom action buttons (e.g. Call for Help).",
        "settings": [
            {"key": "buttons", "type": "button_list", "label": "Buttons", "default": []},
        ],
    },
    "text_block": {
        "label": "Text / Instructions",
        "icon": "fa-solid fa-align-left",
        "description": "Freeform heading + paragraph, e.g. shop-floor instructions.",
        "settings": [
            {"key": "heading", "type": "text", "label": "Heading", "default": ""},
            {"key": "body", "type": "textarea", "label": "Body text", "default": ""},
        ],
    },
    "spacer": {
        "label": "Spacer",
        "icon": "fa-solid fa-arrows-up-down",
        "description": "Blank vertical gap for breathing room between sections.",
        "settings": [
            {"key": "height", "type": "select", "label": "Height", "default": "md",
             "options": ["sm", "md", "lg"]},
        ],
    },
}


def catalog() -> dict:
    return {
        "sizes": SIZES,
        "component_types": [
            {"type": t, **{k: v for k, v in defn.items()}}
            for t, defn in COMPONENT_TYPES.items()
        ],
    }


def validate_layout(components: list, valid_category_ids: set) -> list:
    """Returns a list of human-readable error strings. Empty list = valid.
    Deliberately permissive about *content* (an admin can leave a section
    empty while they build it out) and strict only about things that would
    make the kiosk render garbage or crash: unknown component types, and
    references to categories that no longer exist."""
    errors = []
    if not isinstance(components, list):
        return ["Layout must be a list of components."]

    seen_ids = set()
    for i, comp in enumerate(components):
        pos = f"Component #{i + 1}"
        if not isinstance(comp, dict):
            errors.append(f"{pos}: not a valid component object.")
            continue

        comp_id = comp.get("id")
        if not comp_id:
            errors.append(f"{pos}: missing an id.")
        elif comp_id in seen_ids:
            errors.append(f"{pos}: duplicate component id '{comp_id}'.")
        else:
            seen_ids.add(comp_id)

        ctype = comp.get("type")
        if ctype not in COMPONENT_TYPES:
            errors.append(f"{pos} ({comp_id or 'no id'}): unknown component type '{ctype}'.")
            continue

        if comp.get("size") not in SIZES:
            errors.append(f"{pos} ({comp_id}): size must be one of {SIZES}.")

        settings = comp.get("settings") or {}
        for field in COMPONENT_TYPES[ctype]["settings"]:
            if field["type"] == "category_multi":
                ids = settings.get(field["key"]) or []
                bad = [cid for cid in ids if cid not in valid_category_ids]
                if bad:
                    errors.append(
                        f"{pos} ({comp_id}): references categories that no longer exist: {bad}."
                    )

    return errors
