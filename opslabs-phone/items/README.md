# OPS inventory items (items mode)

Only needed when `Config.Work.Mode = 'items'` (opslabs-phone/config.lua, or OPS Hub → Settings → Quick settings → Play mode).
In standalone mode (the default) nothing here is used.

| File | For |
|---|---|
| `ox_inventory.lua` | paste the entries into `ox_inventory/data/items.lua` |
| `esx_items.sql` | run once on your database (ESX `items` table) |
| `qb_items.lua` | add to `qb-core/shared/items.lua` |

**55 items:** every stock part (`ops_<sku>`, `-` becomes `_`, e.g. `ops_cam_ip`, `ops_cat6`) and every tool / PPE
from the job guides (`ops_crimper`, `ops_ladder`, `ops_hivis` …). Images: name them `<item>.png` in your inventory's image folder.

How they're used:
- **Depot** (`Config.Work.Depots`, blip + [E]): engineers collect the tools & PPE their accepted jobs need, and the job's parts
  (taken out of the company's stock on OPS Hub → company → Stock).
- **Starting / completing a job** needs the job family's tools in your inventory; completing uses up the consumable parts.
- **Placing kit from /towers** uses the matching item (`Config.Work.ModelItems`: model → sku); removing kit gives it back.
- **Risk assessment**: PPE you tick must be in your inventory.

If you change the item prefix (`Config.Work.ItemPrefix`) or add stock lines, regenerate these files (or rename the entries).
