-- Framework bridge: who the player is (name, callsign, job, grade, duty) and what they carry, for the access check and
-- the evidence captions. Qbox, QBCore, ESX Legacy (1.9+), ox_core, ND Core v2 — or standalone (player name, ACE).
-- Other scripts can set a callsign on any framework: Player(src).state:set('callsign', '1-ADAM-12', true)

Bridge = { name = 'standalone' }

local function started(r) return GetResourceState(r) == 'started' end

local function pick()
    local want = GetConvar('opsbodycam_framework', '')
    if want == '' then want = Config.Framework or 'auto' end
    if want ~= 'auto' then return want end
    if started('qbx_core') then return 'qbx' end     -- before qb-core: Qbox also answers to qb-core
    if started('qb-core') then return 'qb' end
    if started('es_extended') then return 'esx' end
    if started('ox_core') then return 'ox' end
    if started('ND_Core') then return 'nd' end
    return 'standalone'
end

local A = {}   -- adapter: info(src) → { identifier, name, job, jobLabel, grade, gradeLabel, onDuty, callsign }, hasItem(src, item)

local function qbInfo(p)
    if not p or not p.PlayerData then return nil end
    local d = p.PlayerData
    local j, ci, md = d.job or {}, d.charinfo or {}, d.metadata or {}
    local cs = md.callsign
    if cs == 'NO CALLSIGN' or cs == '' then cs = nil end
    return {
        identifier = d.citizenid, name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', ''),
        job = j.name, jobLabel = j.label, grade = tonumber(j.grade and j.grade.level) or 0, gradeLabel = j.grade and j.grade.name,
        onDuty = j.onduty, callsign = cs,
    }
end

local adapters = {
    esx = function()
        local ESX = exports.es_extended:getSharedObject()
        return {
            label = 'ESX Legacy',
            info = function(src)
                local x = ESX.GetPlayerFromId(src)
                if not x then return nil end
                local j = (x.getJob and x.getJob()) or x.job or {}
                return {
                    identifier = x.identifier, name = x.getName and x.getName() or nil,
                    job = j.name, jobLabel = j.label, grade = tonumber(j.grade) or 0, gradeLabel = j.grade_label,
                    onDuty = j.onDuty,       -- ESX 1.10+; nil on older builds (counts as on duty)
                }
            end,
            usable = function(item, fn) ESX.RegisterUsableItem(item, function(src) fn(src) end) end,
            hasItem = function(src, item)
                local x = ESX.GetPlayerFromId(src)
                local i = x and x.getInventoryItem and x.getInventoryItem(item)
                return i ~= nil and (tonumber(i.count or i.amount) or 0) > 0
            end,
        }
    end,
    qb = function()
        local QB = exports['qb-core']:GetCoreObject()
        return {
            label = 'QBCore',
            info = function(src) return qbInfo(QB.Functions.GetPlayer(src)) end,
            usable = function(item, fn) QB.Functions.CreateUseableItem(item, function(src) fn(src) end) end,
            hasItem = function(src, item)
                local p = QB.Functions.GetPlayer(src)
                local i = p and p.Functions.GetItemByName(item)
                return i ~= nil and (tonumber(i.amount or i.count) or 0) > 0
            end,
        }
    end,
    qbx = function()
        return {
            label = 'Qbox',
            info = function(src) return qbInfo(exports.qbx_core:GetPlayer(src)) end,
            usable = function(item, fn) exports.qbx_core:CreateUseableItem(item, function(src) fn(src) end) end,
        }
    end,
    ox = function()
        local ox = exports.ox_core
        local call = function(src, m, ...) return ox:CallPlayer(src, m, ...) end
        return {
            label = 'ox_core',
            info = function(src)
                local p = ox:GetPlayer(src)
                if not p or not p.charId then return nil end
                local g = call(src, 'get', 'activeGroup')
                local group = g and GlobalState['group.' .. g] or {}
                local grade = g and tonumber(call(src, 'getGroup', g)) or 0
                return {
                    identifier = tostring(p.charId), name = ((call(src, 'get', 'firstName') or '') .. ' ' .. (call(src, 'get', 'lastName') or '')),
                    job = g, jobLabel = group.label or g, grade = grade, gradeLabel = (group.grades or {})[grade],
                }
            end,
        }
    end,
    nd = function()
        return {
            label = 'ND Core',
            info = function(src)
                local p = exports.ND_Core:getPlayer(src)
                if not p then return nil end
                local j = p.jobInfo or {}
                return {
                    identifier = tostring(p.id), name = ((p.firstname or '') .. ' ' .. (p.lastname or '')),
                    job = p.job, jobLabel = j.label or p.job, grade = tonumber(j.rank) or 0, gradeLabel = j.rankName,
                }
            end,
        }
    end,
}

--- license:… identifier: the same person on every framework
local function license(src)
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, 8) == 'license:' then return id end
    end
    return GetPlayerIdentifier(src, 0) or ('player:' .. src)
end

function Bridge.Init()
    local name = pick()
    if adapters[name] then
        local ok, a = pcall(adapters[name])
        if ok and a then
            A, Bridge.name = a, name
            print(('[opslabs-bodycam] Framework: %s'):format(a.label))
            return
        end
        print(('^3[opslabs-bodycam] %s found but could not be used (%s) — running standalone^7'):format(name, tostring(a)))
    end
    A, Bridge.name = {}, 'standalone'
    print('[opslabs-bodycam] Framework: none (standalone — access by ACE, item or everyone)')
end

--- everything known about the player; never nil
function Bridge.Player(src)
    local info = A.info and select(2, pcall(A.info, src)) or nil
    if type(info) ~= 'table' then info = {} end
    info.license = license(src)
    info.identifier = info.identifier or info.license
    if not info.name or info.name:match('^%s*$') then info.name = GetPlayerName(src) or ('Player ' .. src) end
    local st = Player(src).state
    info.callsign = st.callsign or info.callsign
    return info
end

function Bridge.HasItem(src, item)
    if not item or item == '' then return false end
    if started('ox_inventory') then
        local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
        return ok and (tonumber(n) or 0) > 0
    end
    if A.hasItem then
        local ok, r = pcall(A.hasItem, src, item)
        return ok and r == true
    end
    return false
end

--- make an item usable through the framework; false when it has no usable items (ox_core / ND / standalone: use the
--- ox_inventory item export instead, README)
function Bridge.UsableItem(item, fn)
    if not A.usable or not item or item == '' then return false end
    local ok, err = pcall(A.usable, item, fn)
    if not ok then print(('^3[opslabs-bodycam] could not make %s usable: %s^7'):format(item, err)) end
    return ok
end

--- is this player issued a bodycam at all (ace/job/item), regardless of whether the vest is currently worn?
--- (allowed, reason) — this is what gates putting the vest ON (server/vest.lua), so it must not itself require
--- the vest to already be on.
function Bridge.Eligible(src)
    local acc = Config.Access or {}

    if acc.Ace and IsPlayerAceAllowed(src, acc.Ace) then return true end
    local mode = acc.Mode or 'job'
    if mode == 'everyone' then return true end
    if mode == 'ace' then return false, 'not_allowed' end

    local function job()
        local p = Bridge.Player(src)
        local min = p.job and (acc.Jobs or {})[p.job]
        if not min then return false, 'wrong_job' end
        if (p.grade or 0) < min then return false, 'grade' end
        if acc.OnDutyOnly and p.onDuty == false then return false, 'off_duty' end
        return true
    end
    local function item() if Bridge.HasItem(src, acc.Item) then return true end return false, 'no_item' end

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

--- is this player issued a bodycam right now AND actually wearing it? (allowed, reason) — the full gate for
--- starting/continuing a recording.
function Bridge.CanUse(src)
    local ok, why = Bridge.Eligible(src)
    if not ok then return ok, why end

    -- Config.Vest.RequiredToRecord: the vest (item or /vest command) has to physically be on, not just carried/
    -- issued, before the bodycam will start at all. Player(src).state.opsVest is set by
    -- opslabs-bodycam:vestState (server/vest.lua) whenever the vest/shirt-cam actually goes on or off.
    if (Config.Vest or {}).RequiredToRecord then
        local st = Player(src).state
        if st.opsVest ~= true then return false, 'vest_off' end
    end

    return true
end
