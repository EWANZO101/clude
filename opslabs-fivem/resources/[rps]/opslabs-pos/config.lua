-- OPS POS Systems: point of sale for stores. The hardware is OPS kit placed with /towers (opslabs-props models);
-- a business boss sets up a till at a placed terminal and from then on staff ring up sales on it.
Config = {}

Config.Company = 'pos'                -- OPS platform company (opslabs-phone sql/ops_catalog.json) that gets licence fees and card fees
Config.Currency = '$'
Config.Locale = 'en-US'

-- the kit (opslabs-props models). A store's till uses every piece within KitRadius of its terminal.
Config.Models = {
    terminal = 'opslabs_pos_terminal',
    display = 'opslabs_pos_display',
    reader = 'opslabs_pos_cardreader',
    scanner = 'opslabs_pos_scanner',
    printer = 'opslabs_pos_printer',
    drawer = 'opslabs_pos_drawer',
}
Config.KitRadius = 3.0                -- metres from the terminal
Config.UseDistance = 1.6              -- how close you stand to the terminal to use it
Config.CustomerDistance = 3.5         -- customers this close to the terminal can be charged
Config.DisplayDistance = 6.0          -- players this close to the customer display see the basket
Config.RequirePower = false           -- true = the terminal must be plugged into a live socket (opslabs-towers mains)

-- POS software licence: charged to the business's society account every period, paid to Config.Company
Config.Licence = {
    SetupFee = 500,                   -- once, when a boss sets the till up
    Monthly = 250,                    -- every PeriodDays
    PeriodDays = 7,                   -- real days between licence bills
    GraceDays = 2,                    -- unpaid this long → the till is suspended until a boss pays it
}

-- payments
Config.Payments = {
    CardFeePct = 1.75,                -- payment processor fee on card / contactless sales, paid to Config.Company
    CardTimeout = 30,                 -- seconds the customer has to approve on their phone
    TaxPct = 0,                       -- default sales tax for a new store (bosses change it on the till)
    CashBank = 'cash',                -- the customer's cash account (FW money account)
    CardBank = 'bank',                -- the account card payments come out of
    MaxSale = 50000,
}

-- loyalty: points per currency unit spent, and what a point is worth when redeemed
Config.Loyalty = { PointsPer = 0.1, PointValue = 0.05, MinRedeem = 100 }

-- receipts: a printed receipt (item, with metadata) when the store has a printer, otherwise a phone notification
Config.ReceiptItem = 'ops_receipt'

-- staff
Config.Staff = {
    RequireClockIn = true,            -- staff must clock in on the till before they can sell
    MaxShiftHours = 12,               -- shifts left open longer are closed at this length
}

-- NPC shops (rps_shops): a store set up within this distance of an rps_shops shop owns it. That shop's takings then
-- go to the business (cash into the society, card payments through OPS POS), and the till's reports include them.
Config.NpcShops = {
    Enabled = true,
    LinkDistance = 25.0,
    StaffName = 'Store assistant',    -- who the NPC sales are recorded under
}

-- who counts as a boss of a business (can set up tills, change prices, refund, cash up, see reports):
-- rps_bossmenu decides when it's running, otherwise these ESX grade names
Config.BossGrades = { boss = true, owner = true, manager = true }
