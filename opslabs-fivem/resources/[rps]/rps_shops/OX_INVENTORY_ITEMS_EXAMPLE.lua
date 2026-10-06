-- EXAMPLE item definitions for ox_inventory/data/items.lua
-- Add only the items you don't already have. DO NOT add duplicates of items your server already defines.
--
-- ox_inventory already ships with: water, sprunk, burger, bandage, radio, parachute, phone, money
-- and these weapons (data/weapons.lua): WEAPON_HAMMER, WEAPON_WRENCH, WEAPON_CROWBAR,
-- WEAPON_HATCHET, WEAPON_FLASHLIGHT, WEAPON_PETROLCAN
--
-- Hunger/thirst "status" works with esx_status (ESX) or qb/qbx metadata via ox_inventory.

-- Copy the entries INSIDE the table below (from ['ecola'] down) into the table
-- in ox_inventory/data/items.lua. The wrapper only keeps this file valid Lua;
-- it is not loaded by the resource.

return {

-- ============================================
--  24/7 Supermarket + LTD Gasoline (food / drinks / misc)
-- ============================================

['ecola'] = {
    label = 'eCola',
    weight = 350,
    client = {
        status = { thirst = 200000 },
        anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
        prop = { model = `prop_ecola_can`, pos = vec3(0.01, 0.01, 0.06), rot = vec3(5.0, 5.0, -180.5) },
        usetime = 2500,
        notification = 'You drank an eCola'
    }
},

['coffee'] = {
    label = 'Coffee',
    weight = 300,
    client = {
        status = { thirst = 150000 },
        anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
        prop = { model = `p_amb_coffeecup_01`, pos = vec3(0.0, 0.0, 0.0), rot = vec3(0.0, 0.0, 0.0) },
        usetime = 3000,
        notification = 'That hit the spot'
    }
},

['chips'] = {
    label = 'Phat Chips',
    weight = 100,
    client = {
        status = { hunger = 100000 },
        anim = 'eating',
        usetime = 2500,
        notification = 'You ate some chips'
    }
},

['egochaser'] = {
    label = 'EgoChaser Bar',
    weight = 80,
    client = {
        status = { hunger = 120000 },
        anim = 'eating',
        prop = { model = `prop_choc_ego`, pos = vec3(0.01, 0.0, -0.01), rot = vec3(0.0, 0.0, 0.0) },
        usetime = 2500,
        notification = 'You ate an EgoChaser'
    }
},

['meteorite'] = {
    label = 'Meteorite Bar',
    weight = 80,
    client = {
        status = { hunger = 120000 },
        anim = 'eating',
        prop = { model = `prop_choc_meto`, pos = vec3(0.01, 0.0, -0.01), rot = vec3(0.0, 0.0, 0.0) },
        usetime = 2500,
        notification = 'You ate a Meteorite bar'
    }
},

['donut'] = {
    label = 'Donut',
    weight = 100,
    client = {
        status = { hunger = 150000 },
        anim = 'eating',
        prop = { model = `prop_amb_donut`, pos = vec3(0.01, 0.0, -0.01), rot = vec3(0.0, 0.0, 0.0) },
        usetime = 2500,
        notification = 'You ate a donut'
    }
},

['bread'] = {
    label = 'Bread',
    weight = 200,
    client = {
        status = { hunger = 200000 },
        anim = 'eating',
        usetime = 2500,
        notification = 'You ate some bread'
    }
},

['sandwich'] = {
    label = 'Sandwich',
    weight = 250,
    client = {
        status = { hunger = 300000 },
        anim = 'eating',
        prop = { model = `prop_sandwich_01`, pos = vec3(0.02, 0.02, -0.02), rot = vec3(0.0, 0.0, 0.0) },
        usetime = 3000,
        notification = 'You ate a sandwich'
    }
},

['pisswasser'] = {
    label = 'Pißwasser',
    weight = 500,
    client = {
        status = { thirst = 100000 },
        anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
        prop = { model = `prop_amb_beer_bottle`, pos = vec3(0.0, 0.0, 0.05), rot = vec3(0.0, 0.0, 0.0) },
        usetime = 3000,
        notification = 'Prost!'
    }
},

['lighter'] = {
    label = 'Lighter',
    weight = 30,
    stack = true,
},

['cigarettes'] = {
    label = 'Redwood Cigarettes',
    weight = 50,
    stack = true,
},

-- ============================================
--  YouTool (plain items - hook them into your mechanic / heist / job scripts)
-- ============================================

['screwdriver'] = {
    label = 'Screwdriver Set',
    weight = 300,
    stack = true,
},

['drill'] = {
    label = 'Cordless Drill',
    weight = 2000,
    stack = false,
},

['grinder'] = {
    label = 'Angle Grinder',
    weight = 2500,
    stack = false,
},

['repairkit'] = {
    label = 'Repair Kit',
    weight = 2500,
    stack = true,
},

['tyrekit'] = {
    label = 'Tyre Kit',
    weight = 1500,
    stack = true,
},

['cleaningkit'] = {
    label = 'Cleaning Kit',
    weight = 800,
    stack = true,
},

['rope'] = {
    label = 'Rope',
    weight = 600,
    stack = true,
},

['ducttape'] = {
    label = 'Duct Tape',
    weight = 150,
    stack = true,
},

['zipties'] = {
    label = 'Zip Ties',
    weight = 100,
    stack = true,
},

['binoculars'] = {
    label = 'Binoculars',
    weight = 600,
    stack = false,
},

-- ============================================
--  Digital Den
-- ============================================

['tablet'] = {
    label = 'Tablet',
    weight = 700,
    stack = false,
    close = true,
},

['laptop'] = {
    label = 'Laptop',
    weight = 2200,
    stack = false,
    close = true,
},

['headphones'] = {
    label = 'Headphones',
    weight = 350,
    stack = false,
    close = true,
},

['camera'] = {
    label = 'Camera',
    weight = 850,
    stack = false,
    close = true,
},

['usb'] = {
    label = 'USB Drive',
    weight = 50,
    stack = true,
    close = true,
},

['powerbank'] = {
    label = 'Power Bank',
    weight = 400,
    stack = true,
    close = true,
},

['smartwatch'] = {
    label = 'Smart Watch',
    weight = 120,
    stack = false,
    close = true,
},

-- ============================================
--  Receipts (only needed for brands with Receipt.Enabled = true)
-- ============================================

['supermarket_receipt'] = {
    label = '24/7 Receipt',
    weight = 5,
    stack = false,
    close = true,
},

['ltd_receipt'] = {
    label = 'LTD Receipt',
    weight = 5,
    stack = false,
    close = true,
},

['youtool_receipt'] = {
    label = 'YouTool Receipt',
    weight = 5,
    stack = false,
    close = true,
},

['digitalden_receipt'] = {
    label = 'Digital Den Receipt',
    weight = 5,
    stack = false,
    close = true,
}

}
