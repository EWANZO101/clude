-- ============================================
--  LTD Gasoline  (was rps_LtdGasline)
-- ============================================
local location = {
    pedModel = 'mp_m_shopkeep_01',
    scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
    blipLabel = 'LTD Gasoline'
}

Config.Brands.ltd = {
    enabled = true,

    -- NUI theme folder: web/themes/<theme>
    theme = 'ltd',

    UI = {
        Accent = '#e0261c',          -- LTD red
        AccentAlt = '#ffc20e',       -- LTD yellow
        StoreTagline = 'FUEL • FOOD • DRINKS • LOS SANTOS & BLAINE COUNTY',
        FooterText = 'LTD GASOLINE • FILL UP, STOCK UP',
        ShowItemImages = true,

        -- Decorative pump price board in the sidebar (text only, nothing is sold).
        FuelBoard = {
            { label = 'UNLEADED', price = '3.49' },
            { label = 'PLUS',     price = '3.69' },
            { label = 'PREMIUM',  price = '3.89' },
            { label = 'DIESEL',   price = '3.99' }
        }
    },

    Target = {
        Icon = 'fa-solid fa-gas-pump',
        Label = 'Shop at LTD'
    },

    Stock = {
        RestockMinutes = 20
    },

    Receipt = {
        Enabled = true,
        Item = 'ltd_receipt'
    },

    Blip = {
        Enabled = true,
        Sprite = 52,   -- shopping basket
        Colour = 1,    -- red
        Scale = 0.7,
        ShortRange = true
    },

    Admin = {
        RestockCommand = 'restockltd',
        AcePermission = 'ltdgasoline.admin'
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

    -- Vanilla GTA V LTD Gasoline counters. Adjust the coords if you use an MLO that moves the till.
    -- Location IDs must be unique across ALL brands.
    --
    -- priceMultiplier:          1.0 = normal, 0.9 = 10% cheaper, 1.2 = 20% more expensive
    -- productIds / categoryIds: false = everything, or a table to limit what that store sells
    Locations = {
        ltd_grovestreet   = Config.Location(location, 'LTD Grove Street',   -47.02,  -1758.23,  29.42,  45.05),
        ltd_littleseoul   = Config.Location(location, 'LTD Little Seoul',  -706.06,   -913.97,  19.22,  88.04),
        ltd_richmanglen   = Config.Location(location, 'LTD Richman Glen', -1820.02,    794.03, 138.09, 135.45),
        ltd_mirrorpark    = Config.Location(location, 'LTD Mirror Park',   1164.71,   -322.94,  69.21, 101.72),
        ltd_grapeseed     = Config.Location(location, 'LTD Grapeseed',     1697.87,   4922.96,  42.06, 324.71, {
            priceMultiplier = 1.10 -- out in the sticks, a bit pricier
        })
    },

    Locale = {
        ShopTitle = 'LTD Gasoline',
        Target = 'Shop at LTD',

        TooFar = 'You are too far away from the counter.',
        InvalidShop = 'This LTD is closed right now.',
        InvalidCart = 'Your basket contains invalid items.',
        NoMoney = 'You do not have enough %s.',
        InventoryFull = 'You cannot carry everything in your basket.',
        OutOfStock = '%s is out of stock.',
        PurchaseComplete = 'Thanks for stopping at LTD! Paid %s%s.',
        PurchaseFailed = 'The till jammed. Transaction failed.',
        Restocked = 'All LTD Gasoline stores have been restocked.',
        ReceiptLabel = 'LTD Receipt'
    }
}
