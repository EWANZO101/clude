-- ============================================
--  YouTool  (was rps_YouTool)
-- ============================================
local location = {
    pedModel = 's_m_y_construct_01',
    scenario = 'WORLD_HUMAN_CLIPBOARD',
    blipLabel = 'YouTool'
}

Config.Brands.youtool = {
    enabled = true,

    -- NUI theme folder: web/themes/<theme>
    theme = 'youtool',

    UI = {
        Accent = '#f47b20',          -- YouTool orange
        AccentAlt = '#ffd23f',       -- safety yellow (hazard stripes, deals, LED text)
        StoreTagline = 'TOOLS • HARDWARE • AUTO • BLAINE COUNTY',
        FooterText = 'YOUTOOL • YOU BUILD IT, YOU TOOL IT',
        ShowItemImages = true,

        -- Decorative board in the sidebar (text only, nothing is sold). Set rows = {} to hide it.
        PriceBoard = {
            title = 'TOOL RENTAL',
            note = 'Ask at the Pro Desk. Deals tagged in yellow.',
            rows = {
                { label = 'CEMENT MIXER', price = '$120/D' },
                { label = 'JACKHAMMER',   price = '$95/D' },
                { label = 'FLATBED',      price = '$250/D' },
                { label = 'CHAINSAW',     price = '$60/D' }
            }
        }
    },

    Target = {
        Icon = 'fa-solid fa-screwdriver-wrench',
        Label = 'Shop at YouTool'
    },

    Stock = {
        RestockMinutes = 30
    },

    Receipt = {
        Enabled = true,
        Item = 'youtool_receipt'
    },

    Blip = {
        Enabled = true,
        Sprite = 402,  -- wrench
        Colour = 17,   -- orange
        Scale = 0.75,
        ShortRange = true
    },

    Admin = {
        RestockCommand = 'restockyoutool',
        AcePermission = 'youtool.admin'
    },

    -- Category order is controlled by this table.
    -- icon = Font Awesome icon name (without "fa-"), emoji = fallback when an item image is missing.
    Categories = {
        { id = 'handtools',  label = 'Hand Tools',  icon = 'hammer',             emoji = '🔨' },
        { id = 'powertools', label = 'Power Tools', icon = 'plug',               emoji = '🪚' },
        { id = 'automotive', label = 'Automotive',  icon = 'oil-can',            emoji = '🔧' },
        { id = 'hardware',   label = 'Hardware',    icon = 'screwdriver-wrench', emoji = '🔩' },
        { id = 'electrical', label = 'Electrical',  icon = 'bolt',               emoji = '🔋' },
        { id = 'outdoors',   label = 'Outdoors',    icon = 'tree',               emoji = '🪓' }
    },

    -- Product IDs are internal to this brand.
    -- "item" must match an item name in your inventory (see OX_INVENTORY_ITEMS_EXAMPLE.lua).
    -- WEAPON_* items are the melee/utility weapons ox_inventory already ships with.
    --
    -- stock:      number = finite server-side stock, false = unlimited
    -- salePrice:  nil/false = normal price, number = discounted price displayed and charged
    -- image:      nil = automatic (Config.ItemImages), string = custom NUI image URL/path
    Products = {
        -- Hand Tools
        hammer = {
            enabled = true, item = 'WEAPON_HAMMER', label = 'Claw Hammer',
            description = 'Drives nails, pulls nails. Mostly nails.',
            category = 'handtools', price = 45, salePrice = false, stock = 20, maxPerPurchase = 2
        },
        wrench = {
            enabled = true, item = 'WEAPON_WRENCH', label = 'Pipe Wrench',
            description = 'Heavy, reliable and surprisingly versatile.',
            category = 'handtools', price = 55, salePrice = false, stock = 15, maxPerPurchase = 2
        },
        crowbar = {
            enabled = true, item = 'WEAPON_CROWBAR', label = 'Crowbar',
            description = 'For opening crates. Only crates. Right?',
            category = 'handtools', price = 75, salePrice = 60, stock = 15, maxPerPurchase = 1
        },
        screwdriver = {
            enabled = true, item = 'screwdriver', label = 'Screwdriver Set',
            description = 'Flat, Phillips and the weird star one.',
            category = 'handtools', price = 15, salePrice = false, stock = 30, maxPerPurchase = 3
        },

        -- Power Tools
        drill = {
            enabled = true, item = 'drill', label = 'Cordless Drill',
            description = '18V brushless. Battery sold separately. Obviously.',
            category = 'powertools', price = 350, salePrice = false, stock = 8, maxPerPurchase = 1
        },
        grinder = {
            enabled = true, item = 'grinder', label = 'Angle Grinder',
            description = 'Cuts metal, sparks joy. Wear goggles.',
            category = 'powertools', price = 280, salePrice = 240, stock = 6, maxPerPurchase = 1
        },

        -- Automotive
        repairkit = {
            enabled = true, item = 'repairkit', label = 'Repair Kit',
            description = 'Gets a dead engine limping back to the shop.',
            category = 'automotive', price = 250, salePrice = false, stock = 12, maxPerPurchase = 3
        },
        tyrekit = {
            enabled = true, item = 'tyrekit', label = 'Tyre Kit',
            description = 'Patch, plug and pump. Back on the road in minutes.',
            category = 'automotive', price = 120, salePrice = false, stock = 12, maxPerPurchase = 3
        },
        cleaningkit = {
            enabled = true, item = 'cleaningkit', label = 'Cleaning Kit',
            description = 'Sponge, soap and wax. Hides the evidence of Sandy Shores dust.',
            category = 'automotive', price = 40, salePrice = false, stock = 20, maxPerPurchase = 5
        },
        jerrycan = {
            enabled = true, item = 'WEAPON_PETROLCAN', label = 'Jerry Can',
            description = '20 litres of red plastic. Fuel not included.',
            category = 'automotive', price = 80, salePrice = false, stock = 15, maxPerPurchase = 2
        },

        -- Hardware
        rope = {
            enabled = true, item = 'rope', label = 'Rope',
            description = '15 m of braided nylon. Holds a boat, a load or a grudge.',
            category = 'hardware', price = 20, salePrice = false, stock = 30, maxPerPurchase = 5
        },
        ducttape = {
            enabled = true, item = 'ducttape', label = 'Duct Tape',
            description = 'If it moves and it should not: tape.',
            category = 'hardware', price = 8, salePrice = false, stock = 40, maxPerPurchase = 5
        },
        zipties = {
            enabled = true, item = 'zipties', label = 'Zip Ties',
            description = 'Pack of 50 heavy-duty cable ties.',
            category = 'hardware', price = 10, salePrice = false, stock = 40, maxPerPurchase = 5
        },

        -- Electrical
        radio = {
            enabled = true, item = 'radio', label = 'Two-Way Radio',
            description = 'Handheld radio for job sites and long drives.',
            category = 'electrical', price = 150, salePrice = false, stock = 10, maxPerPurchase = 2
        },
        flashlight = {
            enabled = true, item = 'WEAPON_FLASHLIGHT', label = 'Flashlight',
            description = 'Heavy-duty, waterproof and way too bright.',
            category = 'electrical', price = 35, salePrice = false, stock = false, maxPerPurchase = 2
        },

        -- Outdoors
        hatchet = {
            enabled = true, item = 'WEAPON_HATCHET', label = 'Hatchet',
            description = 'Firewood, kindling and Blaine County survival.',
            category = 'outdoors', price = 90, salePrice = false, stock = 10, maxPerPurchase = 1
        },
        binoculars = {
            enabled = true, item = 'binoculars', label = 'Binoculars',
            description = 'Bird watching. Totally just bird watching.',
            category = 'outdoors', price = 120, salePrice = false, stock = 10, maxPerPurchase = 1
        },
        parachute = {
            enabled = true, item = 'parachute', label = 'Parachute',
            description = 'For Mount Chiliad and other bad ideas.',
            category = 'outdoors', price = 400, salePrice = false, stock = 5, maxPerPurchase = 1
        }
    },

    -- The Senora Fwy YouTool is the vanilla GTA V store. The other two are the
    -- common hardware-store spots used by most servers; disable them if you don't want them.
    -- Location IDs must be unique across ALL brands.
    --
    -- priceMultiplier:          1.0 = normal, 0.9 = 10% cheaper, 1.2 = 20% more expensive
    -- productIds / categoryIds: false = everything, or a table to limit what that store sells
    Locations = {
        youtool_senora = Config.Location(location, 'YouTool Senora Fwy',  2747.71, 3472.85, 55.67, 255.08),
        youtool_davis  = Config.Location(location, 'YouTool Davis',         45.68, -1749.04, 29.61,  53.13),
        youtool_paleto = Config.Location(location, 'YouTool Paleto Bay',  -421.83, 6136.13, 31.88, 228.20, {
            priceMultiplier = 1.10 -- out in the sticks, a bit pricier
        })
    },

    Locale = {
        ShopTitle = 'YouTool',
        Target = 'Shop at YouTool',

        TooFar = 'You are too far away from the counter.',
        InvalidShop = 'This YouTool is closed right now.',
        InvalidCart = 'Your cart contains invalid items.',
        NoMoney = 'You do not have enough %s.',
        InventoryFull = 'You cannot carry everything in your cart.',
        OutOfStock = '%s is out of stock.',
        PurchaseComplete = 'Thanks for shopping at YouTool! Paid %s%s.',
        PurchaseFailed = 'The register jammed. Transaction failed.',
        Restocked = 'All YouTool stores have been restocked.',
        ReceiptLabel = 'YouTool Receipt'
    }
}
