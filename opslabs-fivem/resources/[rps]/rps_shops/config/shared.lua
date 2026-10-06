Config = {}

Config.Debug = false

-- Framework (ESX / QBCore / QBox / standalone), inventory and notifications come from rps_lib.
-- To force a framework: setr rps_lib:forceFramework "esx" (or set it in rps_lib's config.lua)

-- ============================================
--  Global settings (shared by every store brand)
--  A brand can override Security / Stock.RestockMinutes in its own config file.
-- ============================================

-- Currency used by the shops.
--
-- Type:
--   'item'    = cash is an inventory item (ox_inventory: 'money')
--   'account' = cash is a framework account (QBCore / QBox: 'cash', or 'bank')
Config.Currency = {
    Type = 'item',
    Item = 'money',
    Account = 'cash',
    Label = 'Cash',
    Symbol = '$'
}

-- Item image path per inventory (picked from the inventory rps_lib detects).
-- %s is replaced with the item name. Products with their own "image" skip this.
Config.ItemImages = {
    ox_inventory = 'nui://ox_inventory/web/images/%s.png',
    ['tgiann-inventory'] = 'nui://inventory_images/images/%s.webp',
    ['qb-inventory'] = 'nui://qb-inventory/html/images/%s.png',
    ['ps-inventory'] = 'nui://ps-inventory/html/images/%s.png',
    ['lj-inventory'] = 'nui://lj-inventory/html/images/%s.png',
    default = 'nui://ox_inventory/web/images/%s.png'
}

Config.TargetDistance = 2.5

Config.Security = {
    MaxServerDistance = 5.0,
    MaxDifferentItemsPerPurchase = 15,
    MaxTotalUnitsPerPurchase = 50
}

Config.PurchaseAnimation = {
    Enabled = true,
    Dict = 'mp_common',
    Clip = 'givetake1_a',
    Duration = 1200
}

Config.Stock = {
    Enabled = true,

    -- Restock automatically while the resource is running.
    AutoRestock = true,
    RestockMinutes = 30,

    -- 0.25 means restore 25% of the product's maximum stock each cycle.
    RestockPercent = 0.25
}

-- Restocks every brand at once. Each brand also has its own command (see its config file).
Config.Admin = {
    RestockCommand = 'restockshops',
    AcePermission = 'rps_shops.admin'
}

-- Fallback texts for any key a brand's Locale leaves out.
Config.DefaultLocale = {
    ShopTitle = 'Shop',
    Target = 'Shop',

    TooFar = 'You are too far away from the counter.',
    InvalidShop = 'This shop is closed right now.',
    InvalidCart = 'Your basket contains invalid items.',
    NoMoney = 'You do not have enough %s.',
    InventoryFull = 'You cannot carry everything in your basket.',
    OutOfStock = '%s is out of stock.',
    PurchaseComplete = 'Purchase complete: %s%s.',
    PurchaseFailed = 'The transaction could not be completed.',
    Restocked = 'Stock has been restocked.',
    ReceiptLabel = 'Receipt'
}

-- ============================================
--  Brands
--  Every file in config/brands/ adds one entry: Config.Brands.<id> = { ... }
--  Set enabled = false in a brand file to turn that whole store chain off.
-- ============================================
Config.Brands = {}

-- Helper to keep location lists short. Every location of a brand uses the same
-- ped / blip settings, only the label and the cashier position change.
--   x, y, z, h = cashier ped position + heading (also used for distance checks)
--
-- defaults:  { pedModel, scenario, blipLabel }
-- overrides: any shop field, e.g. { priceMultiplier = 1.10 } or { enabled = false }
function Config.Location(defaults, label, x, y, z, h, overrides)
    local shop = {
        enabled = true,
        label = label,
        priceMultiplier = 1.0,
        coords = vec3(x, y, z),

        productIds = false,
        categoryIds = false,

        ped = {
            enabled = true,
            model = defaults.pedModel,
            coords = vec4(x, y, z, h),
            scenario = defaults.scenario
        },

        zone = {
            enabled = false,
            coords = vec3(x, y, z),
            size = vec3(1.8, 1.8, 2.2),
            rotation = h
        },

        blip = {
            enabled = true,
            label = defaults.blipLabel or label
        }
    }

    if overrides then
        for k, v in pairs(overrides) do
            shop[k] = v
        end
    end

    return shop
end
