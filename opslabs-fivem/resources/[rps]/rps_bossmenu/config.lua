-- ============================================
--  Framework & Core Settings
-- ============================================
-- This resource is built entirely on rps_lib (exports.rps_lib:...) for every
-- framework/inventory/target/job operation — there is no per-framework or
-- per-inventory config here anymore. Requires the standalone rps_lib
-- resource started before this one (see fxmanifest.lua's dependency and
-- your server.cfg order). rps_lib has its own config.lua controlling which
-- framework/inventory/target it auto-detects or is forced to.
Config = {}

Config.InventoryImagePath = 'rps_bossmenu/ui/dist/images'
                               -- Path used to display item images in the UI —
                               -- set this to match whatever inventory rps_lib
                               -- is actually bridging to (rps_lib abstracts
                               -- function calls, not UI asset paths):
                               -- 'qb-inventory/html/images'   (qb-inventory)
                               -- 'qs-inventory/html/img'      (qs-inventory)
                               -- 'ox_inventory/web/images'    (ox_inventory)
                               -- 'rps_bossmenu/ui/dist/images' (bundled fallback)

-- ============================================
--  Debug & World
-- ============================================
Config.Debug = false           -- reserved for future debug logging in this resource
                               -- (target zone debug outlines are controlled by rps_lib's own config now)

Config.InteractionDistance = 5.0  -- Radius in metres for nearby player detection

-- ============================================
--  Commands
-- ============================================
Config.Commands = {
    AdminMenu = 'bossadmin',   -- Command to open the admin panel
    Billing = 'bill'           -- Command to open the billing tablet (ignored if TabletItem is set)
}

Config.TabletItem = 'bill_tablet'   -- false    = use the /bill command
                               -- 'tablet' = require the player to use an in-game item
                               -- (make sure this item name is registered in your framework's/inventory's item list)

Config.AdminAce = 'rps_bossmenu.admin'  -- ACE permission node that also grants /bossadmin access,
                                        -- on top of the framework's own admin/god ranks (via rps_lib).
                                        -- Set to false to disable the ACE check entirely.
                                        -- Grant it in server.cfg, e.g.:
                                        --   add_ace group.admin rps_bossmenu.admin allow
                                        -- (swap group.admin for whatever group/identifier should have access)

-- ============================================
--  Economy
-- ============================================
Config.Commission = 10         -- % of each paid invoice sent back to the invoice sender as commission (0 to disable)

-- ============================================
--  Limits
-- ============================================
Config.MaxWage = 10000000            -- Maximum wage that can be set for an employee
Config.MaxDeposit = 10000000       -- Maximum deposit per transaction
Config.MaxWithdraw = 10000000      -- Maximum withdrawal per transaction
Config.MaxInvoice = 1000000        -- Maximum invoice amount
Config.MaxOrderTotal = 5000000     -- Maximum Jungle order total

Config.AllowedExportResources = {}  -- Whitelist of resource names allowed to call PlaceJungleOrder
                                    -- Leave empty {} to allow any resource
                                    -- this is an added layer of security if you're sceptical of my security measures :(
                                    -- Example: {'my_shop_resource', 'jungle_web'}
