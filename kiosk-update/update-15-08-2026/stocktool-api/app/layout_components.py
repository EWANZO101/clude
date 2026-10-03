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


# ============================================================================
# Admin-panel surfaces (Items / Tools / Projects / Categories / Barcode Scan)
# ----------------------------------------------------------------------------
# Rendered server-side by stocktool-admin's Jinja templates, not by the
# kiosk's browse.js -- a completely separate catalog because admin pages
# have real CRUD functionality (filters that hit the DB, forms, a
# drag-reorder category list, a barcode scanner) that a generic
# component can't safely reinvent. Items/Tools/Projects are structurally
# near-identical list pages, so they get a full data_table treatment.
# Categories (drag-reorder + modals) and Barcode Scan (scanner input)
# keep their real interactive UI hardcoded -- only their header/intro
# text is customisable, via the same page_header/text_block components
# reused from the list pages.
# ============================================================================

ADMIN_SURFACES = {
    "admin_items": {"label": "Items Page", "entity": "items"},
    "admin_tools": {"label": "Tools Page", "entity": "tools"},
    "admin_projects": {"label": "Projects Page", "entity": "projects"},
    "admin_categories": {"label": "Categories Page", "entity": "categories"},
    "admin_barcode_scan": {"label": "Barcode Scan Page", "entity": None},
}

# Columns available per entity for the data_table component -- exactly the
# columns the original hand-written templates already showed, so picking
# "all of them, in this order" reproduces the original page exactly.
ADMIN_TABLE_COLUMNS = {
    "items": ["name", "sku", "category", "location", "quantity", "status"],
    "tools": ["name", "brand_model", "location", "status", "checked_out_by"],
    "projects": ["name", "code", "description"],
}

ADMIN_STAT_OPTIONS = {
    "items": [
        {"value": "total", "label": "Total items"},
        {"value": "low_stock", "label": "Low stock"},
        {"value": "out_of_stock", "label": "Out of stock"},
    ],
    "tools": [
        {"value": "total", "label": "Total tools"},
        {"value": "checked_out", "label": "Checked out"},
        {"value": "overdue", "label": "Overdue"},
    ],
    "projects": [
        {"value": "total", "label": "Total projects"},
    ],
    "categories": [
        {"value": "total", "label": "Total categories"},
    ],
}

ADMIN_COMPONENT_TYPES = {
    "page_header": {
        "label": "Page Header",
        "icon": "fa-solid fa-heading",
        "description": "Title, subtitle, and an optional 'Add' button.",
        "settings": [
            {"key": "title", "type": "text", "label": "Title", "default": ""},
            {"key": "subtitle", "type": "text", "label": "Subtitle", "default": ""},
            {"key": "icon", "type": "text", "label": "Icon (Font Awesome class)", "default": ""},
            {"key": "show_add_button", "type": "bool", "label": "Show 'Add' button", "default": True},
            {"key": "add_button_label", "type": "text", "label": "Add button label", "default": "Add"},
        ],
    },
    "stat_cards": {
        "label": "Stat Cards",
        "icon": "fa-solid fa-chart-simple",
        "description": "A row of summary numbers.",
        "settings": [
            {"key": "stats", "type": "stat_multi", "label": "Which stats to show", "default": []},
        ],
    },
    "filter_bar": {
        "label": "Filter Bar",
        "icon": "fa-solid fa-filter",
        "description": "Search and filter controls above the table.",
        "settings": [
            {"key": "show_search", "type": "bool", "label": "Show search box", "default": True},
            {"key": "show_category_filter", "type": "bool", "label": "Show category filter", "default": True},
            {"key": "show_status_filter", "type": "bool", "label": "Show status/stock filter", "default": True},
        ],
    },
    "data_table": {
        "label": "Data Table",
        "icon": "fa-solid fa-table",
        "description": "The main list, with the columns you choose (desktop table + mobile card list).",
        "settings": [
            {"key": "columns", "type": "column_multi", "label": "Columns to show, in order", "default": []},
        ],
    },
    "button_row": {
        "label": "Button Row",
        "icon": "fa-solid fa-table-cells",
        "description": "A row of custom action buttons.",
        "settings": [
            {"key": "buttons", "type": "button_list", "label": "Buttons", "default": []},
        ],
    },
    "text_block": {
        "label": "Text / Instructions",
        "icon": "fa-solid fa-align-left",
        "description": "Freeform heading + paragraph.",
        "settings": [
            {"key": "heading", "type": "text", "label": "Heading", "default": ""},
            {"key": "body", "type": "textarea", "label": "Body text", "default": ""},
        ],
    },
    "spacer": {
        "label": "Spacer",
        "icon": "fa-solid fa-arrows-up-down",
        "description": "Blank vertical gap.",
        "settings": [
            {"key": "height", "type": "select", "label": "Height", "default": "md",
             "options": ["sm", "md", "lg"]},
        ],
    },
}

# The safe default every admin surface starts from -- reproduces the
# original hand-written page as closely as the component set allows, so
# resetting a surface never leaves it broken or empty.
def default_admin_layout(surface: str) -> list:
    entity = ADMIN_SURFACES.get(surface, {}).get("entity")
    components = [
        {"id": "hdr-1", "type": "page_header", "size": "full", "visible": True,
         "settings": {"title": "", "subtitle": "", "icon": "", "show_add_button": True, "add_button_label": "Add"}},
    ]
    if entity in ("items", "tools"):
        components.append({"id": "filter-1", "type": "filter_bar", "size": "full", "visible": True,
                            "settings": {"show_search": True, "show_category_filter": True, "show_status_filter": True}})
    elif entity == "projects":
        components.append({"id": "filter-1", "type": "filter_bar", "size": "full", "visible": True,
                            "settings": {"show_search": True, "show_category_filter": False, "show_status_filter": False}})
    if entity in ADMIN_TABLE_COLUMNS:
        components.append({"id": "table-1", "type": "data_table", "size": "full", "visible": True,
                            "settings": {"columns": list(ADMIN_TABLE_COLUMNS[entity])}})
    return components


def admin_catalog(surface: str) -> dict:
    entity = ADMIN_SURFACES.get(surface, {}).get("entity")
    types = dict(ADMIN_COMPONENT_TYPES)
    # Categories/Barcode Scan keep their real interactive UI hardcoded --
    # only header/text/stats are customisable for those two surfaces.
    if entity not in ADMIN_TABLE_COLUMNS:
        types = {k: v for k, v in types.items() if k not in ("filter_bar", "data_table")}
    return {
        "sizes": SIZES,
        "surface": surface,
        "entity": entity,
        "table_columns": ADMIN_TABLE_COLUMNS.get(entity, []),
        "stat_options": ADMIN_STAT_OPTIONS.get(entity, []),
        "component_types": [{"type": t, **defn} for t, defn in types.items()],
    }


def validate_admin_layout(surface: str, components: list) -> list:
    entity = ADMIN_SURFACES.get(surface, {}).get("entity")
    valid_types = admin_catalog(surface)["component_types"]
    valid_type_names = {c["type"] for c in valid_types}
    valid_columns = set(ADMIN_TABLE_COLUMNS.get(entity, []))
    valid_stats = {s["value"] for s in ADMIN_STAT_OPTIONS.get(entity, [])}

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
        if ctype not in valid_type_names:
            errors.append(f"{pos} ({comp_id or 'no id'}): '{ctype}' isn't available on this page.")
            continue
        if comp.get("size") not in SIZES:
            errors.append(f"{pos} ({comp_id}): size must be one of {SIZES}.")

        settings = comp.get("settings") or {}
        if ctype == "data_table":
            bad = [c for c in (settings.get("columns") or []) if c not in valid_columns]
            if bad:
                errors.append(f"{pos} ({comp_id}): unknown columns {bad}.")
        if ctype == "stat_cards":
            bad = [s for s in (settings.get("stats") or []) if s not in valid_stats]
            if bad:
                errors.append(f"{pos} ({comp_id}): unknown stats {bad}.")

    return errors


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
