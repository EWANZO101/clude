# opslabs-bodycam items

The source of truth is `source.lua` in this folder — edit that first, then keep the three files below in step with
it by hand (there's no build script, same as opslabs-phone's own `items/` folder, which this one follows).

| File | For |
|---|---|
| `ox_inventory.lua` | paste the entries into `ox_inventory/data/items.lua` |
| `esx_items.sql` | run once on your database (ESX `items` table) |
| `qb_items.lua` | add to `qb-core/shared/items.lua` |

**3 items**, all read by name from `opslabs-bodycam/config.lua` — don't rename a key without updating the matching
`Config.*` field, or any saved inventories that already hold one:

| Item | Config field | What it does |
|---|---|---|
| `bodycam` | `Config.Access.Item` | the access-gate item (modes `item` / `job_and_item` / `job_or_item`) |
| `ops_vest` | `Config.Vest.Item` | the clothing item — wears `opslabs_vest_black` with the camera clipped on |
| `dash_cam` | *(none yet)* | matches the separate `Config.LiveStream` ("OPS DASH CAM") feature, which is currently command/export-gated only — see below |

Images: name them `<item>.png` in your inventory's image folder (`bodycam.png`, `ops_vest.png`, `dash_cam.png`).

## Adding a new item

1. Add it to `source.lua` with all the fields the existing entries have (this keeps the table a useful reference
   even though it isn't machine-read).
2. Add the matching line to `ox_inventory.lua`, `esx_items.sql` and `qb_items.lua`.
3. If it should gate a feature, add an `Item = '<key>'` field to the relevant `Config.*` block in
   `opslabs-bodycam/config.lua` and read it the same way `Config.Access.Item` / `Config.Vest.Item` already are.
4. Re-paste/re-run the three generated files per the table above.

## `dash_cam` is a freebie, not a requirement

`Config.LiveStream` (the real-time feed to Xon Sight's `/live` page, separate from recorded evidence uploads) has
no item check at all right now — anyone with the right job/command/MDT access can start it. If you want it to also
require carrying `dash_cam`, add this to `opslabs-bodycam/config.lua`:

```lua
Config.LiveStream = {
    Item = 'dash_cam',   -- add this line
    Command = 'dashcam',
    ...
}
```

...and check it in `server/main.lua` the same way the `Config.Access.Item` check already works there — this repo
doesn't do that for you, since it changes who can go live, not just what's in the item catalog.
