-- Live location sharing (live tracking style).
-- The sharer's client reports its own position every few seconds while it has
-- active shares; the server relays it to the people it is shared with, who see
-- it live in Messages/Maps and as a blip on the in-game map.

local shares = {}   -- [id] = { id, owner, ownerNumber, ownerName, viewer (number), expires (0 = until stopped), x, y, z, h, updated }
local nextId = 0
local lastReport = {}

local function payload(s)
    return {
        id = s.id, number = s.ownerNumber, name = s.ownerName, viewer = s.viewer,
        x = s.x, y = s.y, z = s.z, h = s.h, expires = s.expires, updated = s.updated,
    }
end

local function ownerHasShares(src)
    for _, s in pairs(shares) do
        if s.owner == src then return true end
    end
    return false
end

local function setReporting(src)
    TriggerClientEvent('opslabs-phone:liveReporting', src, ownerHasShares(src))
end

local function sendToViewer(s, event, data)
    local target = GetSourceByNumber(s.viewer)
    if target then TriggerClientEvent(event, target, data) end
end

local function endShare(id)
    local s = shares[id]
    if not s then return end
    shares[id] = nil
    sendToViewer(s, 'opslabs-phone:liveLocationEnded', { id = id })
    if GetPlayerName(s.owner) then
        Push(s.owner, 'liveLocationEnded', { id = id })
        setReporting(s.owner)
    end
end

function EndLiveSharesFor(src)
    for id, s in pairs(shares) do
        if s.owner == src then endShare(id) end
    end
end

local function durationSeconds(minutes)
    minutes = tonumber(minutes) or 0
    for _, allowed in ipairs(Config.LiveLocation.Durations) do
        if allowed == minutes then return minutes * 60 end
    end
    return Config.LiveLocation.Durations[1] * 60
end

Register('startLiveLocation', function(src, phone, data)
    local to = NormalizeNumber(data.number)
    if to == '' or to == phone.number then return { error = 'Invalid number' } end

    local seconds = durationSeconds(data.minutes)
    local expires = seconds > 0 and (os.time() + seconds) or 0

    -- sharing again with the same person just extends the existing share
    local share
    for _, s in pairs(shares) do
        if s.owner == src and s.viewer == to then share = s break end
    end

    if share then
        share.expires = expires
    else
        nextId = nextId + 1
        local c = GetEntityCoords(GetPlayerPed(src))
        share = {
            id = nextId, owner = src, ownerNumber = phone.number, ownerName = phone.name, viewer = to,
            expires = expires, updated = os.time(),
        }
        if c.x ~= 0.0 or c.y ~= 0.0 then share.x, share.y, share.z = c.x, c.y, c.z end
        shares[share.id] = share
        SendMessage(phone.number, to, '', { type = 'live', shareId = share.id }, phone.name)
    end

    setReporting(src)
    if share.x then sendToViewer(share, 'opslabs-phone:liveLocation', payload(share)) end
    return { id = share.id, expires = expires, number = to }
end)

Register('stopLiveLocation', function(src, _, data)
    local s = shares[tonumber(data.id)]
    if not s or s.owner ~= src then return false end
    endShare(s.id)
    return true
end)

Register('stopAllLiveLocation', function(src)
    EndLiveSharesFor(src)
    return true
end)

Register('getLiveShares', function(src, phone)
    local incoming, outgoing = {}, {}
    for _, s in pairs(shares) do
        if s.owner == src then
            outgoing[#outgoing + 1] = { id = s.id, number = s.viewer, expires = s.expires }
        elseif s.viewer == phone.number then
            incoming[#incoming + 1] = payload(s)
        end
    end
    return { incoming = incoming, outgoing = outgoing, now = os.time() }
end)

-- position reports from the sharer's own client
RegisterNetEvent('opslabs-phone:livePos', function(x, y, z, h)
    local src = source
    x, y, z, h = tonumber(x), tonumber(y), tonumber(z), tonumber(h) or 0.0
    if not (x and y and z) then return end
    local now = GetGameTimer()
    if lastReport[src] and now - lastReport[src] < 900 then return end
    lastReport[src] = now

    local t = os.time()
    for _, s in pairs(shares) do
        if s.owner == src then
            s.x, s.y, s.z, s.h, s.updated = x, y, z, h, t
            sendToViewer(s, 'opslabs-phone:liveLocation', payload(s))
        end
    end
end)

AddEventHandler('playerDropped', function()
    lastReport[source] = nil
end)

-- expiry
CreateThread(function()
    while true do
        Wait(5000)
        local t = os.time()
        for id, s in pairs(shares) do
            if (s.expires > 0 and t >= s.expires) or not GetPlayerName(s.owner) then
                endShare(id)
            end
        end
    end
end)
