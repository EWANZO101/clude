Config = {}

-- General Settings
Config.Command = "ads"             -- /ads "your message"
Config.Price = 0                -- cost per ad (0 = free)
Config.Account = "bank"            -- account charged for ads ('bank' or 'cash')
Config.Cooldown = 0               -- seconds a player must wait between ads
Config.MaxLength = 150             -- max characters in an ad message
Config.Logs = "https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE"


-- Lifeinvader: used when the player's job isn't listed in Businesses or Gangs.
Config.LifeInvader = {
    enabled = true,
    price = 0,                  -- separate price for Lifeinvader ads
    title = "anonymous",
    category = "public",
    imageUrl = "",                 -- put a Lifeinvader logo URL here
    duration = 10,
}


-- Businesses: key = job name. Players with this job can run /ads.
Config.Businesses = {

    ["police"] = {
        title = "SAPS",
        imageUrl = "https://seeklogo.com/images/S/south-african-police-service-logo-6BDCE827FF-seeklogo.com.png",
        duration = 10,
        type = "business"
    },

}


-- Gangs: `gang` = the gang name.
--   QBCore / QBox: matched against the player's gang (PlayerData.gang.name)
--   ESX:           matched against the player's job (ESX has no gangs)
Config.Gangs = {

    [1] = {
        gang = "cartel",   -- QB/QBox: gang name | ESX: job name
        title = "The Cartel",
        imageUrl = "https://cdn.discordapp.com/attachments/1497481473177944094/1500938033317281962/ChatGPT_Image_Feb_3_2026_05_07_58_PM.png",
        duration = 10,
        type = "gang"
    },

    [2] = {
        gang = "ballas",
        title = "The Ballas",
        imageUrl = "https://cdn.discordapp.com/attachments/1497481473177944094/1500938032566632508/ChatGPT_Image_Feb_3_2026_04_06_48_PM.png",
        duration = 10,
        type = "gang"
    },

}
