# opslabs-pos items

The source of truth is `source.lua` in this folder — edit that first, then keep the three files below in step with
it by hand (same pattern as `opslabs-bodycam/items/`).

| File | For |
|---|---|
| `ox_inventory.lua` | paste the entries into `ox_inventory/data/items.lua` |
| `esx_items.sql` | run once on your database (ESX `items` table) |
| `qb_items.lua` | add to `qb-core/shared/items.lua` |

**1 item.** Image: name it `ops_receipt.png` in your inventory's image folder.

| Item | Config field | What it does |
|---|---|---|
| `ops_receipt` | `Config.ReceiptItem` | given after a till sale, when the store has a printer |

**Worth knowing:** on ox_inventory, each receipt carries real per-sale metadata — store name, itemised lines,
total (`server/main.lua`, `exports.ox_inventory:AddItem(target, Config.ReceiptItem, 1, meta)`). Without
ox_inventory (the ESX/QB item-table fallback, `FW.AddItem`), that metadata isn't attached — every copy looks
identical, just "Receipt." That's a limitation of this item catalog approach generally, not something regenerating
these files changes.

## Adding a new item

1. Add it to `source.lua`.
2. Add the matching line to `ox_inventory.lua`, `esx_items.sql` and `qb_items.lua`.
3. Point `Config.<whatever>Item` at it in `opslabs-pos/config.lua` and read it the way `Config.ReceiptItem` already is.
4. Re-paste/re-run the three generated files per the table above.
