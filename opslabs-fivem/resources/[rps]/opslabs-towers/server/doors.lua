-- Doors and gates on placed buildings / gate frames (layouts in Config.Buildings).
-- State per fixture + door index: open, locked, PIN. PINs are stored hashed here and never sent to players.
-- Building doors: E opens / closes; locked doors need the PIN (which unlocks them).
-- Gates & rising bollards: open by themselves when someone comes close, close again when they've gone.
-- A locked gate stays shut until someone enters the PIN at the keypad — that lets them through once.

local B = Config.Buildings or {}
local State = {}            -- [fid][idx] = { open, locked, pin, pass, closeAt }
local Fails = {}            -- [src] = { n, untilT }

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_doors (
        fixture_id INT NOT NULL, door INT NOT NULL, locked TINYINT NOT NULL DEFAULT 0, pin VARCHAR(16) NULL,
        PRIMARY KEY (fixture_id, door)) ]])
    for _, r in ipairs(MySQL.query.await('SELECT fixture_id, door, locked, pin FROM opslabs_towers_doors') or {}) do
        State[r.fixture_id] = State[r.fixture_id] or {}
        State[r.fixture_id][r.door] = { open = false, locked = r.locked == 1, pin = r.pin }
    end
end)

local function now() return os.time() end

local function layout(fid)
    local f = Cabling.fixtures[fid]
    return f and B[f.model], f
end

local function st(fid, idx)
    State[fid] = State[fid] or {}
    State[fid][idx] = State[fid][idx] or { open = false, locked = false }
    return State[fid][idx]
end

local function hashPin(fid, pin)
    return tostring(GetHashKey(('opslabs:%d:%s'):format(fid, pin)))
end

local function validPin(pin)
    pin = tostring(pin or '')
    return pin:match('^%d%d%d%d%d?%d?$') and pin or nil
end

local function persist(fid, idx)
    local s = st(fid, idx)
    MySQL.query('INSERT INTO opslabs_towers_doors (fixture_id, door, locked, pin) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE locked = VALUES(locked), pin = VALUES(pin)',
        { fid, idx, s.locked and 1 or 0, s.pin })
end

local function public(s) return { open = s.open, locked = s.locked, pin = s.pin ~= nil } end

local function broadcast(fid, idx)
    TriggerClientEvent('opslabs-towers:door', -1, fid, idx, public(st(fid, idx)))
end

--- world position of a door (middle of its first leaf), for distance checks
local function doorPos(fid, idx)
    local L, f = layout(fid)
    local d = L and L.doors and L.doors[idx]
    if not d then return nil end
    local lf = (d.leaves or { d })[1]
    local h = math.rad(f.heading or 0.0)
    local lh = math.rad((f.heading or 0.0) + (lf.h or 0))
    local lx, ly = lf.hinge[1], lf.hinge[2]
    local x = f.x + lx * math.cos(h) - ly * math.sin(h) + math.cos(lh) * (lf.w or 1) / 2
    local y = f.y + lx * math.sin(h) + ly * math.cos(h) + math.sin(lh) * (lf.w or 1) / 2
    return vector3(x, y, f.z + 1.0), d
end

local function nearDoor(src, fid, idx, extra)
    local p, d = doorPos(fid, idx)
    if not p then return false end
    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    return #(GetEntityCoords(ped) - p) < (extra or 4.0) + (d.auto or 0), d
end

local function failed(src)
    local f = Fails[src] or { n = 0 }
    f.n = f.n + 1
    if f.n >= 5 then f.untilT, f.n = now() + 30, 0 end
    Fails[src] = f
end

local function lockedOut(src)
    local f = Fails[src]
    return f and f.untilT and f.untilT > now()
end

lib.callback.register('opslabs-towers:door:states', function()
    local out = {}
    for fid, doors in pairs(State) do
        if Cabling.fixtures[fid] then
            out[fid] = {}
            for idx, s in pairs(doors) do out[fid][idx] = public(s) end
        end
    end
    return out
end)

--- E on a door / gate: open or close it (when it isn't locked)
lib.callback.register('opslabs-towers:door:use', function(src, fid, idx)
    fid, idx = tonumber(fid), tonumber(idx)
    local ok, d = nearDoor(src, fid, idx)
    if not ok then return { error = 'Too far away' } end
    local s = st(fid, idx)
    if s.locked and not (s.pass and s.pass > now()) and not s.open then return { error = 'locked' } end
    s.open = not s.open
    if d.auto then s.closeAt = now() + 8 end
    broadcast(fid, idx)
    return { ok = true, open = s.open }
end)

--- keypad: enter the PIN. Doors unlock (and open); gates let you through once and stay locked
lib.callback.register('opslabs-towers:door:unlock', function(src, fid, idx, pin, keep)
    fid, idx = tonumber(fid), tonumber(idx)
    local ok, d = nearDoor(src, fid, idx)
    if not ok then return { error = 'Too far away' } end
    if lockedOut(src) then return { error = 'Keypad locked out — try again in 30 seconds' } end
    local s = st(fid, idx)
    pin = validPin(pin)
    if not s.pin then return { error = 'No PIN has been set on this keypad' } end
    if not pin or hashPin(fid, pin) ~= s.pin then
        failed(src)
        return { error = 'Wrong PIN' }
    end
    Fails[src] = nil
    if d.auto and not keep then
        s.pass, s.open, s.closeAt = now() + 20, true, now() + 10
    elseif d.auto then
        s.locked, s.open, s.closeAt = false, true, now() + 10
        persist(fid, idx)
    else
        s.locked, s.open = false, true
        persist(fid, idx)
    end
    broadcast(fid, idx)
    return { ok = true }
end)

--- keypad: lock (needs a PIN set; closes the door first). Gates: toggles between "locked" and "open to everyone"
lib.callback.register('opslabs-towers:door:lock', function(src, fid, idx, locked)
    fid, idx = tonumber(fid), tonumber(idx)
    local ok = nearDoor(src, fid, idx)
    if not ok then return { error = 'Too far away' } end
    local s = st(fid, idx)
    if locked ~= false and not s.pin then return { error = 'Set a PIN first' } end
    if locked == false then
        -- unlocking without the PIN is only for engineers / admins; everyone else uses door:unlock
        if not CanCable(src) then return { error = 'Enter the PIN to unlock' } end
        s.locked = false
    else
        s.locked, s.open, s.pass = true, false, nil
    end
    persist(fid, idx)
    broadcast(fid, idx)
    return { ok = true }
end)

--- set / change a PIN (idx = 'all' sets every door in the building). Needs the current PIN, unless there is none
--- yet or you are a network engineer / admin.
lib.callback.register('opslabs-towers:door:setPin', function(src, fid, idx, old, new)
    fid = tonumber(fid)
    local L = layout(fid)
    if not L or not L.doors then return { error = 'No doors here' } end
    new = validPin(new)
    if not new then return { error = 'A PIN is 4 to 6 digits' } end
    local list = {}
    if idx == 'all' then for i in ipairs(L.doors) do list[#list + 1] = i end else list[1] = tonumber(idx) end
    if not nearDoor(src, fid, list[1], 25.0) then return { error = 'Too far away' } end
    if lockedOut(src) then return { error = 'Keypad locked out — try again in 30 seconds' } end
    local admin = CanCable(src)
    for _, i in ipairs(list) do
        local s = st(fid, i)
        if s.pin and not admin then
            local o = validPin(old)
            if not o or hashPin(fid, o) ~= s.pin then failed(src) return { error = 'Current PIN is wrong' } end
        end
    end
    for _, i in ipairs(list) do
        st(fid, i).pin = hashPin(fid, new)
        persist(fid, i)
        broadcast(fid, i)
    end
    return { ok = true, count = #list }
end)

--- engineers / admins: clear a PIN (and unlock)
lib.callback.register('opslabs-towers:door:clearPin', function(src, fid, idx)
    fid = tonumber(fid)
    if not CanCable(src) then return { error = 'not allowed' } end
    local L = layout(fid)
    if not L or not L.doors then return { error = 'No doors here' } end
    local list = {}
    if idx == 'all' then for i in ipairs(L.doors) do list[#list + 1] = i end else list[1] = tonumber(idx) end
    for _, i in ipairs(list) do
        local s = st(fid, i)
        s.pin, s.locked = nil, false
        persist(fid, i)
        broadcast(fid, i)
    end
    return { ok = true }
end)

--- someone (on foot or in a vehicle) is at a gate: open it if it's free to use or they have a pass
RegisterNetEvent('opslabs-towers:gate:presence', function(fid, idx)
    local src = source
    fid, idx = tonumber(fid), tonumber(idx)
    if not fid or not idx then return end
    local ok, d = nearDoor(src, fid, idx, 3.0)
    if not ok or not d.auto then return end
    local s = st(fid, idx)
    if s.locked and not (s.pass and s.pass > now()) then return end
    s.closeAt = now() + 5
    if not s.open then
        s.open = true
        broadcast(fid, idx)
    end
end)

-- close gates nobody is using
CreateThread(function()
    while true do
        Wait(1000)
        local t = now()
        for fid, doors in pairs(State) do
            if not Cabling.fixtures[fid] then
                State[fid] = nil
            else
                for idx, s in pairs(doors) do
                    if s.open and s.closeAt and s.closeAt < t then
                        s.open, s.closeAt = false, nil
                        if s.pass and s.pass < t then s.pass = nil end
                        broadcast(fid, idx)
                    end
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function() Fails[source] = nil end)

-- a building / gate taken away takes its doors, locks and PINs with it
AddEventHandler('opslabs-towers:fixtureRemoved', function(fid)
    if not State[fid] then return end
    State[fid] = nil
    MySQL.query('DELETE FROM opslabs_towers_doors WHERE fixture_id = ?', { fid })
end)
