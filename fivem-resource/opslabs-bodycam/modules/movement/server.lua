-- Lets the 17Movement app submit evidence straight from its own camera, independent of the bodycam
-- recording. The webhook POST itself lives in modules/evidence.lua, shared with the LB Phone and GKSPHONE
-- modules.

local cfg = (ServerConfig.Modules or {}).Movement or {}

if cfg.Enabled ~= true then return end

RegisterNetEvent("opslabs-bodycam:movement:submitEvidence", function(data)
    local src = source

    if cfg.AllowCapture == false then
        return
    end

    Modules.SubmitEvidenceFromPhone(src, data, "movement", "opslabs-bodycam:movement:submitResult")
end)
