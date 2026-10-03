local isAdVisible = false

-- Show NUI and send ad data
local function ShowAd(adData)
    if isAdVisible then return end
    isAdVisible = true

    SetNuiFocus(false, false)
    SendNUIMessage({
        action = "showAd",
        data = {
            title    = adData.title,
            category = adData.category or "ADVERTISEMENT",
            message  = adData.message or "",
            imageUrl = adData.imageUrl or "",
            duration = (adData.duration or 10) * 1000,
            type     = adData.type or "default"
        }
    })
end

-- Hide the ad UI
local function HideAd()
    isAdVisible = false
    SendNUIMessage({ action = "hideAd" })
end

-- NUI callback: ad timer expired on the frontend
RegisterNUICallback("adExpired", function(_, cb)
    isAdVisible = false
    cb({ success = true })
end)

-- Server broadcasts an ad
RegisterNetEvent("rps_ads:client:showAd", function(data)
    ShowAd(data)
end)

TriggerEvent("chat:addSuggestion", "/" .. Config.Command, "Post an ad for your business or gang", {
    { name = "message", help = '"your message"' }
})

-- Server asks client to hide the ad early
RegisterNetEvent("rps_ads:client:hideAd", function()
    HideAd()
end)
