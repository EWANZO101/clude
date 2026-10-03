-- ============================================
--  Digital Den  (was rps_DigitalDen)
-- ============================================
local location = {
    pedModel = 'a_m_y_business_01',
    scenario = 'WORLD_HUMAN_STAND_MOBILE',
    blipLabel = 'Digital Den'
}

Config.Brands.digitalden = {
    enabled = true,

    -- NUI theme folder: web/themes/<theme>
    theme = 'digitalden',

    UI = {
        Accent = '#653196',
        StoreTagline = 'TRAPS ELECTRONICS',
        FooterText = 'DIGITAL DEN • AUTHORIZED ELECTRONICS RETAILER',
        ShowItemImages = true
    },

    Target = {
        Icon = 'fa-solid fa-microchip',
        Label = 'Browse Digital Den'
    },

    -- Overrides Config.Security for this brand only.
    Security = {
        MaxDifferentItemsPerPurchase = 12,
        MaxTotalUnitsPerPurchase = 25
    },

    Stock = {
        RestockMinutes = 30
    },

    Receipt = {
        Enabled = true,
        Item = 'digitalden_receipt'
    },

    Blip = {
        Enabled = true,
        Sprite = 521,
        Colour = 27,
        Scale = 0.75,
        ShortRange = true
    },

    Admin = {
        RestockCommand = 'digitaldenrestock',
        AcePermission = 'digitalden.admin'
    },

    -- Category order is controlled by this table.
    Categories = {
        { id = 'phones',      label = 'Phones',      icon = 'mobile-screen-button' },
        { id = 'computing',   label = 'Computing',   icon = 'laptop' },
        { id = 'audio',       label = 'Audio',       icon = 'headphones' },
        { id = 'comms',       label = 'Comms',       icon = 'walkie-talkie' },
        { id = 'accessories', label = 'Accessories', icon = 'plug' }
    },

    -- Product IDs are internal to this brand.
    -- "item" must match an item name in your inventory.
    --
    -- stock:      number = finite server-side stock, false = unlimited
    -- salePrice:  nil/false = normal price, number = discounted price displayed and charged
    -- image:      nil = automatic (Config.ItemImages), string = custom NUI image URL/path
    Products = {
        phone = {
            enabled = true,
            item = 'phone',
            label = 'Smart Phone',
            description = 'Watch something on it god knows?',
            category = 'phones',
            price = 500,
            salePrice = false,
            stock = 5,
            maxPerPurchase = 1
        },
    },

    -- Each location can use a cashier ped, a target box zone, or both.
    -- Location IDs must be unique across ALL brands.
    --
    -- priceMultiplier:          1.0 = normal, 0.9 = 10% cheaper, 1.2 = 20% more expensive
    -- productIds / categoryIds: false = everything, or a table to limit what that store sells
    Locations = {
        -- Example Digital Den MLO area. Change these to match your MLO/store.
        digitalden_main = Config.Location(location, 'Digital Den', -509.4184, 278.8416, 83.3171, 162.6652, {
            zone = {
                enabled = false,
                coords = vec3(-509.4184, 278.8416, 83.3171),
                size = vec3(1.8, 1.8, 2.2),
                rotation = 0.0
            }
        })

        -- Example second store:
        -- digitalden_vinewood = Config.Location(location, 'Digital Den - Vinewood', 0.0, 0.0, 0.0, 0.0, {
        --     priceMultiplier = 1.05,
        --     productIds = { 'phone' }
        -- })
    },

    Locale = {
        ShopTitle = 'Digital Den',
        Target = 'Browse Digital Den',

        TooFar = 'You are too far away from the shop.',
        InvalidShop = 'That Digital Den location is unavailable.',
        InvalidCart = 'Your basket contains invalid items.',
        NoMoney = 'You do not have enough %s.',
        InventoryFull = 'You cannot carry everything in your basket.',
        OutOfStock = '%s does not have enough stock.',
        PurchaseComplete = 'Purchase complete: %s%s.',
        PurchaseFailed = 'The transaction could not be completed.',
        Restocked = 'Digital Den stock has been restocked.',
        ReceiptLabel = 'Digital Den Receipt'
    }
}
