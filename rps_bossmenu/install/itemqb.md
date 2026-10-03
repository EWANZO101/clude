# Item Install Guide — qb-inventory / QBCore / QBox

rps_bossmenu uses 3 items. rps_bossmenu registers each item's "use" behavior
itself (via `exports.rps_lib:CreateUseableItem`) — you only need to **define
the items** below in your shared item list, nothing else to wire up (no
`QBCore.Functions.CreateUseableItem` calls needed on your end).

Add these to `qb-core/shared/items.lua` (or `qbx_core`'s items file):

```lua
['bill_tablet'] = {
    ['name'] = 'bill_tablet',
    ['label'] = 'Billing Tablet',
    ['weight'] = 1000,
    ['type'] = 'item',
    ['image'] = 'bill_tablet.png',
    ['unique'] = true,
    ['useable'] = true,
    ['shouldClose'] = true,
    ['combinable'] = nil,
    ['description'] = 'Used to access your business billing and invoicing tablet.'
},

['packaging'] = {
    ['name'] = 'packaging',
    ['label'] = 'Packaging Material',
    ['weight'] = 100,
    ['type'] = 'item',
    ['image'] = 'packaging.png',
    ['unique'] = false,
    ['useable'] = true,
    ['shouldClose'] = true,
    ['combinable'] = nil,
    ['description'] = 'Used to pack delivery boxes for shipment.'
},

['delivery_box'] = {
    ['name'] = 'delivery_box',
    ['label'] = 'Delivery Box',
    ['weight'] = 5000,
    ['type'] = 'item',
    ['image'] = 'delivery_box.png',
    ['unique'] = true,
    ['useable'] = true,
    ['shouldClose'] = true,
    ['combinable'] = nil,
    ['description'] = 'A sealed box of delivered goods. Use it to unpack the contents.'
},
```

## Notes

- `bill_tablet` — only needed if `Config.TabletItem` in `config.lua` is set to a
  string (it currently is: `'bill_tablet'`). If you set `Config.TabletItem = false`
  instead, players use the `/bill` command and don't need this item at all.
- `packaging` — consumed one-per-box when a seller packs a Jungle Shop order into
  a delivery box at the truck. Leave `['unique'] = false` so it can stack.
- `delivery_box` — **must stay `['unique'] = true`**. Each box carries its own
  contents as item metadata/info (`info.items`, set automatically by the
  resource when the box is created); a stackable/non-unique box would merge
  different boxes' contents together.
- Images: the `image` fields above assume you'll drop `bill_tablet.png`,
  `packaging.png`, and `delivery_box.png` into `qb-inventory/html/images` (or
  wherever your inventory serves item images from). This resource ships no
  images of its own — supply your own art, or reuse an existing image from
  your inventory by pointing `image` at that filename instead.
- `Config.InventoryImagePath` in `rps_bossmenu/config.lua` should be set to
  `'qb-inventory/html/images'` so the boss menu's own UI (item pickers, etc.)
  points at the same image folder.
