Config = {}

-- ════════════════════════════════════════════════════════════════════════════════════
-- TAX SYSTEM CONFIGURATION
-- ════════════════════════════════════════════════════════════════════════════════════

--- Enable or disable the entire tax system
Config.Enabled = true

--- Tax collection interval (in minutes)
--- Default: 60 minutes (1 hour)
Config.TaxInterval = 240 -- every 4 hours

--- Debug mode - prints additional information to console
Config.Debug = false

--- Currency symbol to display in notifications and messages
Config.CurrencySymbol = 'R'

-- ════════════════════════════════════════════════════════════════════════════════════
-- BANK BALANCE TAX CONFIGURATION
-- ════════════════════════════════════════════════════════════════════════════════════

--- Enable bank balance tax
Config.BankTax = {
    enabled = true,
    
    --- Tax percentage on bank balance (0.01 = 1%, 0.05 = 5%)
    percentage = 0.01, -- 1% tax on bank balance
    
    --- Minimum bank balance required to be taxed
    minBalance = 100,
    
    --- Maximum tax amount per collection (0 = no limit)
    maxTaxAmount = 0,
    
    --- Exempt job roles from bank tax (case-sensitive)
    exemptJobs = {
       -- 'police',
       -- 'ambulance',
       -- 'government'
    }
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- VEHICLE TAX CONFIGURATION
-- ════════════════════════════════════════════════════════════════════════════════════

--- Enable vehicle ownership tax
Config.VehicleTax = {
    enabled = true,
    
    --- Tax amount per vehicle owned
    perVehicle = 500,
    
    --- Minimum vehicles owned to be taxed
    minVehicles = 1,
    
    --- Maximum tax amount per collection (0 = no limit)
    maxTaxAmount = 0,
    
    --- Vehicle database configuration
    --- table = 'auto' picks it from the framework rps_lib detects:
    ---   ESX -> owned_vehicles.owner | QBCore / QBox -> player_vehicles.citizenid
    --- Set table + ownerColumn manually to override.
    database = {
        table = 'auto',
        ownerColumn = 'citizenid' -- only used when table is not 'auto'
    },
    
    --- Exempt job roles from vehicle tax
    exemptJobs = {
       -- 'police',
       -- 'ambulance'
    }
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- NOTIFICATION CONFIGURATION
-- ════════════════════════════════════════════════════════════════════════════════════

--- Notification settings (sent through rps_lib: codem-supreme-notification,
--- ox_lib or the framework's own notify, whichever rps_lib detects)
Config.Notifications = {
    enabled = true,
    
    --- Notification position ('top', 'top-right', 'top-left', 'bottom', 'bottom-right', 'bottom-left', 'center-right', 'center-left')
    position = 'bottom',
    
    --- Duration in milliseconds
    duration = 8000,
    
    --- Notification types
    types = {
        success = 'success',
        error = 'error',
        info = 'inform'
    }
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- PHONE CONFIGURATION (via rps_lib: lb-phone / qb-phone, auto-detected)
-- ════════════════════════════════════════════════════════════════════════════════════

Config.Phone = {
    enabled = true,

    --- Send a tax notice to the phone's mail app
    --- (lb-phone falls back to an SMS if the player has no mail account)
    mail = true,

    --- Push a transaction to the phone's banking / wallet app
    bankingAlert = true,
    bankingAlertTitle = 'Tax Authority',

    --- Mail sender information
    sender = 'Tax Authority',
    senderNumber = 'TAX-DEPT', -- SMS sender (lb-phone fallback)

    --- Mail subject templates
    subjects = {
        taxCollected = 'Tax Collection Notice',
        taxFailed = 'Tax Payment Failed',
        taxExempt = 'Tax Exemption Notice'
    },

    --- Send the breakdown mail on successful collection
    detailedBreakdown = true
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- BANKING CONFIGURATION (via rps_lib: qb-banking / Renewed-Banking, ESX: esx_addonaccount)
-- ════════════════════════════════════════════════════════════════════════════════════

--- Split each cycle's collected tax across one or more society / government accounts
Config.Banking = {
    enabled = true,

    --- Default transaction reason (where the bank resource supports it)
    reason = 'Government Tax Collection',

    --- Accounts that receive tax revenue
    ---   account : job/society name (ESX uses 'society_<name>' in esx_addonaccount,
    ---             the prefix is added automatically)
    ---   share   : portion of the revenue (0.5 = 50%)
    ---   from    : (optional) which tax it takes a share of: 'all' (default), 'bank' or 'vehicle'
    ---   reason  : (optional) overrides the default reason for this account
    ---
    --- Shares of the same `from` should add up to 1.0 (100%). Anything less is not
    --- deposited anywhere (it leaves the economy); more than 1.0 is rejected at startup.
    accounts = {
        { account = 'mechanic', share = 0.60 },
        { account = 'police',     share = 0.20 },
        { account = 'ambulance',  share = 0.20 },

        -- Example: send all vehicle tax to a separate account instead
        -- { account = 'mechanic', share = 1.0, from = 'vehicle', reason = 'Road Tax' },
    }
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- DISCORD WEBHOOK CONFIGURATION
-- ════════════════════════════════════════════════════════════════════════════════════

--- Discord webhook settings
Config.Webhook = {
    enabled = true,
    
    --- Webhook URLs are set in server/webhooks.lua (server-only, so players can't read them)

    --- Bot name that appears in Discord
    botName = 'rps Tax System',
    
    --- Bot avatar URL
    avatarUrl = 'https://i.imgur.com/4M34hi2.png',
    
    --- Embed colors (in decimal format)
    colors = {
        success = 3066993,  -- Green
        error = 15158332,   -- Red
        info = 3447003,     -- Blue
        warning = 16776960  -- Yellow
    },
    
    --- Log different tax events
    events = {
        taxCollected = true,      -- Log successful tax collections (per player)
        taxFailed = true,         -- Log failed tax collections (per player)
        taxExempt = false,        -- Log exempt players (can be spammy)
        collectionSummary = true, -- Log the end-of-cycle summary
        manualTrigger = true,     -- Log when an admin runs /collecttaxes
        systemStart = true,       -- Log when tax system starts
        systemError = true        -- Log system errors
    },
    
    --- Include player identifiers in webhook
    includeIdentifiers = true,
    
    --- Footer text
    footer = 'rps Tax System',
    
    --- Timestamp format
    timestamp = true,

    --- Throttle settings to prevent server hangs during bursts
    throttle = {
        enabled = true,          -- enable throttling
        delayMs = 250,           -- delay between sends (ms)
        maxPerCycle = 20,        -- max webhook messages during a single tax cycle
        summaryOnlyOnCap = true  -- when cap reached, only send the final summary
    }
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- LANGUAGE / TEXT CONFIGURATION
-- ════════════════════════════════════════════════════════════════════════════════════

--- Customizable text messages
Config.Messages = {
    -- Tax collection messages
    taxCollected = 'You have been taxed %s (Bank: %s | Vehicles: %s)',
    taxFailed = 'Tax collection failed: Insufficient funds. You owe %s',
    taxExempt = 'You are exempt from taxes due to your job position',
    
    -- Email messages
    emailTaxCollected = [[
Hello,

This is an automated notice from the Tax Authority.

Your taxes have been successfully collected:
- Bank Tax: %s
- Vehicle Tax: %s
- Total: %s

Thank you for your contribution.

Tax Authority
]],

    emailTaxFailed = [[
Hello,

This is an automated notice from the Tax Authority.

We attempted to collect taxes from your account but you had insufficient funds.

Amount Due: %s

Please ensure you have sufficient funds for the next collection cycle.

Tax Authority
]],

    -- System messages
    systemStart = 'Tax system initialized. Next collection in %s minutes.',
    systemError = 'Tax system error: %s'
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- ADVANCED SETTINGS
-- ════════════════════════════════════════════════════════════════════════════════════

--- Run tax collection on resource start
Config.CollectOnStart = false

--- Delay before first tax collection on resource start (in minutes)
Config.StartDelay = 5

--- Notify offline players when they reconnect about missed taxes
Config.NotifyOfflineTaxes = false

--- Allow negative balance (debt) when collecting taxes
Config.AllowNegativeBalance = true

return Config
