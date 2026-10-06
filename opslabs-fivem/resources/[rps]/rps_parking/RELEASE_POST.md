# 🅿️ rps_parking – Advanced Persistent Parking

**Real parking lots for your server.** Drive into a marked bay, press **E**, and your car stays exactly where you left it – through relogs, crashes and server restarts – with all its mods, colours, damage and fuel. Come back, pay at the parking machine, and drive away.

No more cars vanishing into a garage menu. Parking lots actually fill up, police can ticket and impound, and staff get a full logistics panel with revenue and history.

> 📺 **Preview:** *[video link]*
> 📥 **Download:** *[link]*
> 📚 **Docs / support:** *[link]*

---

## ✨ Highlights

- 🚗 **Real-world persistent parking** – cars are spawned by the server and stay in the world across restarts
- 🧾 **Parking machine at every lot** – target it to see *your* cars parked there, pay and unlock
- 🎯 **Red arrow** above your car after unlocking, so you find it straight away
- 🛠️ **In-game lot editor** – draw zones with a laser, place bays with a ghost car. No coordinates, no config editing
- 👮 **Police tools** – target any parked car to write a parking ticket or impound it
- 📊 **Admin logistics panel** – revenue, occupancy, outstanding fees, plate history, impound management
- 🔌 **Multi-framework** – ESX, QBCore, QBox and standalone through `rps_lib`

---

## 🚗 Parking

- Park only in **marked bays** inside a parking lot – one car per bay
- **Green / red bay markers** while driving near a lot show free and taken bays at a glance
- A **"[E] Park vehicle"** hint appears when you drive into a lot – the key does nothing outside a lot, so it never gets in the way
- Cars are **snapped straight** into the bay (forward *or* reverse parking)
- Parked cars are **locked and frozen** – no pushing, towing or stealing
- Saves **all vehicle properties**: mods, colours, extras, damage, fuel
- **Auto-respawn watchdog** – if a parked car gets deleted (car-wipe, crash, another script), it's put back in its bay
- **Ownership check** against your framework's vehicle table (can be turned off)
- **Per-player limit** on parked cars and **anti-duplication** checks
- Optional floating **"PARKED | PLATE"** text over parked cars
- `/parked` – list all your parked cars with the amount due and **set a waypoint** to any of them

## 🧾 Parking machine & fees

- A **parking machine prop** at every lot – interact with your target script (ox_target / qb-target / tgiann-target), or `[E]` if you don't use one
- Shows only **your cars at that lot**: model, plate, bay number, time parked and total due (incl. fines)
- **Paid lots** with a price per hour and a **max fee cap**, or **free lots**
- Pays from **bank first, then cash**
- After paying, the car unlocks, you get your **keys** (qb-vehiclekeys, wasabi_carlock or your own hook) and a **red arrow** marks the car until you get in

## 👮 Police

- Players with a police job (configurable, e.g. `police`, `sheriff`) get **target options on every parked car**:
  - **Write parking ticket** – amount + reason, added to what the owner pays at the machine
  - **Impound vehicle** – reason + progress bar, car goes to the impound lot
- The owner gets a **notification** when their car is ticketed or impounded
- The server checks the job, the amount and the distance on every action
- Standalone servers can use an ACE permission instead of a job

## 🚓 Impound

- Impound lot with a **release fee** (+ any unpaid parking fees and fines)
- Walk up to the impound point and pick your car from a menu
- **Abandoned cars are auto-impounded** after a configurable number of days

## 🛠️ In-game lot editor (admins)

Build parking lots **in-game** – no copying coordinates into a config.

- **Draw the zone with a laser** – click 2 corners for a box, or 3+ for any shape. The zone shows as see-through walls
- **Place the parking machine** as a ghost prop – rotate with the scroll wheel, click to place
- **Place bays with a ghost car** – green when the spot is OK, red when it's too close to another bay or outside the zone
  - Rotate with scroll (hold Shift for fine steps), `Q` for 90°
  - Aim at a bay and press `DEL` to remove it, `X` to undo
  - **Fill a whole row**: place the first and last bay, press `R`, enter how many bays – done
- Set the name, price per hour, max fee and map blip
- **Changes go live for everyone instantly** – blips, machines, target zones and bay markers update without a restart
- **Safe editing** – parked cars keep their bay, a bay with a car in it can't be removed, and a lot with parked cars can't be deleted
- All lots are stored in the database (`ParkingLots` table)

## 📊 Admin logistics panel – `/parkadmin`

- **Dashboard** – revenue today / last 7 days / total, occupancy across all lots, parked and impounded counts, outstanding unpaid fees, today's activity
- **Lots** – fill bar per lot (green / yellow / red), 7-day revenue and number of stays. Open a lot to see **every bay**: free, or who's parked, for how long and what they owe
- **Plate search** – owner, location, time parked, amount due and **full history**
- **Staff actions** – teleport to the car, force unpark (fees waived), impound with reason, waive fines, delete impound record
- **Impound list** – every impounded car with owner, reason and fines
- **Recent activity** – last 40 log entries, filterable by action

## 📜 Logs

- Every park, unpark, ticket, impound, release, auto-impound and staff action is **logged to the database** – who did it, where, and how much money was involved
- Optional **Discord webhook** with per-action toggles
- Automatic clean-up of old logs (configurable retention)

---

## 🔌 Compatibility

| | Supported |
|---|---|
| **Frameworks** | ESX, QBCore, QBox, Standalone (auto-detected by `rps_lib`) |
| **Target** | ox_target, qb-target, tgiann-target (or `[E]` prompt at the machine without one) |
| **Notifications** | ox_lib, codem, framework default (via `rps_lib`) |
| **Vehicle keys** | qb-vehiclekeys, wasabi_carlock – or add your own in `Config.GiveKeys` |

## 📦 Requirements

- OneSync
- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)
- `rps_lib`

## ⚙️ Installation

1. Put `rps_parking` in your resources folder
2. Add to `server.cfg` after ox_lib, oxmysql, your framework and rps_lib:
   ```
   ensure rps_lib
   ensure rps_parking
   ```
3. Start the server – the database tables are created automatically, with two example lots
4. Give your admins access: `add_ace group.admin rps_parking.admin allow`
5. Open `/parkadmin` → **Lot editor** and build your lots

## 🎮 Commands & controls

| | |
|---|---|
| `E` / `/park` | Park in a free bay (inside a parking lot) |
| Parking machine (target) | Your cars at this lot – pay & unlock |
| `/parked` | Your parked cars + waypoints |
| Target a parked car (police) | Write parking ticket / Impound vehicle |
| `/parkadmin` | Admin panel + lot editor |
| `/parkspot` | Dev tool – prints your position as a `vec4` |

## 🧩 Exports (server)

```lua
exports.rps_parking:IsVehicleParked(plate)          -- true / false
exports.rps_parking:GetParkedVehicle(plate)         -- { plate, owner, lot, spot, coords, entity } or nil
exports.rps_parking:IsSpotTaken(lotName, spotIndex) -- true / false
```

Use `IsVehicleParked` in your garage script to stop a parked car being spawned twice, and in car-wipe scripts to skip parked cars (or check `Entity(vehicle).state.parked`).

## 🔧 Config highlights

- Park key, park time, max parked cars per player, ownership check on/off
- Bay size tolerance, max parking angle, snap to bay, marker colours and distance
- Parking machine model, label, icon and interaction distance
- Police jobs and max ticket amount
- Impound fee and location, days before abandoned cars are impounded
- Respawn interval for deleted parked cars
- Admin permission, framework admin groups, ghost car model for the editor
- Log retention, Discord webhook and which actions it sends

---

**Version:** 1.0.3
*Feedback and bug reports welcome – [support link]*
