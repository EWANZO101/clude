# rps_shops

One resource for all RPS store chains. It replaces these four resources:

| Brand id         | Was                  | Config file                        | NUI theme                        |
|------------------|----------------------|------------------------------------|----------------------------------|
| `supermarket247` | `rps_247Supermarget` | `config/brands/supermarket247.lua` | `web/themes/supermarket247/`     |
| `ltd`            | `rps_LtdGasline`     | `config/brands/ltd.lua`            | `web/themes/ltd/`                |
| `youtool`        | `rps_YouTool`        | `config/brands/youtool.lua`        | `web/themes/youtool/`            |
| `digitalden`     | `rps_DigitalDen`     | `config/brands/digitalden.lua`     | `web/themes/digitalden/`         |

Requires `ox_lib` and `rps_lib` (framework, inventory, target and notifications).

## Install

1. **Remove the four old resource folders** above. `server.cfg` runs `ensure [esx_addons]`, which starts
   every resource in the folder, so leaving them in place spawns duplicate cashiers and blips.
2. Add any missing items from `OX_INVENTORY_ITEMS_EXAMPLE.lua` to `ox_inventory/data/items.lua`.
3. Restart the server (or `ensure rps_shops`).

## Config

- `config/shared.lua`: settings shared by every brand (currency, item images, security, stock, purchase animation).
- `config/brands/<brand>.lua`: everything specific to one chain: UI colours, target, blip, receipt, categories,
  products, locations and texts. Set `enabled = false` at the top to switch off a whole chain.
- A brand can override `Security` and `Stock.RestockMinutes`. Anything left out of a brand's `Locale`
  falls back to `Config.DefaultLocale`.
- Location ids must be unique across all brands (they are, by prefix: `store247_`, `ltd_`, `youtool_`, `digitalden_`).
- `store247_grapeseed` is disabled by default because it sits on the same counter as `ltd_grapeseed`.

## Admin

| Command                  | Ace                                    | Restocks          |
|--------------------------|----------------------------------------|-------------------|
| `/restockshops [brand]`  | `rps_shops.admin`                      | all, or one brand |
| `/restock247`            | `supermarket247.admin` or `rps_shops.admin` | 24/7         |
| `/restockltd`            | `ltdgasoline.admin` or `rps_shops.admin`    | LTD          |
| `/restockyoutool`        | `youtool.admin` or `rps_shops.admin`        | YouTool      |
| `/digitaldenrestock`     | `digitalden.admin` or `rps_shops.admin`     | Digital Den  |

## UI

`web/index.html` is a small loader. It keeps each brand's original UI in its own frame and sends the
NUI messages to the frame of the shop being opened (`theme` in the brand config). To add a new chain, add a
brand config, a folder in `web/themes/`, and its name to `THEMES` in `web/loader.js`.

To preview a theme in a browser, serve the `web` folder and open `index.html?theme=youtool`.
