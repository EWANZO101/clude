-- Laptops: OPS OS on a desk (opslabs-towers places them and owns the cabling).
-- While a player sits at a laptop their online actions go over its Ethernet port
-- instead of the phone's signal / Wi-Fi: no plan or data used, and nothing works
-- unless a CAT6 cable connects the laptop to a router with an uplink (or a live ONT).

Laptop = {}
local sessions = {}            -- src -> fixture id
local TOWERS = 'opslabs-towers'
local MAX_DIST = 4.0

--- what opslabs-towers says about the laptop's Ethernet port (nil = no such laptop / towers stopped)
local function netOf(id)
    if GetResourceState(TOWERS) ~= 'started' then return nil end
    local ok, net = pcall(function() return exports[TOWERS]:GetLaptopNet(id) end)
    return ok and type(net) == 'table' and net or nil
end

local function near(src, net)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not net.x then return false end
    local p = GetEntityCoords(ped)
    return #(p - vector3(net.x, net.y, net.z)) <= MAX_DIST
end

local ended = {}             -- src -> why the last session ended ('battery')

--- the laptop is (or isn't) in use: its battery drains while someone works on it (opslabs-towers server/mains.lua)
local function inUse(id, on)
    if GetResourceState(TOWERS) ~= 'started' then return end
    pcall(function() exports[TOWERS]:SetLaptopInUse(id, on) end)
end

local function endSession(src, why)
    local id = sessions[src]
    if not id then return end
    sessions[src] = nil
    ended[src] = why
    local still = false
    for _, other in pairs(sessions) do if other == id then still = true end end
    if not still then inUse(id, false) end
end

--- the laptop session for this player, or nil (dropped when they walked away or the battery died)
function Laptop.Session(src)
    local id = sessions[src]
    if not id then return nil end
    local net = netOf(id)
    if not net or not near(src, net) then endSession(src) return nil end
    if net.dead then endSession(src, 'battery') return nil end
    return id, net
end

--- coverage as Carrier sees it while at a laptop: Ethernet up = like Wi-Fi, down = nothing
function Laptop.Coverage(src)
    local id, net = Laptop.Session(src)
    if not id then return nil end
    return { laptop = true, cell = 0, wifi = net.internet and { id = -id, ssid = 'Ethernet', bars = 4 } or nil }
end

-- requests a laptop makes on its own (not over the internet)
local LOCAL_RPCS = { laptopNet = true, saveSettings = true }

--- at a laptop whose Ethernet has no internet: refuse everything that would go online
function Laptop.Offline(src, name)
    if not sessions[src] or LOCAL_RPCS[name] then return false end
    local id, net = Laptop.Session(src)
    return id ~= nil and not net.internet
end

local function public(net)
    if not net then return nil end
    net.x, net.y, net.z = nil, nil, nil
    return net
end

lib.callback.register('opslabs-phone:laptopOpen', function(src, id)
    id = tonumber(id)
    local net = id and netOf(id)
    if not net then return { error = 'not_found' } end
    if not near(src, net) then return { error = 'too_far' } end
    if not GetPhone(src) then return { error = 'no_profile' } end
    if net.dead then return { error = 'battery' } end
    sessions[src] = id
    ended[src] = nil
    inUse(id, true)
    return { ok = true, net = public(net) }
end)

lib.callback.register('opslabs-phone:laptopClose', function(src)
    endSession(src)
    return true
end)

-- the desktop polls this for the Ethernet icon and the Network window
Register('laptopNet', function(src)
    local id, net = Laptop.Session(src)
    if not id then return { closed = true, reason = ended[src] } end
    return public(net)
end)

AddEventHandler('playerDropped', function() endSession(source) ended[source] = nil end)
