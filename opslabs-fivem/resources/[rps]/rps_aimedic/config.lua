-- CONFIGURATION SETTINGS
Config = {}

-- EMS ONLINE SETTINGS
Config.Doctor = 1 -- Maximum amount of EMS allowed online for the AI medic to be usable
Config.AmbulanceJobName = "ambulance" -- Job name counted as EMS (matched via rps_lib's framework-agnostic GetPlayerData)

-- PAYMENT SETTINGS
Config.Price = 1000 -- Default payment amount
Config.PaymentMethod = "bank" -- Account charged/refunded: "cash", "bank", or any other account rps_lib's active framework supports

-- PROGRESSBAR SETTINGS
Config.ReviveTime = 20000 -- Time in milliseconds for the revive progressbar
Config.ProgressbarText = "The medic is treating you"
Config.ProgressbarDisableMovement = false
Config.ProgressbarDisableCarMovement = false
Config.ProgressbarDisableMouse = false
Config.ProgressbarDisableCombat = true

-- ANTI-ABUSE SETTINGS
Config.Cooldown = 60000 -- Time in milliseconds a player must wait between /aimedic requests
Config.MedicTimeout = 6000 -- Time in milliseconds the medic will try to path to the player before instead being teleported to them

-- COMMAND SETTINGS
Config.CommandName = "aimedic" -- Example command name

-- MESSAGES
Config.Messages = {
    notDowned = "This can only be used while you are downed",
    alreadyRequested = "A medic has already been requested",
    onCooldown = "You must wait %d more second(s) before requesting another medic",
    tooManyEMS = "There are currently %d EMT's online. The maximum allowed is %d",
    notEnoughMoney = "Not Enough Money",
    onTheWay = "Your medic is on the way",
    treatmentComplete = "Your treatment is complete. You have been charged: $%d",
    medicPulledToYou = "The medic couldn't reach you, so you were moved to them instead",
    medicTimedOut = "The medic could not reach you. You have been refunded.",
    genericError = "Something went wrong, please try again",
}

--v1.0.3
