-- OPS SafeMag: a magnetic battery pack. Use the item to snap it onto the back of the phone / take it off. While it's
-- on it charges the phone wirelessly from its own battery (client/battery.lua asks SafeMagSupply / SafeMagDraw). On a
-- charger the phone charges first and the pack after it; a pack that's off charges beside any live charger.
-- The UI gets { owned, on, level, charging } for the Dynamic Island and the Batteries widget.

local CS = Config.SafeMag or {}

function SafeMagSupply() return false end
function SafeMagDraw() end
function SafeMagLoad() end
function SafeMagOnProp() end
function SafeMagOffProp() end
if CS.Enabled == false then
    RegisterNUICallback('safemagState', function(_, cb) cb({}) end)   -- switched off: answer straight away
    return
end

local PREFIX = 'opslabs-phone:'
local S = { owned = false, on = false, level = 100.0, charging = false }
local loaded = false
local busy = false
local warned = {}
local topped = false          -- reached StopAt: wait for the phone to drop a little before topping it up again
local lastReport, lastSent = 0, ''
local showPack, removePack     -- the pack model on the phone in your hand (below)

local function round(v) return math.floor(v + 0.5) end

local function state(event)
    return { event = event, owned = S.owned, on = S.on, level = round(S.level), charging = S.charging, label = CS.Label or 'OPS SafeMag' }
end

local function push(event)
    SendNUIMessage({ action = 'safemag', data = state(event) })
end

-- the phone UI asks when it (re)loads: a push sent before the page was ready is lost
RegisterNUICallback('safemagState', function(_, cb) cb(loaded and state() or {}) end)

local function report()
    lastReport = GetGameTimer()
    TriggerServerEvent(PREFIX .. 'safemag', S.level, S.on)
end

--- settings arrive with the phone data (client/main.lua Preload)
function SafeMagLoad(settings)
    local m = type(settings) == 'table' and type(settings.safemag) == 'table' and settings.safemag or {}
    S.level = tonumber(m.level) or 100.0
    S.on = m.on == true
    warned = {}
    loaded = true
    CreateThread(function()
        S.owned = lib.callback.await(PREFIX .. 'hasSafeMag', false) == true
        if not S.owned then S.on = false end
        push()
    end)
end

--- battery.lua: can the pack charge the phone right now?
function SafeMagSupply()
    if not (loaded and S.on and S.level > 0) then return false end
    local stop = CS.StopAt or 100
    if BatteryLevel >= stop then topped = true end
    if topped and BatteryLevel < stop - 3 then topped = false end
    return not topped
end

--- battery.lua: `pct` went into the phone; returns how much the pack could actually give
function SafeMagDraw(pct)
    local cost = pct * (CS.Cost or 0.7)
    if cost > S.level then pct, cost = S.level / (CS.Cost or 0.7), S.level end
    S.level = math.max(0.0, S.level - cost)
    return pct
end

local function hasPhone()
    if not Config.RequireItem then return true end
    return HasPhoneCached == nil or HasPhoneCached()
end

local function setOn(on, silent)
    S.on = on
    topped = false
    showPack()
    push(on and 'on' or 'off')
    report()
    if not silent then
        lib.notify({ type = 'inform', title = CS.Label or 'OPS SafeMag',
            description = on and ('Snapped onto your phone · %d%%'):format(round(S.level)) or 'Taken off your phone' })
    end
end

RegisterNetEvent(PREFIX .. 'safemagUse', function()
    if busy or not loaded then return end
    S.owned = true
    if S.on then return setOn(false) end
    if not hasPhone() then
        return lib.notify({ type = 'error', title = CS.Label or 'OPS SafeMag', description = 'You need a phone to snap it onto' })
    end
    if MyDock and MyDock() then
        return lib.notify({ type = 'error', title = CS.Label or 'OPS SafeMag', description = 'Pick your phone up off the charger first' })
    end
    busy = true
    -- a quick look at the phone while it clicks on
    local ped = PlayerPedId()
    if not PhoneOpen and not IsPedInAnyVehicle(ped, false) then
        lib.requestAnimDict('cellphone@')
        TaskPlayAnim(ped, 'cellphone@', 'cellphone_text_read_base', 4.0, -4.0, 1200, 49, 0, false, false, false)
        Wait(700)
    end
    setOn(true)             -- the UI peeks the phone up to show the charging animation
    busy = false
end)

---------------------------------------------------------------------------
-- the pack on the back of the phone in your hand (opslabs-props opslabs_safemag, networked so others see it)
---------------------------------------------------------------------------

local phoneEnt, packEnt = nil, nil

--- rotation matrix (columns = where the pack's x / y / z end up) -> GTA euler, rotation order 2 (R = Rz * Rx * Ry)
local function toEuler(cx, cy, cz)
    local x = math.asin(math.max(-1.0, math.min(1.0, cy.z)))
    local y, z
    if math.abs(cy.z) > 0.9999 then
        y, z = 0.0, math.atan(cx.y, cx.x)     -- pointing straight up / down (gimbal lock): no roll, heading from x
    else
        y, z = math.atan(-cx.z, cz.z), math.atan(-cy.x, cy.y)
    end
    return vector3(math.deg(x), math.deg(y), math.deg(z))
end

local function cross(a, b) return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end

--- where the pack goes on this phone model: flat on its back, centred, pointing the same way as the phone
local function fit(ent)
    local A = CS.Attach or {}
    if A.pos and A.rot then return A.pos, A.rot end
    local mn, mx = GetModelDimensions(GetEntityModel(ent))
    local size, mid = mx - mn, (mn + mx) / 2
    local axes = { { 'x', size.x }, { 'y', size.y }, { 'z', size.z } }
    table.sort(axes, function(a, b) return a[2] < b[2] end)
    local thin, long = axes[1][1], axes[3][1]
    local unit = { x = vector3(1.0, 0.0, 0.0), y = vector3(0.0, 1.0, 0.0), z = vector3(0.0, 0.0, 1.0) }
    local side = (A.side or 1) >= 0 and 1 or -1            -- which face of the phone is the back
    local up = unit[long] * ((A.flip and -1) or 1)
    local toPhone = unit[thin] * -side                      -- the pack's +Z (its phone side) faces the phone
    local pos = mid + unit[thin] * (side * size[thin] / 2) + (A.offset or vector3(0.0, 0.0, 0.0))
    return pos, toEuler(cross(up, toPhone), up, toPhone)
end

removePack = function()
    if packEnt and DoesEntityExist(packEnt) then DeleteEntity(packEnt) end
    packEnt = nil
end

showPack = function()
    removePack()
    if not (S.on and phoneEnt and DoesEntityExist(phoneEnt)) then return end
    local model = CS.Model or `opslabs_safemag`
    if not IsModelInCdimage(model) then return end           -- opslabs-props not running
    lib.requestModel(model)
    packEnt = CreateObject(model, 0.0, 0.0, 0.0, true, true, false)
    SetEntityCollision(packEnt, false, false)
    local pos, rot = fit(phoneEnt)
    AttachEntityToEntity(packEnt, phoneEnt, 0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, false, false, false, false, 2, true)
    SetModelAsNoLongerNeeded(model)
end

--- client/main.lua: the phone prop came into / left your hand
function SafeMagOnProp(ent) phoneEnt = ent showPack() end
function SafeMagOffProp() phoneEnt = nil removePack() end

-- /safemagside: flips which face of the phone counts as the back, to line the pack up with a different phone prop
RegisterCommand('safemagside', function()
    CS.Attach = CS.Attach or {}
    CS.Attach.side = (CS.Attach.side or 1) >= 0 and -1 or 1
    showPack()
    print(('[opslabs-phone] OPS SafeMag: Config.SafeMag.Attach.side = %d'):format(CS.Attach.side))
end, false)

-- charging the pack, losing it, low warnings
CreateThread(function()
    local step = 5
    while true do
        Wait(step * 1000)
        if loaded and S.owned then
            local before = S.level
            -- on the phone: charges with it once the phone is (nearly) full; off it: beside a live charger
            local docked = MyDock and MyDock() and DockCharging and DockCharging()
            local charger = docked or (TowersChargerNear and TowersChargerNear())
            local charging = charger and (not S.on or (BatteryLevel or 0) >= 95) and S.level < 100 or false
            if charging then S.level = math.min(100.0, S.level + (CS.Recharge or 2.5) * step / 60) end
            if S.on and S.level < before then
                for _, w in ipairs(CS.Warnings or { 20, 10 }) do
                    if before > w and S.level <= w and not warned[w] then
                        warned[w] = true
                        SendNUIMessage({ action = 'notify', data = { app = 'settings', title = CS.Label or 'OPS SafeMag', body = ('Low Battery: %d%% remaining'):format(w) } })
                    end
                end
                if S.level <= 0 then
                    lib.notify({ type = 'error', title = CS.Label or 'OPS SafeMag', description = 'The SafeMag is flat. Charge it beside a live charger.' })
                end
            elseif S.level > 25 then
                warned = {}
            end
            local key = ('%d|%s|%s'):format(round(S.level), tostring(S.on), tostring(charging))
            if key ~= lastSent then
                lastSent = key
                S.charging = charging
                push()
            end
            if GetGameTimer() - lastReport > 60000 and S.level ~= before then report() end
        end
    end
end)

-- dropped it, gave it away, put it in a stash: it comes off the phone with it
CreateThread(function()
    while true do
        Wait(15000)
        if loaded then
            local has = lib.callback.await(PREFIX .. 'hasSafeMag', false) == true
            if has ~= S.owned then
                S.owned = has
                if not has and S.on then setOn(false, true) else push() end
            end
        end
    end
end)

-- character switch: everything comes back with the new character's settings
FW.OnPlayerUnloaded(function()
    if loaded then report() end
    loaded = false
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removePack()
    if loaded then report() end
end)
