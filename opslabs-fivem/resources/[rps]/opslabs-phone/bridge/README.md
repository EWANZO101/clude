# OPS Phone framework bridge

OPS Phone finds the framework and inventory your server runs by itself. Nothing in the phone's apps knows which
framework it is on: they call `FW.*` (server) and `FW.On…` (client), and the adapters in this folder translate.

## What it detects

| Framework | `Config.Framework` | Resource | Status |
|---|---|---|---|
| Qbox | `qbx` | `qbx_core` | experimental |
| QBCore | `qb` | `qb-core` | experimental |
| ESX Legacy (1.9+) | `esx` | `es_extended` | **verified** |
| ox_core | `ox` | `ox_core` | experimental |
| ND Core (v2) | `nd` | `ND_Core` | experimental |
| vRP | `vrp` | `vrp` | experimental |
| none | `standalone` | — | **verified** |
| your own | its name | — | custom |

**Verified** means it was tested on a live server. **Experimental** means the adapter passes its automated tests,
which run against fakes built from that framework's source, but nobody has run it on a live server of that
framework yet. Once a server owner confirms it works, it can be marked verified. The console shows the status at
start-up.

Detection order: your own adapters → Qbox → QBCore → ESX → ox_core → ND → vRP → standalone. Qbox is checked before
QBCore because Qbox also answers to `qb-core`.

Inventories (`Config.Inventory`): `ox_inventory`, `qs-inventory`, `codem-inventory`, `tgiann-inventory`,
`ps-inventory`, `lj-inventory`, `qb-inventory`. If none of these is running, the framework's own inventory is used
(`framework`). If there's no inventory at all (`none`), `Config.RequireItem` is ignored and everyone can open the
phone.

## Start-up

The server console shows what was picked and how:

```
[opslabs-phone] Framework: ESX Legacy 1.15.2 (detected) · verified
[opslabs-phone] Inventory: ox_inventory (detected)
```

- **Detected:** found automatically.
- **Config / convar:** forced by you.
- **Fallback:** nothing was found, so the phone runs standalone.

If a framework is found but fails its check (for example a missing export), the console says why and the phone
runs **standalone**, so it keeps working. A framework the phone recognises but doesn't support (VORP, RSG, …) is
named in a warning.

`opsphone_bridge` in the server console (or for admins in game) prints the current choice again.

## Choosing manually

`config.lua`:

```lua
Config.Framework = 'auto'   -- or 'qbx', 'qb', 'esx', 'ox', 'nd', 'vrp', 'standalone', 'myframework'
Config.Inventory = 'auto'   -- or 'ox_inventory', …, 'framework', 'none'
```

…or a convar in `server.cfg`. A convar takes priority over `config.lua`, so no file has to be edited:

```
setr opslabs_phone:framework "qbx"
setr opslabs_phone:inventory "ox_inventory"
```

## Admins

On every framework, a player with the `opslabs.admin` ACE is an OPS Phone admin:

```
add_ace group.admin opslabs.admin allow
```

The framework's own admins count too: ESX `admin`/`superadmin`, QBCore/Qbox `admin`/`god` permissions, ox_core
`admin` group, ND `admin` group, vRP `admin` permission.

## Writing your own adapter

You never edit the phone's files. Pick one of these:

1. **A file in `bridge/custom/server/` (and `bridge/custom/client/`).** Every `.lua` file there is loaded
   automatically. Copy `example.lua`, set `ENABLED = true` and fill it in.
2. **From your own resource**, with an export:

   ```lua
   exports['opslabs-phone']:RegisterFrameworkAdapter('mycity', {
       detect = function() return true end,
       GetPlayer = function(src) ... end,
       ...
   })
   ```

   Also set `Config.Framework = 'mycity'` (or the convar), so the phone waits for your resource to register it.
   Client adapters still go in `bridge/custom/client/`.

A custom adapter whose `detect()` returns true wins over the built-in ones. Registering the name of a built-in
adapter (`'esx'`, …) replaces that adapter.

### Server adapter reference

Every function is called with plain arguments (`A.GetPlayer(src)`, not `A:GetPlayer`). Only `detect` and
`GetPlayer` are required. Errors are caught, reported once in the console, and the phone carries on with a safe
default.

| Function | Returns | Used for |
|---|---|---|
| `detect()` | `true` when this framework runs | detection |
| `init()` | `true`, or `false, 'reason'` | the start-up check (on failure: standalone) |
| `GetPlayer(src)` | `{ identifier, name?, firstname?, lastname?, job? = { name, label, grade = { level, name } } }` | everything. `identifier` must be stable per **character**, because it keys the phone number |
| `GetSource(identifier)` | server id or nil | faster lookups (otherwise every player is scanned) |
| `IsAdmin(src, groups)` | boolean | Developer app, license key, OPS Hub. `groups` lists extra group names a caller accepts |
| `GetMoney(src, account)` | number | Wallet. `account` is `'bank'` or `'cash'` |
| `AddMoney(src, amount, account, reason)` | `true` | transfers, refunds |
| `RemoveMoney(src, amount, account, reason)` | `true` only if taken | payments. Must refuse an overdraft |
| `GetOfflineMoney(identifier, account)` | number, or nil if unknown | transfers to offline players, carrier billing |
| `AddOfflineMoney` / `RemoveOfflineMoney(identifier, amount, account)` | `true` | same. Without these, offline transfers are refused |
| `AddSocietyMoney` / `RemoveSocietyMoney(society, amount)` | `true` | job / business accounts |
| `ItemCount(src, item)`, `AddItem(src, item, count, metadata)`, `RemoveItem(src, item, count)` | number / `true` | only if the framework owns items (`Config.Inventory = 'framework'`) |
| `UsableItem(item, handler)` | `true` | the phone's items (power bank, buds, SafeMag). Call `handler(src)` when used |
| `Notify(src, message, kind)` | `true` | otherwise ox_lib's notify is used |
| `GetBills(identifier)` | `{ { id, label, amount, target } }` | Wallet bills |
| `TakeBill(identifier, id)` | the bill, removed so it can't be paid twice, or nil | paying a bill |
| `RestoreBill(bill)` | — | the payment failed: put it back |
| `SettleBill(bill)` | — | pay the bill's money to whoever sent it |
| `GetVehicles(identifier)` | `{ { plate, model, name, stored, parking, pound, fuel, engine, body, mileage } }` | Garage app |
| `BackfillNames()` | rows updated | once at start: names of phone owners who haven't logged in since |
| `events.loaded` / `events.unloaded` | `{ ['event:name'] = function(...) return src end }` | character load / logout (character switch) |

Fields: `label` (console name), `resource` (detection waits while it is starting), `status` (leave it out for
custom adapters).

### Client adapter reference

```lua
Bridge.RegisterFramework('mycity', {
    events = {
        loaded = { ['mycity:client:loaded'] = true },          -- or function(...) return false to ignore one
        unloaded = { ['mycity:client:unloaded'] = true },
        inventory = { ['mycity:client:items'] = function(item) return item end },   -- framework inventory only
    },
})
```

The client uses whatever the server picked (it's shared through `GlobalState['opslabs-phone:bridge']`), so the
client adapter must have the same name as the server one.

Inventory adapters work the same way (`Bridge.RegisterInventory`): server `detect`, `ItemCount`, `AddItem`,
`RemoveItem`, optional `UsableItem`. Client `events.inventory`, or `watchInventory(changed)`, which calls
`changed(item)` itself. `localEvents = { ['event'] = true }` marks client-side events (not network events).

## Tests

```
lua5.4 bridge/tests/run.lua
```

This runs every adapter against a fake of its framework, built from that framework's source (`bridge/tests/fakes.lua`):
detection, the start-up checks, fallbacks, players, money, admins, events, items, bills and the garage. Add a test
when you add an adapter. Nothing in `bridge/tests/` is loaded by the server.
