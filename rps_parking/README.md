# rps_parking – Advanced Persistent Parking for FiveM

Park your car in a marked bay at a parking lot and it stays there – across relogs and server restarts – with all mods, colours, damage and fuel.

## Features
- Real-world persistent parking (server-side spawned, OneSync, survives restarts)
- Auto-respawn watchdog if a parked car is deleted (car-wipes, crashes)
- Parked cars are locked + frozen (no pushing/stealing)
- Parking lots with individual bays: green/red bay markers while driving, one car per bay
- Cars are snapped straight into the bay (forward or reverse parking)
- Paid lots (per-hour, capped) or free lots
- Parking machine prop at each lot: target it to see your cars parked there, pay and unlock them (a red arrow then shows above your car until you get in)
- `/parkspot` dev tool to build bays in-game
- **Parking logistics:** every park, unpark, ticket, impound and staff action is logged to the database (optional Discord webhook)
- **Admin panel** (`/parkadmin`): revenue today / 7 days, live occupancy per lot, outstanding fees, bay-by-bay view, plate search with full history, impound management
- Police (`Config.PoliceJobs`): target a parked car to write a parking ticket or impound it, with owner notifications
- Impound lot with release fees; abandoned cars auto-impounded after X days
- `/parked` menu with waypoints to your cars
- Per-player parking limit, ownership checks, anti-duplication
- QBCore / QBox / ESX / Standalone support and notifications via `rps_lib`

## Requirements
- OneSync enabled
- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)
- `rps_lib` (framework + notification bridge)

## Install
1. Drop `rps_parking` into your resources folder.
2. (Optional) run `sql/install.sql` – the tables are also created automatically, and the two example lots are added to `ParkingLots` on first start.
3. Add to `server.cfg` **after** ox_lib, oxmysql, your framework and rps_lib:
   ```
   ensure rps_lib
   ensure rps_parking
   ```
   The framework is auto-detected by rps_lib. To force one: `setr rps_lib:forceFramework "esx"`.
4. Edit `config.lua` (key, fees, impound, key-system hook in `Config.GiveKeys`).
5. Set up your parking lots in-game with the lot editor (below).

## Lot editor (in-game, admins)
`/parkadmin` → **Lot editor** – all parking lots (name, prices, blip, zone, machine and bays) are stored in the `ParkingLots` database table and update live for everyone.

1. **Create new lot** – enter an ID, name, price per hour, max fee and blip.
2. **Draw zone** – aim the laser at the ground: `E` add corner, `X` undo, `DEL` clear, `ENTER` done. 2 corners make a box from opposite corners, 3+ make any shape.
3. **Place parking machine** – ghost prop follows the laser: `SCROLL` rotate (`SHIFT` = fine), `Q` 90°, `E` place.
4. **Bays** – ghost car follows the laser (green = OK, red = too close / outside zone): `E` place, `SCROLL`/`Q` rotate, `DEL` remove the aimed bay, `X` undo, `R` fill the row between the last 2 bays, `ENTER` done.
5. **Save lot**.

Bays with a parked car can't be removed or moved, and a lot with parked cars can't be deleted – release or impound those cars first.

`/parkspot` (while `Config.EnableSpotTool = true`) prints your current position as a `vec4` in F8 – handy for the impound coords in `config.lua`.

## Controls & Commands
| Command | Description |
|---|---|
| `E` / `/park` | Park when stopped in a free bay – only works inside a parking lot (a "[E] Park vehicle" hint shows when you drive in) |
| Parking machine (target) | At each lot: shows your cars parked there, pay fees & unlock |
| `/parkspot` | Dev: print current position as a bay `vec4` |
| `/parkadmin` | Admin: parking logistics panel |
| `/parked` | List your parked cars & set waypoint |
| Target a parked car (police job) | **Write parking ticket** (amount + reason) or **Impound vehicle** (reason) |

Standalone police permission: `add_ace group.police rps_parking.police allow`
Admin panel permission: `add_ace group.admin rps_parking.admin allow` (QB `admin`/`god` and ESX `admin`/`superadmin` also work when `Config.Admin.frameworkAdmin = true`)

## Admin panel
- **Dashboard:** revenue (today, 7 days, logged total), occupancy across all lots, parked / impounded counts, outstanding unpaid fees, today's activity.
- **Lots:** each lot shows a fill bar (green / yellow / red), 7-day revenue and stays. Open a lot to see every bay – free, or who is parked, for how long and what they owe.
- **Vehicle page:** owner, location, time parked, amount due, full history, and actions: teleport, force unpark (fees waived), impound with reason, waive fines, delete impound record.
- **Impound lot:** every impounded vehicle with owner, reason and fines.
- **Recent activity:** last 40 log entries, filterable by action.

## Database
| Table | Purpose |
|---|---|
| `advanced_parking` | Parked and impounded vehicles (position, props, lot, bay, fines) |
| `parking_logs` | Every action with who did it, where, and money involved – used for revenue stats |

Logs older than `Config.Logs.retentionDays` are pruned on server start. Revenue = parking fees + fines paid on unpark, plus impound releases.

## Exports (server)
```lua
exports.rps_parking:IsVehicleParked(plate)   -- bool
exports.rps_parking:GetParkedVehicle(plate)  -- { plate, owner, lot, spot, coords, entity } | nil
exports.rps_parking:IsSpotTaken(lotName, spotIndex) -- bool
```
Use `IsVehicleParked` in your garage script to block spawning a car that is already parked (prevents duplicates), and in car-wipe scripts to skip parked cars (or check `Entity(veh).state.parked`).
