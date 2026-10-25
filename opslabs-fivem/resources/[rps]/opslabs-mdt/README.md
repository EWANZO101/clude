# opslabs-mdt

A portable in-car MDT: an `opslabs_laptop` item any officer can install in any vehicle's front, use from the
seat or standing next to it, and take back out again. It isn't its own CAD — it's a client for the SnailyCAD
instance already running on this server. Each officer links their own personal CAD **User API Token** once;
every search, BOLO, citation and warrant they make goes through the real CAD, attributed to them, under their
own CAD permissions.

## Install

1. `ensure opslabs-mdt` after `rps_lib`, `oxmysql`, `ox_lib` and `opslabs-license`.
2. Add the item to `ox_inventory`'s `data/items.lua`:
   ```lua
   ['mdt_laptop'] = {
       label = 'MDT Laptop', weight = 3500, stack = false, close = true,
       client = { image = 'opslabs_laptop.png' },   -- reuse the field-engineer laptop's icon, or make your own
   },
   ```
3. Give it to officers however you hand out other duty gear (a locker, a shop, an admin command).
4. SnailyCAD needs to already be reachable the way `snailycad-framework` / `snailycad-radio` already use it
   (`snailycad_framework_api_url` / `snailycad_radio_api_url` in server.cfg) — nothing new to configure there.

## Using it

- **Install:** use the MDT Laptop item near the front of any vehicle. It mounts on the dash (best-effort
  generic position — see *Mount positions* below) and the item is consumed from your inventory.
- **Remove:** stand by the vehicle and run `/mdtremove` (rebindable, "Remove the MDT laptop from the nearest
  vehicle"). You get the item back.
- **Open it:** get close to an installed laptop (in the car or standing by the door) and press **E**.
- **First time:** paste your SnailyCAD **User API Token** (CAD → Account Settings → API Tokens). That's the
  only setup each officer does — it's remembered after that. `Unlink` in the top bar forgets it.
- Being "on duty" is whatever the CAD itself says (an active officer unit) — set that the same way you always
  do (the game's own duty toggle, already synced by `snailycad-framework`). The MDT doesn't gate on the game's
  duty flag at all, only on the job check below and the CAD's own permission checks per action.

## Who can use one

`config.lua`'s `Config.Access` — same shape as opslabs-bodycam's bridge: `Mode = 'job' | 'item' | 'job_and_item'
| 'job_or_item' | 'ace' | 'everyone'`, `Config.Access.Jobs = { police = 0 }` by default (job name → minimum
grade), plus an always-allowed ACE (`opslabs.mdt`).

## Mount positions

`Config.DefaultMount` is one generic centre-console-ish offset that won't look right in every car (there's no
dashboard bone shared across all vehicle models). Add a per-model entry to `Config.Mounts` to fix a specific
car properly:
```lua
Config.Mounts.police3 = { x = 0.05, y = 0.25, z = 0.68, rx = -5.0, ry = 0.0, rz = 90.0 }
```
There's no in-game calibration tool for this yet (unlike some other MDT scripts) — eyeball it with
`/mdtremove` + reinstall between tries, or extend `client/main.lua` with one later.

## What's built (full suite)

- Query person (name search, licences, DOB, WANTED flag, records)
- Query plate (owner, stolen/BOLO flags, registration/insurance status)
- Query weapon (serial number)
- BOLOs: view active, post a new one (person / vehicle / other)
- Write citation: ticket, written warning or arrest report, multiple violations, posted to the CAD
- Warrants: view active, issue one, serve one
- Incident report: description, postal, firearms/injuries/arrests flags
- Active units board, active 911 calls board

The CAD's own permission system is the real gate on all of this — an officer's token can only do what that CAD
account is actually allowed to do (e.g. `ManageBolos`, `ManageWarrants`). An action the CAD refuses comes back
as a plain error on the MDT screen, not a crash.

## Notes / known gaps

- Citizen/vehicle/weapon/BOLO/unit/call response shapes are rendered defensively (common field names, safe
  fallbacks) rather than against a hand-verified exact schema for every screen — the create/write endpoints
  (citation, warrant, BOLO, incident) ARE verified against this CAD's own Zod validation schemas, so those are
  solid; a read screen showing a blank field just means that field's real name differs from the guess, not a
  broken request.
- Penal codes for the citation form (`Cad.Global`, the same server-wide token `snailycad-framework` already
  uses) need **Admin Values** read access on that token the way `snailycad-framework` already requires.
- Untested in-game (built and reviewed, not yet run on the live server) — the usual first-boot checklist: table
  creation on start (`opslabs_mdt_installs`, `opslabs_mdt_officers`), the item entry above, one real officer
  link + one real search before trusting it on duty.
