-- World cleanup (Config.WorldCleanup): hide GTA's fuel pumps, power / phone poles and traffic lights around the player.
-- Map props are hidden with model hides around the player, re-applied as they move; switching a group off (live, from
-- OPS Hub or the Developer app) brings those props back.

local hidden = {}           -- hash -> true (currently hidden)
local centres = {}          -- places a hide was applied (to undo it)
local radius = 400.0
local last = nil

local function wanted()
    local W = Config.WorldCleanup or {}
    local out = {}
    if W.Enabled == false then return out end
    local function add(list) for _, m in ipairs(list or {}) do if type(m) == 'string' and m ~= '' and not m:find('^opslabs_') then out[joaat(m)] = true end end end
    local M = W.Models or {}
    if W.GasStations ~= false then add(M.GasStations) end
    if W.Poles ~= false then add(M.Poles) end
    if W.TrafficLights ~= false then add(M.TrafficLights) end
    add(W.Extra)
    return out
end

local function hideAt(p, list)
    for h in pairs(list) do CreateModelHide(p.x, p.y, p.z, radius, h, true) end
end

local function unhide(list)
    for _, c in ipairs(centres) do
        for h in pairs(list) do RemoveModelHide(c.x, c.y, c.z, c.r, h, false) end
    end
end

local function refresh()
    local want = wanted()
    radius = math.max(100.0, math.min(1500.0, tonumber((Config.WorldCleanup or {}).Radius) or 400.0))
    local gone = {}
    for h in pairs(hidden) do if not want[h] then gone[h] = true end end
    if next(gone) then unhide(gone) end
    hidden = want
    last = nil                                  -- re-apply around the player now
    if not next(want) then centres = {} end
end

CreateThread(function()
    Wait(2000)
    refresh()
    while true do
        local p = GetEntityCoords(PlayerPedId())
        if next(hidden) and (not last or #(p - last) > radius * 0.35) then
            last = p
            hideAt(p, hidden)
            centres[#centres + 1] = { x = p.x, y = p.y, z = p.z, r = radius }
            if #centres > 400 then table.remove(centres, 1) end
        end
        Wait(1000)
    end
end)

AddEventHandler('opslabs:configChanged', function(res) if res == GetCurrentResourceName() then refresh() end end)
AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then unhide(hidden) end end)
