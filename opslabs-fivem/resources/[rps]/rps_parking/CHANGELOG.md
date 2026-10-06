# Changelog

## v1.0.3 - 2026-09-23

### Renamed
- Resource renamed from `adv_parking` to `rps_parking` — folder, `fxmanifest.lua` name, exports (`exports.rps_parking:...`), callbacks/events, context menu ids, the `rps_parking_taken` GlobalState key and console log prefix. ACE permissions are now `rps_parking.admin` and `rps_parking.police` — re-add them in `server.cfg`. The `advanced_parking` / `parking_logs` tables are unchanged, so existing parked vehicles are kept.

### rps_lib migration
- Framework and notifications now go through `rps_lib` (ESX / QBCore / QBox / standalone). `bridge/server.lua` is a thin wrapper around `exports.rps_lib:...` (identifier, job, name, money, admin check) and the new `bridge/client.lua` handles client notifications. QBox is now supported (`player_vehicles` ownership check).
- `Config.Framework` removed — force a framework with `setr rps_lib:forceFramework "esx"` instead. Added `dependency 'rps_lib'` to `fxmanifest.lua`.
- All notifications (server + client) use `rps_lib`'s `ShowNotification` instead of calling `ox_lib:notify` directly.

### Parking machine
- Unparking moved to a parking machine prop (`prop_park_ticket_01`) at each lot. Target it (ox_target / qb-target / tgiann-target via `rps_lib`, or `[E]` when no target script is installed) to see your cars parked at that lot with bay, time parked and amount due, then pay and unlock them.
- The server checks the player is at that lot's machine and owns the car; a car that was deleted (car-wipe) is respawned with its mods before it's released.
- `/unpark` removed, and the park key no longer unparks.
- New `Config.ParkingMachine` (model, label, icon, distance).

### Park key
- `Config.ParkKey` changed from `F7` to `E`. Players who already bound the key keep their own binding.
- The key only parks, and only works while driving inside a parking lot — elsewhere it does nothing. A `[E] Park vehicle – <lot>` hint shows when you drive into a lot. `/park` still tells you when you're not in a lot.

### Lot editor (admin)
- New in-game lot editor: `/parkadmin` → **Lot editor**.
  - **Draw zone** — laser-draw the lot's box (2 opposite corners) or any polygon (3+ corners).
  - **Place parking machine** — ghost prop follows the laser, scroll/Q to rotate.
  - **Bays** — ghost car follows the laser (green = OK, red = too close / outside the zone); place, rotate, delete the aimed bay, undo, and fill a whole row between two bays.
  - Edit name, price per hour, max fee and blip; teleport to the lot; save; delete.
- Changes go live for every player without a restart (blips, machines, target zones, bay markers).
- Parked cars keep their bay when bays are renumbered; bays with a parked car can't be removed or moved, and a lot with parked cars can't be deleted.
- Parking now checks the lot's drawn zone (lots without a zone use their coords + radius).
- `ghostModel` and `bayMinGap` added to `Config.Admin`.
- Lot edits and deletions are written to the activity log (`admin_lot`).

### Parking lots in the database
- `Config.ParkingLots` removed from `config.lua` — all lots are stored in the new `ParkingLots` table (`name`, `label`, `price_per_hour`, `max_fee`, `blip`, `coords`, `radius`, `machine`, `zone`, `spots`). The table is created automatically; on first start it is seeded with the Legion Square and Del Perro Pier lots, and any lots from the earlier `parking_lots` table are imported.
- Lots are synced to clients through GlobalState (`rps_parking_lots`).

### Removed
- `/unpark` command.
- Bay recorder commands (`/bayadd`, `/bayrow`, `/bayundo`, `/baysave`, `/bayclear`) — replaced by the lot editor. `/parkspot` is kept.

### Notes
- The old `parking_lots` table is no longer used and can be dropped once you've confirmed your lots were imported into `ParkingLots`.
- E is also the vehicle horn in GTA, so parking with E inside a lot will honk.
