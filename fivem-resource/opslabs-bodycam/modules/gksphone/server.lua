-- Lets the GKSPHONE app submit evidence straight from its own camera, independent of the bodycam recording.
-- The webhook POST itself lives in modules/evidence.lua, shared with the LB Phone and 17Movement modules.

local cfg = (ServerConfig.Modules or {}).GksPhone or {}

if cfg.Enabled ~= true then return end

RegisterNetEvent("opslabs-bodycam:gksphone:submitEvidence", function(data)
    local src = source

    if cfg.AllowCapture == false then
        return
    end

    Modules.SubmitEvidenceFromPhone(src, data, "gksphone", "opslabs-bodycam:gksphone:submitResult")
end)
