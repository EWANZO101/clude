-- Shared evidence-submission webhook used by every phone app module (LB Phone, GKSPHONE, 17Movement - and
-- Sky Phone through its lb-phone/17mov_Phone compatibility aliases). Each module's server.lua just forwards
-- its own event into Modules.SubmitEvidenceFromPhone(); this is where the actual POST to Xon Sight happens
-- (keeps the webhook key out of NUI-reachable client code). Was duplicated per-module before; one copy now.

function Modules.SubmitEvidenceFromPhone(src, data, moduleTag, resultEvent)
    local function log(...)
        print("[opslabs-bodycam:" .. moduleTag .. "]", ...)
    end

    local siteUrl = Modules.SiteUrl()
    if siteUrl == "" then
        log("ServerConfig.XonSight.Url isn't configured (config_server.lua) - dropping evidence submission from player", src)
        TriggerClientEvent(resultEvent, src, false, "Xon Sight isn't configured on this server")
        return
    end

    if not data or not data.videoUrl or data.videoUrl == "" then
        log("Dropped evidence submission from player", src, "- no videoUrl")
        TriggerClientEvent(resultEvent, src, false, "No media was captured")
        return
    end

    local playerName = GetPlayerName(src) or ("Player " .. src)
    local identifier = GetPlayerIdentifierByType(src, "license") or ("source:" .. src)

    -- Xon Sight's `id` is "integer, unique per item - re-posting the same id updates it in place". No shared
    -- counter here, so a timestamp plus the player's server id - enough to avoid collisions between captures.
    local evidenceId = math.floor(os.time() * 1000 + src)

    local payload = json.encode({
        id = evidenceId,
        submitterIdentifier = identifier,
        submitterName = playerName,
        caption = (data.caption and data.caption ~= "") and data.caption or (playerName .. " - captured via " .. moduleTag),
        videoUrl = data.videoUrl,
        createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ") .. "",
    })

    PerformHttpRequest(siteUrl .. "/api/xonsight/evidence", function(statusCode, responseText)
        local ok = statusCode ~= nil and statusCode >= 200 and statusCode < 300
        TriggerClientEvent(resultEvent, src, ok, ok and "Sent to Xon Sight" or ("Failed to submit (" .. tostring(statusCode) .. ")"))
        if not ok then
            log("Evidence submission failed for player", src, statusCode, responseText)
        end
    end, "POST", payload, Modules.Headers())
end
