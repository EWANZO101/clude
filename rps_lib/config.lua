--[[
    config.lua
    Central configuration for the lib resource. Edit these values directly —
    no convars required, no fxmanifest changes needed.
]]

Config = {}

--- Which framework module to use.
---   'auto'       - auto-detect ESX / QBCore / QBox / standalone at startup (recommended)
---   'esx'        - force framework/esx
---   'qb'         - force framework/qb (QBCore)
---   'qbox'       - force framework/qbox
---   'standalone' - force framework/standalone (no framework)
Config.Framework = 'auto'

--- Which garage integration to use.
---   'auto'        - pick automatically based on the detected framework (recommended)
---   'qb-garage'   - force integrations/garages/qb-garage (player_vehicles table)
---   'qbox-garage' - force integrations/garages/qbox-garage (qbx_vehicles/qbx_garages exports)
---   'esx-garage'  - force integrations/garages/esx-garage (owned_vehicles table)
---   'none'        - no garage integration
Config.Garage = 'auto'

--- Which progress bar integration to use.
---   'auto'   - auto-detect ox_lib, else none (recommended)
---   'ox_lib' - force integrations/progressbar/ox_lib (requires ox_lib)
---   'none'   - no progress bar; calls resolve instantly with no UI
Config.ProgressBar = 'auto'

--- Which ambulance/EMS job integration to use.
---   'auto'             - pick automatically based on the detected framework (recommended)
---   'esx_ambulancejob' - force integrations/ambulancejob/esx_ambulancejob
---   'qb-ambulancejob'  - force integrations/ambulancejob/qb-ambulancejob
---   'qbx_ambulancejob' - force integrations/ambulancejob/qbx_ambulancejob
---   'none'             - no ambulance job integration
Config.Ambulance = 'auto'

--- Which rich-notification integration to use (separate from the plain,
--- always-available Notify/Notify(source, ...)).
---   'auto'   - auto-detect codem-supreme-notification, then ox_lib, else none (recommended)
---   'ox_lib' - force integrations/notifications/ox_lib (requires ox_lib)
---   'codem'  - force integrations/notifications/codem (requires codem-supreme-notification)
---   'none'   - falls back to the plain framework Notify
Config.Notifications = 'auto'

--- Which inventory integration to use.
---   'auto'             - auto-detect ox_inventory, tgiann-inventory, qb-inventory, ps-inventory, lj-inventory, else none (recommended)
---   'ox_inventory'     - force integrations/inventory/ox_inventory
---   'tgiann-inventory' - force integrations/inventory/tgiann-inventory
---   'qb-inventory'     - force integrations/inventory/qb-inventory
---   'ps-inventory'     - force integrations/inventory/ps-inventory (Project Sloth)
---   'lj-inventory'     - force integrations/inventory/lj-inventory
---   'none'             - no inventory integration
Config.Inventory = 'auto'

--- Which targeting ("third-eye") integration to use. Client-only.
---   'auto'           - auto-detect ox_target, then tgiann-target, then qb-target, else none (recommended)
---   'ox_target'      - force integrations/target/ox_target
---   'tgiann-target'  - force integrations/target/tgiann-target
---   'qb-target'      - force integrations/target/qb-target
---   'none'           - no targeting integration
Config.Target = 'auto'

--- Which phone integration to use.
---   'auto'     - auto-detect lb-phone, then qb-phone, else none (recommended)
---   'lb_phone' - force integrations/phone/lb_phone
---   'qb_phone' - force integrations/phone/qb_phone
---   'none'     - no phone integration
Config.Phone = 'auto'

--- Which bank integration to use.
---   'auto'             - auto-detect qb-banking, then Renewed-Banking, else qbox
---                        (if that's the detected framework), else none (recommended)
---   'qb-banking'       - force integrations/bank/qb-banking (named personal/job/gang accounts)
---   'renewed-banking'  - force integrations/bank/renewed-banking (named personal/job/custom accounts)
---   'qbox'             - force integrations/bank/qbox (qbx_core's own 'bank' money type — per-player only)
---   'none'             - no bank integration
Config.Bank = 'auto'

--- Print debug info to console (detected framework, missing callbacks, etc.)
Config.Debug = true
