-- Phones put down on a wireless charger (opslabs-towers Qi pad / stand). The phone item leaves the owner's inventory
-- and sits on the charger as a prop everyone sees (client/dock.lua). While docked the phone still counts as owned:
-- it rings, gets messages and charges, and its owner can use it standing beside it. Docks are kept in a resource
-- KVP so they survive disconnects and restarts; only picking the phone up gives the item back.

local CD = Config.Dock or {}
local KVP = 'opslabs-phone:docks'
local Docks = {}          -- fixture id -> { id, identifier, item, model, x, y, z, heading, src }
local byOwner = {}        -- identifier -> fixture id

local function save()
    local list = {}
    for _, d in pairs(Docks) do
        list[#list + 1] = { id = d.id, identifier = d.identifier, item = d.item, model = d.model, x = d.x, y = d.y, z = d.z, heading = d.heading }
    end
    SetResourceKvp(KVP, json.encode(list))
end

--- what clients see: position + who is online as the owner (server id), never identifiers
local function publish()
    local list = {}
    for id, d in pairs(Docks) do
        list[tostring(id)] = { id = id, model = d.model, x = d.x, y = d.y, z = d.z, heading = d.heading, owner = d.src, color = Config.Items[d.item] }
    end
    GlobalState['opsphone:docks'] = list
end

local function load()
    local raw = GetResourceKvpString(KVP)
    local ok, list = pcall(json.decode, raw or '[]')
    for _, d in ipairs(ok and type(list) == 'table' and list or {}) do
        if d.id and d.identifier and d.item then
            Docks[d.id] = d
            byOwner[d.identifier] = d.id
        end
    end
    publish()
end

local function notify(src, kind, text)
    TriggerClientEvent('ox_lib:notify', src, { type = kind, title = 'Phone', description = text })
end

--- the docked phone of an online player (also notes which server id the owner has now)
function DockedPhoneOf(src)
    if CD.Enabled == false then return nil end
    local identifier = FW.Identifier(src)
    local changed = false
    for _, d in pairs(Docks) do
        -- character switch: this server id now belongs to someone else
        if d.src == src and d.identifier ~= identifier then d.src = nil changed = true end
    end
    local id = identifier and byOwner[identifier]
    local d = id and Docks[id]
    if d and d.src ~= src then d.src = src changed = true end
    if changed then publish() end
    return d
end

local function towers() return GetResourceState('opslabs-towers') == 'started' end

local function near(src, x, y, z, reach)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return true end
    local p = GetEntityCoords(ped)
    if p.x == 0.0 and p.y == 0.0 then return true end          -- no OneSync: trust the client
    return #(p - vector3(x, y, z)) <= reach
end

RegisterNetEvent('opslabs-phone:dock', function(fixtureId)
    local src = source
    if CD.Enabled == false or not towers() then return end
    fixtureId = tonumber(fixtureId)
    local ok, f = pcall(function() return exports['opslabs-towers']:GetFixture(fixtureId) end)
    if not ok or not f or not (CD.Spots or {})[f.model] then return end
    if not near(src, f.x, f.y, f.z, (CD.PromptDistance or 1.6) + 1.5) then return end
    if Docks[f.id] then return notify(src, 'error', 'There is already a phone on that charger') end
    local identifier = FW.Identifier(src)
    if not identifier then return end
    if byOwner[identifier] then return notify(src, 'error', 'Your phone is already on a charger') end
    -- your own phone (not one you picked up), with its number kept for when it's taken back
    local item, metadata = OwnPhoneItem(src)
    if not item then return notify(src, 'error', "You don't have a phone") end
    if not FW.RemoveItem(src, item, 1, metadata and { phone_number = metadata.phone_number } or nil) then return end
    Docks[f.id] = { id = f.id, identifier = identifier, item = item, metadata = metadata, model = f.model, x = f.x, y = f.y, z = f.z, heading = f.heading, src = src }
    byOwner[identifier] = f.id
    save()
    publish()
    TriggerClientEvent('opslabs-phone:docked', src, true, f.live)
end)

RegisterNetEvent('opslabs-phone:undock', function(fixtureId)
    local src = source
    local d = Docks[tonumber(fixtureId) or -1]
    if not d then return end
    local identifier = FW.Identifier(src)
    if CD.OwnerOnly ~= false and d.identifier ~= identifier then return notify(src, 'error', "That isn't your phone") end
    if not near(src, d.x, d.y, d.z, (CD.PromptDistance or 1.6) + 1.5) then return end
    if not FW.AddItem(src, d.item, 1, d.metadata) then return notify(src, 'error', "You can't carry the phone") end
    Docks[d.id] = nil
    byOwner[d.identifier] = nil
    save()
    publish()
    TriggerClientEvent('opslabs-phone:docked', src, false)
    -- someone else took it: the owner's phone is gone from the dock
    if d.src and d.src ~= src then
        TriggerClientEvent('opslabs-phone:docked', d.src, false)
        notify(d.src, 'error', 'Someone took your phone off the charger')
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, d in pairs(Docks) do
        if d.src == src then d.src = nil publish() break end
    end
end)

if CD.Enabled ~= false then CreateThread(load) end
