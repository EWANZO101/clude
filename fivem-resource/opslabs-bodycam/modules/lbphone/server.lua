-- Lets the LB Phone app (and Sky Phone's lb-phone alias) submit evidence straight from the phone's own
-- camera, independent of the bodycam recording. The webhook POST itself lives in modules/evidence.lua,
-- shared with the GKSPHONE and 17Movement modules.

local cfg = (ServerConfig.Modules or {}).LbPhone or {}

if cfg.Enabled ~= true then return end

RegisterNetEvent("opslabs-bodycam:lbphone:submitEvidence", function(data)
    local src = source

    if cfg.AllowCapture == false then
        return
    end

    Modules.SubmitEvidenceFromPhone(src, data, "lbphone", "opslabs-bodycam:lbphone:submitResult")
end)
