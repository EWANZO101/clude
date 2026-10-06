-- Framework (ESX / QBCore / QBox / standalone) and notifications are handled by rps_lib.
-- Force a framework with: setr rps_lib:forceFramework "esx"
local rps = exports.rps_lib
local cooldowns = {}

CreateThread(function()
    Wait(500) -- rps_lib detects the framework asynchronously on start
    print(('[rps_ads] Framework: %s (via rps_lib)'):format(rps:GetFrameworkName()))
end)

local function Notify(src, msg, type)
    rps:ShowNotification(src, { title = "RPS Ads", description = msg, type = type or "info" })
end

local function GetCharName(data, src)
    if data.firstname and data.lastname then
        return data.firstname .. " " .. data.lastname
    end
    return data.name or GetPlayerName(src)
end

-- Utility: send a Discord webhook log
local function WebhookLog(title, description, color)
    if not Config.Logs or Config.Logs == "" then return end
    PerformHttpRequest(Config.Logs, function() end, "POST",
        json.encode({
            embeds = {{
                title       = title,
                description = description,
                color       = color or 3447003,
                footer      = { text = "RPS Ads | " .. os.date("%Y-%m-%d %H:%M:%S") }
            }}
        }),
        { ["Content-Type"] = "application/json" }
    )
end

-- QBCore / QBox: the player's gang name. ESX / standalone: the job name (no gangs there).
local function GetGangName(src, jobName)
    local fw = rps:GetFrameworkName()
    local player
    if fw == "qbox" then
        player = exports.qbx_core:GetPlayer(src)
    elseif fw == "qb" then
        player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    else
        return jobName
    end
    local gang = player and player.PlayerData and player.PlayerData.gang
    return gang and gang.name or nil
end

-- Find the ad profile for a player: business (job) -> gang -> Lifeinvader
local function GetAdProfile(src, jobName)
    if jobName then
        local biz = Config.Businesses[jobName]
        if biz then return biz, "BUSINESS", biz.type or "business", Config.Price end
    end

    local gangName = GetGangName(src, jobName)
    if gangName then
        for _, gang in pairs(Config.Gangs) do
            if (gang.gang or gang.job) == gangName then return gang, "GANG", "gang", Config.Price end
        end
    end

    local li = Config.LifeInvader
    if li and li.enabled then
        return li, li.category or "CLASSIFIED", "lifeinvader", li.price or Config.Price
    end
end

-- Pull the message out of the raw command, dropping surrounding quotes
local function ParseMessage(rawCommand)
    local msg = rawCommand:match("^%S+%s+(.+)$") or ""
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
    msg = msg:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
    return msg
end

-- /ads "message" — broadcasts an ad for the player's job
RegisterCommand(Config.Command, function(source, _, rawCommand)
    local src = source
    if src == 0 then return end

    local data = rps:GetPlayerData(src)
    if not data then return end

    local jobName = data.job and data.job.name
    local profile, category, adType, price = GetAdProfile(src, jobName)
    if not profile then
        Notify(src, "Your job can't post ads.", "error")
        return
    end

    local message = ParseMessage(rawCommand)
    if message == "" then
        Notify(src, ('Usage: /%s "your message"'):format(Config.Command), "error")
        return
    end
    if #message > Config.MaxLength then
        Notify(src, ("Message too long (max %d characters)."):format(Config.MaxLength), "error")
        return
    end

    local now = os.time()
    local last = cooldowns[src]
    if last and now - last < Config.Cooldown then
        Notify(src, ("Wait %ds before posting another ad."):format(Config.Cooldown - (now - last)), "error")
        return
    end

    if price > 0 and not rps:RemoveMoney(src, price, Config.Account) then
        Notify(src, "Insufficient funds.", "error")
        return
    end

    cooldowns[src] = now

    TriggerClientEvent("rps_ads:client:showAd", -1, {
        title    = profile.title,
        category = category,
        message  = message,
        imageUrl = profile.imageUrl or "",
        duration = profile.duration or 10,
        type     = adType
    })

    Notify(src, "Your ad has been broadcast!", "success")

    WebhookLog(
        "Ad Posted",
        ("**%s** (ID: %d, job: %s) posted an ad for **%s** — $%d\n> %s"):format(
            GetCharName(data, src), src, tostring(jobName), profile.title, price, message
        ),
        adType == "gang" and 15158332 or adType == "lifeinvader" and 15277667 or 5763719
    )
end, false)

AddEventHandler("playerDropped", function()
    cooldowns[source] = nil
end)
