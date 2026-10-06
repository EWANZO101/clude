# Item Install Guide — ESX Legacy

rps_bossmenu uses 3 items. rps_bossmenu registers each item's "use" behavior
itself (via `exports.rps_lib:CreateUseableItem`) — you only need to **register
the items** below, nothing else to wire up (no `ESX.RegisterUsableItem` calls
needed on your end).

ESX Legacy needs items in two places: the `items` database table, and (if your
build uses the newer Lua item registry) `[esx]/es_extended/shared/items.lua`.

## 1. Database

```sql
INSERT INTO `items` (`name`, `label`, `weight`) VALUES
('bill_tablet', 'Billing Tablet', 1000),
('packaging', 'Packaging Material', 100),
('delivery_box', 'Delivery Box', 5000);
```

## 2. shared/items.lua (skip if your ESX build only uses the SQL table)

Add to `es_extended/shared/items.lua`:

```lua
{
    name = 'bill_tablet',
    label = 'Billing Tablet',
    weight = 1000,
    close = true,
    stack = true,
},
{
    name = 'packaging',
    label = 'Packaging Material',
    weight = 100,
    close = true,
    stack = true,
},
{
    name = 'delivery_box',
    label = 'Delivery Box',
    weight = 5000,
    close = true,
    stack = false,
},
```

## Notes

- `bill_tablet` — only needed if `Config.TabletItem` in `config.lua` is set to a
  string (it currently is: `'bill_tablet'`). If you set `Config.TabletItem = false`
  instead, players use the `/bill` command and don't need this item at all.
- `packaging` — consumed one-per-box when a seller packs a Jungle Shop order into
  a delivery box at the truck. Keep it stackable.
- `delivery_box` — **must not be stackable** (`stack = false`). Each box carries
  its own contents as item metadata (`info.items`, set automatically by the
  resource when the box is created); stacking would merge different boxes'
  contents together. If your ESX inventory front-end doesn't support
  per-item metadata, delivery boxes won't carry contents correctly — this is
  primarily built against metadata-capable inventories (ox_inventory,
  qs-inventory, qb-inventory); check with rps_lib's own docs for which ESX
  inventory front-ends it bridges metadata through.
- Images: this resource ships no item images of its own. Drop
  `bill_tablet.png`, `packaging.png`, and `delivery_box.png` into whatever
  folder your inventory HUD resource serves item images from (commonly
  something like `esx_inventoryhud/html/itemimages`, but this varies by which
  inventory front-end you run alongside ESX Legacy).
- `Config.InventoryImagePath` in `rps_bossmenu/config.lua` should be set to
  match that same image folder so the boss menu's own UI (item pickers, etc.)
  points at the right place.
