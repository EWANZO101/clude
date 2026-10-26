-- Third eye (Config.Target): hold the target key (ALT, by default) and look at OPS kit to interact with it,
-- the same way you'd look at a ped or vehicle - as well as placing/installing kit from /towers, which this
-- never touches. Works with tgiann-target or ox_target (same API, picked automatically); with neither running,
-- every system's old [E]/[G]/[H] prompts stay exactly as they were.
--   This file: the bottom of every pole - climb, kit at the base, the Line Tool, live pole data, fault finder,
--   recloser control, fault repair and ladders - plus the generic TargetAddModel / TargetAddLocalEntity
--   helpers every other target-aware file (doors.lua, access.lua, …) calls instead of touching tgiann-target /
--   ox_target directly.

local CT = Config.Target or {}
local CC = Config.Cabling or {}
local CG = Config.Grid or {}

local function api()
    if GetResourceState('tgiann-target') == 'started' then return exports['tgiann-target'] end
    if GetResourceState('ox_target') == 'started' then return exports.ox_target end
    return nil
end

--- is the third eye doing the bottom of poles? (poles.lua / grid.lua hide their [E] prompts then)
function TargetOn() return CT.Enabled ~= false and api() ~= nil end

---------------------------------------------------------------------------
-- generic helpers for other client files (doors.lua, cctv.lua, access.lua, …): one place that knows which
-- target resource is running and how to talk to it, so the rest of the codebase just calls these four and
-- TargetOn() above, the same way it already calls PoleEquipMenu / ShowPoleData / etc. Every call is wrapped in
-- pcall - a target resource stopping mid-session (onClientResourceStart/Stop already clears our own
-- registrations below) must never take a caller's thread down with it.
---------------------------------------------------------------------------
function TargetAddModel(models, options)
    local t = api()
    if not t then return false end
    pcall(function() t:addModel(models, options) end)
    return true
end

function TargetRemoveModel(models, options)
    local t = api()
    if t then pcall(function() t:removeModel(models, options) end) end
end

--- a specific (locally-spawned, not networked) entity - a door/gate leaf, a camera that doesn't warrant a
--- whole-model registration, etc. ox_target / tgiann-target self-clean once the entity no longer exists, but
--- callers should still pair this with TargetRemoveLocalEntity when they delete the entity themselves.
function TargetAddLocalEntity(entity, options)
    local t = api()
    if not t or not entity or entity == 0 then return false end
    pcall(function() t:addLocalEntity(entity, options) end)
    return true
end

function TargetRemoveLocalEntity(entity)
    local t = api()
    if t and entity and entity ~= 0 then pcall(function() t:removeLocalEntity(entity) end) end
end

local function fixtures() return CablingFixtures and CablingFixtures() or {} end
local function isPowerPole(m) return m and m:find('^opslabs_power_pole') ~= nil end

--- the pole (as AllPoles() lists it) behind a targeted entity
local function poleOf(entity)
    if not entity or entity == 0 or not AllPoles then return nil end
    local c = GetEntityCoords(entity)
    local best, bd
    for _, p in ipairs(AllPoles()) do
        if not p.house and not p.anchor then
            if p.ent == entity then return p end
            local d = #(vector2(p.x, p.y) - vector2(c.x, c.y))
            if d < 0.8 and (not bd or d < bd) then best, bd = p, d end
        end
    end
    return best
end

--- standing at the bottom of it, not up it, on foot
local function atBase(entity)
    if PoleClimb or (IsClimbingPole and IsClimbingPole()) or IsPedInAnyVehicle(PlayerPedId(), false) then return nil end
    local p = poleOf(entity)
    if not p then return nil end
    local me = GetEntityCoords(PlayerPedId())
    if math.abs(me.z - p.z) > 3.0 then return nil end
    return p
end

local function recloserOn(p)
    for _, f in pairs(fixtures()) do
        if f.model == CG.Recloser and #(vector2(f.x, f.y) - vector2(p.x, p.y)) <= 1.2 then return f end
    end
end

local function angleTo(p)
    local me = GetEntityCoords(PlayerPedId())
    return math.atan(me.y - p.y, me.x - p.x)
end

local function options()
    local dist = CT.Distance or 2.5
    return {
        { name = 'ops_pole_climb', label = 'Climb the pole', icon = 'fa-solid fa-person-arrow-up-from-line', distance = dist,
            canInteract = function(entity)
                local p = atBase(entity)
                return p ~= nil and not (CC.NoClimb and CC.NoClimb[p.model])
            end,
            onSelect = function(data) local p = atBase(data.entity) if p and TryClimbPole then TryClimbPole(p) end end },
        { name = 'ops_pole_kit', label = 'Pole kit at the base', icon = 'fa-solid fa-screwdriver-wrench', distance = dist,
            canInteract = function(entity) return atBase(entity) ~= nil and PoleEquipMenu ~= nil end,
            onSelect = function(data) local p = atBase(data.entity) if p then PoleEquipMenu(p, angleTo(p), 0.0, function() end) end end },
        { name = 'ops_pole_data', label = 'Pole live data (LineSense)', icon = 'fa-solid fa-gauge-high', distance = dist,
            canInteract = function(entity) local p = atBase(entity) return p ~= nil and not p.world and isPowerPole(p.model) and ShowPoleData ~= nil end,
            onSelect = function(data) local p = atBase(data.entity) if p then ShowPoleData(p.id) end end },
        { name = 'ops_pole_linetool', label = 'Line Tool on this pole', icon = 'fa-solid fa-person-digging', distance = dist,
            canInteract = function(entity) local p = atBase(entity) return p ~= nil and not p.world and isPowerPole(p.model) and LineToolInspect ~= nil end,
            onSelect = function(data)
                local p = atBase(data.entity)
                if not p then return end
                if not lib.callback.await('opslabs-towers:pline:can', false) then return lib.notify({ type = 'error', description = 'Only San Andreas Power & Light crews and engineers carry the Line Tool' }) end
                LineToolInspect(p.id)
            end },
        { name = 'ops_pole_recloser', label = 'Recloser control', icon = 'fa-solid fa-toggle-on', distance = dist,
            canInteract = function(entity) local p = atBase(entity) return p ~= nil and isPowerPole(p.model) and GridCrew and GridCrew() and recloserOn(p) ~= nil end,
            onSelect = function(data) local p = atBase(data.entity) local r = p and recloserOn(p) if r and GridOpenPanel then GridOpenPanel(r) end end },
        { name = 'ops_pole_faultfinder', label = 'Power fault finder', icon = 'fa-solid fa-stethoscope', distance = dist,
            canInteract = function(entity) local p = atBase(entity) return p ~= nil and isPowerPole(p.model) and PowerFaultFinder ~= nil end,
            onSelect = function() PowerFaultFinder() end },
        { name = 'ops_pole_repair', label = 'Repair the fault here', icon = 'fa-solid fa-wrench', distance = dist,
            canInteract = function(entity) return atBase(entity) ~= nil and FaultAtHand ~= nil and FaultAtHand() end,
            onSelect = function() ExecuteCommand('opsrepair') end },
        { name = 'ops_pole_ladder', label = 'Place a ladder', icon = 'fa-solid fa-stairs', distance = dist,
            canInteract = function(entity) return atBase(entity) ~= nil and PlaceLadder ~= nil and not NearLadder end,
            onSelect = function() PlaceLadder() end },
    }
end

local registered = nil
local function models()
    local list, seen = {}, {}
    local function add(m) if m and not seen[m] then seen[m] = true list[#list + 1] = m end end
    for m in pairs(CC.PoleHeights or {}) do add(m) end
    for _, m in ipairs(CC.WorldPoles or {}) do add(m) end
    return list
end

local function register()
    local t = api()
    if not t or CT.Enabled == false or registered then return end
    local ok, e = pcall(function() t:addModel(models(), options()) end)
    if ok then registered = t else print('^3[opslabs-towers] third eye: could not add pole options: ' .. tostring(e) .. '^7') end
end

CreateThread(function() Wait(1500) register() end)
AddEventHandler('onClientResourceStart', function(res) if res == 'tgiann-target' or res == 'ox_target' then registered = nil SetTimeout(1000, register) end end)
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not registered then return end
    local names = {}
    for _, o in ipairs(options()) do names[#names + 1] = o.name end
    pcall(function() registered:removeModel(models(), names) end)
end)
