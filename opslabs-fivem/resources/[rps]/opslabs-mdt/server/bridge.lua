-- Framework access through rps_lib (ESX / QBCore / QBox / standalone) - same shared lib opslabs-towers and
-- opslabs-pos use, so nothing framework-specific lives in this resource at all.

FW = {}
local lib_ = exports.rps_lib   -- rps_lib's functions are exports, not shared globals - every call goes through this

function FW.Player(src) return lib_:GetPlayerData(tonumber(src)) end
function FW.Identifier(src) local p = FW.Player(src) return p and p.identifier end
function FW.Name(src) local p = FW.Player(src) return (p and p.name) or GetPlayerName(src) or tostring(src) end
function FW.Job(src) local p = FW.Player(src) return p and p.job and p.job.name end
function FW.JobLabel(src) local p = FW.Player(src) return p and p.job and p.job.label end
function FW.JobGrade(src) local p = FW.Player(src) return p and p.job and p.job.grade and p.job.grade.level or 0 end

function FW.HasItem(src, item, count) return lib_:HasItem(src, item, count or 1) end
function FW.AddItem(src, item, count) return lib_:AddItem(src, item, count or 1) end
function FW.RemoveItem(src, item, count) return lib_:RemoveItem(src, item, count or 1) end

--- may this player install / carry an MDT at all? rps_lib has no duty concept to check here on purpose -
--- actually being "on duty" for the MDT means being logged in as an active unit in the CAD itself
--- (Cad.ActiveOfficer, checked when the laptop is opened, not here).
function FW.Eligible(src)
    local acc = Config.Access or {}
    if acc.Ace and IsPlayerAceAllowed(src, acc.Ace) then return true end
    local mode = acc.Mode or 'job'
    if mode == 'everyone' then return true end
    if mode == 'ace' then return false, 'not_allowed' end

    local function job()
        local min = (acc.Jobs or {})[FW.Job(src)]
        if not min then return false, 'wrong_job' end
        if FW.JobGrade(src) < min then return false, 'grade' end
        return true
    end
    local function item() if FW.HasItem(src, acc.Item) then return true end return false, 'no_item' end

    if mode == 'job' then return job() end
    if mode == 'item' then return item() end
    if mode == 'job_and_item' then
        local ok, why = job()
        if not ok then return false, why end
        return item()
    end
    if mode == 'job_or_item' then
        if job() then return true end
        return item()
    end
    return false, 'not_allowed'
end
