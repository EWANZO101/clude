# Item Install Guide — ox_inventory

rps_bossmenu uses 3 items. rps_bossmenu registers each item's "use" behavior itself
(via `exports.rps_lib:CreateUseableItem`) — you only need to **define the items**
below in your inventory, nothing else to wire up.

Add these to `ox_inventory/data/items.lua`:

```lua
['bill_tablet'] = {
    label = 'Billing Tablet',
    weight = 1000,
    stack = true,
    close = true,
    description = 'Used to access your business billing and invoicing tablet.',
    client = {
        image = 'bill_tablet.png',
    }
},

['packaging'] = {
    label = 'Packaging Material',
    weight = 100,
    stack = true,
    close = true,
    description = 'Used to pack delivery boxes for shipment.',
    client = {
        image = 'packaging.png',
    }
},

['delivery_box'] = {
    label = 'Delivery Box',
    weight = 5000,
    stack = false,
    close = true,
    description = 'A sealed box of delivered goods. Use it to unpack the contents.',
    client = {
        image = 'delivery_box.png',
    }
},
```

## Notes

- `bill_tablet` — only needed if `Config.TabletItem` in `config.lua` is set to a
  string (it currently is: `'bill_tablet'`). If you set `Config.TabletItem = false`
  instead, players use the `/bill` command and don't need this item at all.
- `packaging` — consumed one-per-box when a seller packs a Jungle Shop order into
  a delivery box at the truck.
- `delivery_box` — **must not be stackable** (`stack = false`). Each box carries
  its own contents as item metadata (`info.items`, set automatically by the
  resource when the box is created); stacking would merge different boxes'
  contents together.
- Images: `client.image` above assumes you'll drop `bill_tablet.png`,
  `packaging.png`, and `delivery_box.png` into `ox_inventory/web/images`. This
  resource ships no images of its own — supply your own art, or reuse an
  existing image from your inventory by pointing `image` at that filename
  instead.
- `Config.InventoryImagePath` in `rps_bossmenu/config.lua` should be set to
  `'ox_inventory/web/images'` so the boss menu's own UI (item pickers, etc.)
  points at the same image folder.
