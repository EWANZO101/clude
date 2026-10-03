-- Extension ladders: placed by players, seen by everyone, kept in memory only (a ladder is a
-- tool, not part of the network, so they're gone after a restart or when the owner leaves).

local CC = Config.Cabling
local Ladders, nextId = {}, 1

local function num(v) v = tonumber(v); return v and v == v and math.abs(v) < 100000 and v or nil end

local function ladderType(id)
    for _, t in ipairs(CC.Ladders or {}) do if t.id == id then return t end end
    return (CC.Ladders or {})[1] or { id = 'l7', maxExt = 3.0 }
end

local function canClimb(src)
    if not CC.ClimbJobs or IsTowerAdmin(src) then return true end
    local xPlayer = ESX.GetPlayerFromId(src)
    local job = xPlayer and xPlayer.getJob() and xPlayer.getJob().name
    for _, j in ipairs(CC.ClimbJobs) do if j == job then return true end end
    return false
end

local function near(src, x, y, z, dist)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(p - vector3(x, y, z)) <= dist
end

local function payload()
    local out = {}
    for _, l in pairs(Ladders) do out[#out + 1] = { id = l.id, type = l.type, x = l.x, y = l.y, z = l.z, heading = l.heading, ext = l.ext, owner = l.name } end
    return out
end

local function broadcast(target) TriggerClientEvent('opslabs-towers:ladders', target or -1, payload()) end

RegisterNetEvent('opslabs-towers:ladders:get', function() broadcast(source) end)

lib.callback.register('opslabs-towers:ladder:place', function(src, d)
    if type(d) ~= 'table' then return { error = 'bad request' } end
    if not canClimb(src) then return { error = 'You need ladder training for that' } end
    local x, y, z, h = num(d.x), num(d.y), num(d.z), num(d.heading)
    if not (x and y and z and h) then return { error = 'bad position' } end
    if not near(src, x, y, z, 8.0) then return { error = 'too far away' } end
    -- one player can't litter the map: oldest ladder goes back on the van
    local mine = {}
    for _, l in pairs(Ladders) do if l.owner == src then mine[#mine + 1] = l end end
    table.sort(mine, function(a, b) return a.id < b.id end)
    while #mine >= (CC.LadderMaxPerPlayer or 2) do
        Ladders[table.remove(mine, 1).id] = nil
    end
    local id = nextId
    nextId = nextId + 1
    local lt = ladderType(d.type)
    Ladders[id] = { id = id, type = lt.id, x = x, y = y, z = z, heading = h % 360, ext = math.max(0.0, math.min(lt.maxExt, num(d.ext) or 0.0)),
        owner = src, name = GetPlayerName(src) }
    broadcast()
    return { ok = true, id = id }
end)

lib.callback.register('opslabs-towers:ladder:extend', function(src, id, ext)
    local l = Ladders[tonumber(id)]
    if not l then return { error = 'That ladder is gone' } end
    if not near(src, l.x, l.y, l.z, 6.0) then return { error = 'too far away' } end
    l.ext = math.max(0.0, math.min(ladderType(l.type).maxExt, num(ext) or l.ext))
    broadcast()
    return { ok = true }
end)

lib.callback.register('opslabs-towers:ladder:remove', function(src, id)
    local l = Ladders[tonumber(id)]
    if not l then return { error = 'That ladder is gone' } end
    if not near(src, l.x, l.y, l.z, 6.0) then return { error = 'too far away' } end
    Ladders[l.id] = nil
    broadcast()
    return { ok = true }
end)

AddEventHandler('playerDropped', function()
    local src, changed = source, false
    for id, l in pairs(Ladders) do if l.owner == src then Ladders[id] = nil changed = true end end
    if changed then broadcast() end
end)
