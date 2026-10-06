-- ============================================
--  24/7 Supermarket  (was rps_247Supermarget)
-- ============================================
local location = {
    pedModel = 'mp_m_shopkeep_01',
    scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
    blipLabel = '24/7 Supermarket'
}

Config.Brands.supermarket247 = {
    enabled = true,

    -- NUI theme folder: web/themes/<theme>
    theme = 'supermarket247',

    UI = {
        Accent = '#19a055',          -- 24/7 green
        AccentAlt = '#ff7a00',       -- 24/7 orange
        StoreTagline = 'ALWAYS OPEN • LOS SANTOS & BLAINE COUNTY',
        FooterText = '24/7 SUPERMARKET • OPEN ALL DAY, EVERY DAY',
        ShowItemImages = true
    },

    Target = {
        Icon = 'fa-solid fa-basket-shopping',
        Label = 'Shop at 24/7'
    },

    Stock = {
        RestockMinutes = 20
    },

    Receipt = {
        Enabled = true,
        Item = 'supermarket_receipt'
    },

    Blip = {
        Enabled = true,
        Sprite = 52,   -- shopping basket
        Colour = 2,    -- green
        Scale = 0.7,
        ShortRange = true
    },

    Admin = {
        RestockCommand = 'restock247',
        AcePermission = 'supermarket247.admin'
    },

    -- Category order is controlled by this table.
    -- icon = Font Awesome icon name (without "fa-"), emoji = fallback when an item image is missing.
    Categories = {
        { id = 'drinks',     label = 'Drinks',      icon = 'bottle-water',   emoji = '🥤' },
        { id = 'snacks',     label = 'Snacks',      icon = 'cookie-bite',    emoji = '🍫' },
        { id = 'food',       label = 'Food',        icon = 'burger',         emoji = '🍔' },
        { id = 'alcohol',    label = 'Liquor',      icon = 'wine-bottle',    emoji = '🍺' },
        { id = 'essentials', label = 'Essentials',  icon = 'kit-medical',    emoji = '🩹' },
        { id = 'misc',       label = 'Misc',        icon = 'fire',           emoji = '🔥' }
    },

    -- Product IDs are internal to this brand.
    -- "item" must match an item name in your inventory (see OX_INVENTORY_ITEMS_EXAMPLE.lua).
    --
    -- stock:      number = finite server-side stock, false = unlimited
    -- salePrice:  nil/false = normal price, number = discounted price displayed and charged
    -- image:      nil = automatic (Config.ItemImages), string = custom NUI image URL/path
    Products = {
        -- Drinks
        water = {
            enabled = true, item = 'water', label = 'Water',
            description = 'Bottled Blaine County spring water. Probably.',
            category = 'drinks', price = 5, salePrice = false, stock = 60, maxPerPurchase = 10
        },
        sprunk = {
            enabled = true, item = 'sprunk', label = 'Sprunk',
            description = 'The essence of life. Lime-green and fizzy.',
            category = 'drinks', price = 8, salePrice = false, stock = 50, maxPerPurchase = 10
        },
        ecola = {
            enabled = true, item = 'ecola', label = 'eCola',
            description = 'Deliciously infectious. Now with 20% more sugar.',
            category = 'drinks', price = 8, salePrice = 6, stock = 50, maxPerPurchase = 10
        },
        coffee = {
            enabled = true, item = 'coffee', label = 'Coffee',
            description = 'Hot, black and slightly burnt. Just how cops like it.',
            category = 'drinks', price = 10, salePrice = false, stock = 30, maxPerPurchase = 5
        },

        -- Snacks
        chips = {
            enabled = true, item = 'chips', label = 'Phat Chips',
            description = 'Extra salty crisps for extra lazy afternoons.',
            category = 'snacks', price = 6, salePrice = false, stock = 40, maxPerPurchase = 10
        },
        egochaser = {
            enabled = true, item = 'egochaser', label = 'EgoChaser Bar',
            description = 'The energy bar for people who think they matter.',
            category = 'snacks', price = 7, salePrice = false, stock = 40, maxPerPurchase = 10
        },
        meteorite = {
            enabled = true, item = 'meteorite', label = 'Meteorite Bar',
            description = 'Out of this world chocolate and caramel.',
            category = 'snacks', price = 7, salePrice = 5, stock = 40, maxPerPurchase = 10
        },
        donut = {
            enabled = true, item = 'donut', label = 'Donut',
            description = 'Glazed, sprinkled and gone in three bites.',
            category = 'snacks', price = 5, salePrice = false, stock = 30, maxPerPurchase = 10
        },

        -- Food
        bread = {
            enabled = true, item = 'bread', label = 'Bread',
            description = 'A fresh-ish loaf from the back shelf.',
            category = 'food', price = 6, salePrice = false, stock = 40, maxPerPurchase = 10
        },
        sandwich = {
            enabled = true, item = 'sandwich', label = 'Sandwich',
            description = 'Pre-packed ham & cheese. Best before... recently.',
            category = 'food', price = 12, salePrice = false, stock = 25, maxPerPurchase = 5
        },
        burger = {
            enabled = true, item = 'burger', label = 'Microwave Burger',
            description = 'Ninety seconds on high and it is almost food.',
            category = 'food', price = 15, salePrice = false, stock = 25, maxPerPurchase = 5
        },

        -- Liquor (remove this category if your server does not want alcohol)
        pisswasser = {
            enabled = true, item = 'pisswasser', label = 'Pißwasser',
            description = 'You are in for a good time. German-style lager.',
            category = 'alcohol', price = 12, salePrice = false, stock = 30, maxPerPurchase = 6
        },

        -- Essentials
        bandage = {
            enabled = true, item = 'bandage', label = 'Bandage',
            description = 'For scrapes, cuts and minor gunshot wounds.',
            category = 'essentials', price = 25, salePrice = false, stock = 20, maxPerPurchase = 5
        },

        -- Misc
        lighter = {
            enabled = true, item = 'lighter', label = 'Lighter',
            description = 'Disposable lighter. Please do not burn down the store.',
            category = 'misc', price = 4, salePrice = false, stock = 30, maxPerPurchase = 3
        },
        cigarettes = {
            enabled = true, item = 'cigarettes', label = 'Redwood Cigarettes',
            description = 'Redwood. Smoke like a real cowboy.',
            category = 'misc', price = 18, salePrice = false, stock = 25, maxPerPurchase = 3
        }
    },

    -- Vanilla GTA V 24/7 counters. Adjust the coords if you use an MLO that moves the till.
    -- Location IDs must be unique across ALL brands.
    --
    -- priceMultiplier:          1.0 = normal, 0.9 = 10% cheaper, 1.2 = 20% more expensive
    -- productIds / categoryIds: false = everything, or a table to limit what that store sells
    Locations = {
        store247_strawberry   = Config.Location(location, '24/7 Strawberry',        24.47,  -1346.62,  29.50, 271.66),
        store247_downtownvw   = Config.Location(location, '24/7 Downtown Vinewood', 372.66,   326.98, 103.57, 253.73),
        store247_chumash      = Config.Location(location, '24/7 Chumash',         -3039.18,   584.21,   7.91,  17.27),
        store247_banham       = Config.Location(location, '24/7 Banham Canyon',   -3242.97,   1000.01, 12.83, 357.57),
        store247_palomino     = Config.Location(location, '24/7 Palomino Fwy',     2557.28,    380.64, 108.62, 356.67),
        store247_sandy        = Config.Location(location, '24/7 Sandy Shores',     1959.82,   3740.48,  32.34, 301.57),
        store247_harmony      = Config.Location(location, '24/7 Harmony',           549.13,   2671.37,  42.16,  99.39),
        store247_senora       = Config.Location(location, '24/7 Senora Fwy',       2677.47,   3279.76,  55.24, 335.08),
        -- Same counter as ltd_grapeseed (the vanilla Grapeseed store is an LTD), so it's off
        -- to avoid two cashiers standing inside each other. Enable one or the other.
        store247_grapeseed    = Config.Location(location, '24/7 Grapeseed',        1697.87,   4922.96,  42.06, 324.71, {
            enabled = false
        }),
        store247_paleto       = Config.Location(location, '24/7 Paleto Bay',       1728.33,   6416.21,  35.04, 247.63, {
            priceMultiplier = 1.10 -- out in the sticks, a bit pricier
        })
    },

    Locale = {
        ShopTitle = '24/7 Supermarket',
        Target = 'Shop at 24/7',

        TooFar = 'You are too far away from the counter.',
        InvalidShop = 'This 24/7 is closed right now.',
        InvalidCart = 'Your basket contains invalid items.',
        NoMoney = 'You do not have enough %s.',
        InventoryFull = 'You cannot carry everything in your basket.',
        OutOfStock = '%s is out of stock.',
        PurchaseComplete = 'Thanks for shopping at 24/7! Paid %s%s.',
        PurchaseFailed = 'The till jammed. Transaction failed.',
        Restocked = 'All 24/7 stores have been restocked.',
        ReceiptLabel = '24/7 Receipt'
    }
}
