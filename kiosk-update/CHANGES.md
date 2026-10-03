# Builder Mode for admin pages — 2026-08-15

## What's new
Builder Mode now covers five more surfaces beyond the kiosk dashboard:
**Items, Tools, Projects, Categories, and Barcode Scan** — all editable
from the same drag-and-drop builder at `/builder/`, with the same
draft/publish safety model.

- **Items / Tools / Projects**: full redesign — page header, stat cards,
  filter bar, and a data table where you choose which columns show and
  in what order. These three are structurally near-identical list pages,
  so they share one rendering engine and one component catalog.
- **Categories / Barcode Scan**: header/intro text only. Their real
  interactive UI (drag-to-reorder categories, the barcode scanner input)
  stays as-is — those aren't things a no-code builder can safely
  reinvent without breaking real functionality, so only what's safe to
  customize is customizable.
- A **surface picker** at the top of Builder Mode switches between the
  kiosk dashboard and any of these five admin pages. Each surface has
  its own layouts, its own component catalog, and its own draft/publish
  state — completely independent of the others.
- Every admin page falls back to its original hand-written template
  automatically until you actually publish something for it — same
  "never break what's already working" pattern as the kiosk dashboard.

## Also fixed
`scripts/publish_unpublished_layouts.py` was too broad — it auto-published
*any* layout with nothing published yet, which was fine when the kiosk
default layout was the only thing that could be in that state, but now
that admin pages can have legitimate in-progress drafts, that's a real
risk (could publish someone's half-finished page redesign during a
routine deploy). Narrowed to only ever touch `is_default=True` layouts —
the one case where "still unpublished" is unambiguously a bug, not a
work in progress.

## Deploy
Same as before — `update-server.sh` needs no changes, since it already
copies the entire `app/`, `scripts/`, and `adminapp/` trees recursively:

```bash
scp kiosk-builder-update-15-08-2026.zip root@your-server:~/
ssh root@your-server
unzip kiosk-builder-update-15-08-2026.zip -d kiosk-update
STOCKTOOL_API_DIR=/path/to/stocktool-api \
STOCKTOOL_ADMIN_DIR=/path/to/stocktool-admin \
STOCKTOOL_API_SERVICE=stocktool-api \
STOCKTOOL_ADMIN_SERVICE=stocktool-admin \
./update-server.sh ~/kiosk-update/update-14-08-2026
```

## Verified before shipping
- Full live API round-trip test: created an `admin_items` layout,
  customized its columns, confirmed invalid columns get rejected,
  published it, confirmed `/api/layouts/resolve?surface=admin_items`
  returns exactly the customized layout
- Rendered every touched/new template (Items, Tools, Projects, Categories,
  Barcode Scan — both the fallback and the new-layout code paths) through
  the real Jinja environment and asserted the customized content actually
  appears in the output
- Both full Flask apps (`stocktool-api`, `stocktool-admin`) boot cleanly
  with every blueprint registered
- `builder.js` syntax-checked with Node
- The narrowed `publish_unpublished_layouts.py` tested against both a
  stale default layout (gets published) and a work-in-progress admin
  layout (correctly left alone)

## Bugs caught and fixed during this build (not shipped broken)
- A Jinja macro tried to return a Python dict for column metadata — macros
  only ever return rendered text, so this silently would have produced a
  string instead of a dict. Moved column metadata into a proper Python
  module instead.
- The shared macro import needed `with context` to see `current_user` —
  caught by actually rendering the templates, not just reading the code.
- The property-panel checkbox handler used `parseInt()` on all
  multi-select fields, which would have silently turned the new
  string-valued stat/column selections into `NaN`. Fixed to branch on
  value type.

## Known gap
There's no device-management UI yet (list of known kiosks, rename,
reassign layout) — device names are just whatever string was in the URL
when a kiosk terminal first connected. Per-device kiosk layouts already
work (set a device name when creating a layout in Builder Mode), just
without a management page around it.
