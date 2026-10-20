-- Lets this app submit evidence straight from LB Phone's own camera,
-- independent of OPS Phone / opslabs-bodycam or any other bodycam
-- resource - Xon Sight's webhook contract is generic (POST /evidence
-- with id/submitterIdentifier/submitterName/caption/videoUrl), it
-- doesn't care which resource calls it. This runs server-side so the
-- webhook key never has to live in NUI-reachable client code.
local function log(...)
    print("[xonsight-lbphone]", ...)
end

RegisterNetEvent("xonsight-lbphone:submitEvidence", function(data)
    local src = source

    if not Config.AllowCapture then
        return
    end

    if not Config.SiteUrl or Config.SiteUrl == "" or Config.SiteUrl:find("YOUR_SITE_HOST") then
        log("Config.SiteUrl isn't configured - dropping evidence submission from player", src)
        TriggerClientEvent("xonsight-lbphone:submitResult", src, false, "Xon Sight isn't configured on this server")
        return
    end

    if not data or not data.videoUrl or data.videoUrl == "" then
        log("Dropped evidence submission from player", src, "- no videoUrl")
        TriggerClientEvent("xonsight-lbphone:submitResult", src, false, "No media was captured")
        return
    end

    local playerName = GetPlayerName(src) or ("Player " .. src)
    local identifier = GetPlayerIdentifierByType(src, "license") or ("source:" .. src)

    -- Xon Sight's documented `id` is "integer, unique per item - re-posting
    -- the same id updates it in place". There's no shared counter to pull
    -- from here, so this combines a timestamp with the player's server id -
    -- good enough to avoid collisions between captures, not meant to be
    -- stable/meaningful beyond that.
    local evidenceId = math.floor(os.time() * 1000 + src)

    local payload = json.encode({
        id = evidenceId,
        submitterIdentifier = identifier,
        submitterName = playerName,
        caption = (data.caption and data.caption ~= "") and data.caption or (playerName .. " - captured via LB Phone"),
        videoUrl = data.videoUrl,
        createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ") .. "",
    })

    local headers = { ["Content-Type"] = "application/json" }
    if Config.WebhookKey and Config.WebhookKey ~= "" then
        headers["X-XonSight-Key"] = Config.WebhookKey
    end

    PerformHttpRequest(Config.SiteUrl .. "/api/xonsight/evidence", function(statusCode, responseText)
        local ok = statusCode ~= nil and statusCode >= 200 and statusCode < 300
        TriggerClientEvent("xonsight-lbphone:submitResult", src, ok, ok and "Sent to Xon Sight" or ("Failed to submit (" .. tostring(statusCode) .. ")"))
        if not ok then
            log("Evidence submission failed for player", src, statusCode, responseText)
        end
    end, "POST", payload, headers)
end)
