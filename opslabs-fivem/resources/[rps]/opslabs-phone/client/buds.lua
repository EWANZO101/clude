-- OPS Buds: wireless earbuds. Use the item (the case) to put them in; the first time, a card on the phone asks to
-- connect them. While they're in and in range of your phone they're connected: music and calls go through them
-- (calls are hands-free), Noise Control runs (Noise Cancellation mutes the world with an audio scene; Adaptive does
-- too but lets loud things like gunfire through; Transparency / Off leave it alone), Conversation Awareness lowers
-- the music while you talk, and the press control plays / pauses / answers. Each bud and the case has a battery:
-- buds drain in your ears and charge in the case, the case charges beside any live charger (opslabs-towers).

local CB = Config.Buds or {}

function BudsHandsFree() return false end
function BudsLoad() end
if CB.Enabled == false then return end

local PREFIX = 'opslabs-phone:'
local ITEM = CB.Item or 'ops_buds'
local MODE_ORDER = { anc = 'adaptive', adaptive = 'transparency', transparency = 'anc', off = 'anc' }

local S = {
    owned = false, worn = false, connected = false,
    paired = false, name = nil, mode = 'anc', earDetect = true, convAware = true, bluetooth = true,
    l = 100.0, r = 100.0, c = 100.0, caseCharging = false,
    playing = false,
}
local loaded = false
local busy = false
local ears = {}               -- 'l' / 'r' -> entity
local caseProp = nil
local ancOn = false
local ducked = false
local loudUntil, talkUntil = 0, 0
local warned = {}

local function round(v) return math.floor(v + 0.5) end

local function push(event)
    SendNUIMessage({ action = 'buds', data = {
        event = event, owned = S.owned, worn = S.worn, connected = S.connected, paired = S.paired,
        name = S.name, mode = S.mode, earDetect = S.earDetect, convAware = S.convAware,
        l = round(S.l), r = round(S.r), c = round(S.c), caseCharging = S.caseCharging, label = CB.Label or 'OPS Buds',
    } })
end

function BudsHandsFree() return S.connected end

-- the phone UI asks when it (re)loads: a push sent before the page was ready is lost
RegisterNUICallback('budsState', function(_, cb)
    if not loaded then return cb({}) end
    cb({ owned = S.owned, worn = S.worn, connected = S.connected, paired = S.paired, name = S.name, mode = S.mode,
        earDetect = S.earDetect, convAware = S.convAware, l = round(S.l), r = round(S.r), c = round(S.c),
        caseCharging = S.caseCharging, label = CB.Label or 'OPS Buds' })
end)

--- settings arrive with the phone data (client/main.lua Preload)
function BudsLoad(settings)
    settings = settings or {}
    local b = type(settings.buds) == 'table' and settings.buds or {}
    S.paired = b.paired == true
    S.name = b.name
    S.mode = b.mode or 'anc'
    S.earDetect = b.earDetect ~= false
    S.convAware = b.convAware ~= false
    S.bluetooth = settings.bluetooth ~= false
    local bb = type(settings.budsBattery) == 'table' and settings.budsBattery or {}
    S.l, S.r, S.c = tonumber(bb.l) or 100.0, tonumber(bb.r) or 100.0, tonumber(bb.c) or 100.0
    loaded = true
    CreateThread(function()
        S.owned = lib.callback.await(PREFIX .. 'hasBuds', false) == true
        push()
    end)
end

---------------------------------------------------------------------------
-- props: the open case in your hand, a bud in each ear (networked, so everyone sees them)
---------------------------------------------------------------------------

local function v3norm(v) local l = #v return l > 1e-6 and v / l or v end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local HEAD = 31086

--- where a bud goes on SKEL_Head and how it's turned: worked out from the head bone's real axes, so the buds sit
--- upright in the ears (body out to the side, stem down) whatever the bone's own orientation is
local function earAttach(ped, side)
    local o = GetPedBoneCoords(ped, HEAD, 0.0, 0.0, 0.0)
    local bx = v3norm(GetPedBoneCoords(ped, HEAD, 1.0, 0.0, 0.0) - o)
    local by = v3norm(GetPedBoneCoords(ped, HEAD, 0.0, 1.0, 0.0) - o)
    local bz = v3norm(GetPedBoneCoords(ped, HEAD, 0.0, 0.0, 1.0) - o)
    local f = GetEntityForwardVector(ped)
    local fwd = v3norm(vector3(f.x, f.y, 0.0))
    local right = vector3(fwd.y, -fwd.x, 0.0)
    local up = vector3(0.0, 0.0, 1.0)
    local female = GetEntityModel(ped) == `mp_f_freemode_01` or not IsPedMale(ped)
    local E = ((CB.Ear or {})[female and 'female' or 'male']) or { side = 0.072, up = 0.02, forward = 0.0 }
    local d = right * (side * E.side) + up * E.up + fwd * E.forward
    local pos = vector3(dot(d, bx), dot(d, by), dot(d, bz))
    -- model axes (X out to the right, Y forward, Z up) in bone space; R = Rz(c)·Rx(a)·Ry(b), GTA rotation order 2
    local R = {
        { dot(right, bx), dot(fwd, bx), dot(up, bx) },
        { dot(right, by), dot(fwd, by), dot(up, by) },
        { dot(right, bz), dot(fwd, bz), dot(up, bz) },
    }
    local s = math.max(-1.0, math.min(1.0, R[3][2]))
    local a, b, c = math.asin(s), 0.0, 0.0
    if math.abs(s) < 0.9999 then
        b = math.atan(-R[3][1], R[3][3])
        c = math.atan(-R[1][2], R[2][2])
    else
        c = math.atan(R[2][1], R[1][1])
    end
    return pos, vector3(math.deg(a), math.deg(b), math.deg(c))
end

local function spawn(model, net)
    local h = joaat(model)
    if not IsModelInCdimage(h) or not lib.requestModel(h, 5000) then return nil end
    local p = GetEntityCoords(PlayerPedId())
    local e = CreateObject(h, p.x, p.y, p.z - 5.0, net, net, false)
    SetEntityCollision(e, false, false)
    SetModelAsNoLongerNeeded(h)
    return e
end

local function removeEars()
    for k, e in pairs(ears) do if DoesEntityExist(e) then DeleteEntity(e) end ears[k] = nil end
end

local function attachEars()
    removeEars()
    local ped = PlayerPedId()
    for key, side in pairs({ r = 1, l = -1 }) do
        local e = spawn(key == 'r' and 'opslabs_bud_r' or 'opslabs_bud_l', true)
        if e then
            local pos, rot = earAttach(ped, side)
            AttachEntityToEntity(e, ped, GetPedBoneIndex(ped, HEAD), pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, false, false, false, true, 2, true)
            ears[key] = e
        end
    end
end

local function holdCase(open)
    if caseProp and DoesEntityExist(caseProp) then DeleteEntity(caseProp) end
    caseProp = nil
    if open == nil then return end
    local ped = PlayerPedId()
    caseProp = spawn(open and 'opslabs_buds_case_open' or 'opslabs_buds_case', true)
    if caseProp then
        AttachEntityToEntity(caseProp, ped, GetPedBoneIndex(ped, 28422), 0.0, -0.01, 0.0, 0.0, 0.0, 180.0, false, false, false, true, 2, true)
    end
end

local function anim(name, ms)
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) and name ~= 'cellphone_call_listen_base' then return end
    lib.requestAnimDict('cellphone@')
    TaskPlayAnim(ped, 'cellphone@', name, 4.0, 4.0, ms, 50, 0, false, false, false)
end

---------------------------------------------------------------------------
-- connection: buds in, paired, a phone in reach that's switched on, Bluetooth on
---------------------------------------------------------------------------

local function phoneReach()
    if not loaded then return false, 'phone' end
    if HasPhoneCached and not HasPhoneCached() then return false, 'phone' end
    if PhoneIsDead and PhoneIsDead() then return false, 'phone' end
    local dd = DockDistance and DockDistance()
    if dd and dd > (CB.Range or 12.0) then return false, 'range' end
    if not S.bluetooth then return false, 'bluetooth' end
    return true
end

local lastReason = nil
local function refreshConnection()
    local ok, why = phoneReach()
    local flat = S.l <= 0 and S.r <= 0
    local want = S.worn and S.paired and ok and not flat
    if want ~= S.connected then
        S.connected = want
        push(want and 'connected' or 'disconnected')
        if not want and S.worn then
            local reason = flat and 'flat' or why
            if reason ~= lastReason then
                lastReason = reason
                local msg = ({ range = 'OPS Buds lost the connection: you are too far from your phone',
                    flat = 'OPS Buds battery is flat. Put them back in the case to charge.',
                    bluetooth = 'Bluetooth is off on your phone', phone = 'OPS Buds have no phone to connect to' })[reason]
                if msg then lib.notify({ type = 'error', title = CB.Label or 'OPS Buds', description = msg }) end
            end
        else
            lastReason = nil
        end
    end
end

---------------------------------------------------------------------------
-- putting them in / taking them out
---------------------------------------------------------------------------

local function putIn()
    holdCase(nil)
    anim('cellphone_call_listen_base', 1100)
    Wait(700)
    attachEars()
    S.worn = true
    push('in')
    if S.l <= 0 and S.r <= 0 then
        lib.notify({ type = 'error', title = CB.Label or 'OPS Buds', description = 'OPS Buds battery is flat. Put them back in the case to charge.' })
    end
    refreshConnection()
    Wait(400)
    if not PhoneOpen then StopAnimTask(PlayerPedId(), 'cellphone@', 'cellphone_call_listen_base', 2.0) end
    busy = false
end

local function takeOut(silent)
    if not silent then
        anim('cellphone_call_listen_base', 900)
        Wait(600)
    end
    removeEars()
    S.worn = false
    refreshConnection()
    push('out')
    if not silent and not PhoneOpen then StopAnimTask(PlayerPedId(), 'cellphone@', 'cellphone_call_listen_base', 2.0) end
end

local pairing = false
RegisterNetEvent(PREFIX .. 'budsUse', function()
    if busy or pairing then return end
    S.owned = true
    if S.worn then
        busy = true
        takeOut(false)
        busy = false
        return
    end
    busy = true
    -- open the case in your hand
    holdCase(true)
    if not PhoneOpen then anim('cellphone_text_read_base', 1400) end
    Wait(900)
    if not S.paired then
        if not phoneReach() then
            holdCase(nil)
            busy = false
            return lib.notify({ type = 'error', title = CB.Label or 'OPS Buds', description = 'Open the case next to your phone to connect your OPS Buds' })
        end
        -- the "Connect" card on the phone; the case stays open in your hand until you answer it
        pairing = true
        if not PhoneOpen then OpenPhone() end
        SendNUIMessage({ action = 'budsCard', data = { stage = 'pair', l = round(S.l), r = round(S.r), c = round(S.c), label = CB.Label or 'OPS Buds' } })
        SetTimeout(45000, function()
            if pairing then pairing = false busy = false holdCase(nil) SendNUIMessage({ action = 'budsCard', data = { stage = 'close' } }) end
        end)
        return
    end
    if PhoneOpen then SendNUIMessage({ action = 'budsCard', data = { stage = 'battery', l = round(S.l), r = round(S.r), c = round(S.c), label = CB.Label or 'OPS Buds' } }) end
    putIn()
end)

RegisterNUICallback('budsPair', function(_, cb)
    cb(true)
    if not pairing then return end
    pairing = false
    S.paired = true
    CreateThread(putIn)
end)

RegisterNUICallback('budsCardClosed', function(_, cb)
    cb(true)
    if pairing then pairing = false busy = false holdCase(nil) end
end)

-- settings changed on the phone (Bluetooth page, Control Center)
RegisterNUICallback('budsSet', function(body, cb)
    cb(true)
    if type(body) ~= 'table' then return end
    if body.paired ~= nil then S.paired = body.paired == true end
    if body.mode then S.mode = body.mode end
    if body.earDetect ~= nil then S.earDetect = body.earDetect == true end
    if body.convAware ~= nil then S.convAware = body.convAware == true end
    if body.name ~= nil then S.name = body.name end
    if body.bluetooth ~= nil then S.bluetooth = body.bluetooth == true end
    if body.paired == false and S.worn then CreateThread(function() takeOut(true) end) end
    refreshConnection()
    push('settings')
end)

RegisterNUICallback('budsAudio', function(body, cb)
    S.playing = body and body.playing == true
    cb(true)
end)

---------------------------------------------------------------------------
-- the press control: tap = play / pause, answer / hang up · double tap = next track · hold = Noise Control
---------------------------------------------------------------------------

local pressAt, pressed, held, taps = 0, false, false, 0

local function cycleMode()
    S.mode = MODE_ORDER[S.mode] or 'anc'
    push('mode')
end

RegisterCommand('+opsbuds', function()
    if not S.connected then return end
    pressed, held = true, false
    local t = GetGameTimer()
    pressAt = t
    SetTimeout(600, function()
        if pressed and pressAt == t then held = true cycleMode() end
    end)
end, false)

RegisterCommand('-opsbuds', function()
    if not pressed then return end
    pressed = false
    if held or not S.connected then return end
    taps = taps + 1
    if taps == 1 then
        SetTimeout(350, function()
            local n = taps
            taps = 0
            SendNUIMessage({ action = 'budsPress', data = { taps = n } })
        end)
    end
end, false)
RegisterKeyMapping('+opsbuds', 'OPS Buds: press (play / pause, answer) · hold (Noise Control)', 'keyboard', CB.Keybind or 'PAGEUP')

---------------------------------------------------------------------------
-- loops: connection + props, Noise Control / Conversation Awareness, batteries
---------------------------------------------------------------------------

local function ownsBuds()
    S.owned = lib.callback.await(PREFIX .. 'hasBuds', false) == true
    if not S.owned and S.worn then takeOut(true) end
    push()
end
local function onInventory(item) if item == ITEM and loaded then CreateThread(ownsBuds) end end
RegisterNetEvent('esx:addInventoryItem', onInventory)
RegisterNetEvent('esx:removeInventoryItem', onInventory)

CreateThread(function()
    local n = 0
    while true do
        Wait(1000)
        n = n + 1
        if loaded then
            refreshConnection()
            if S.worn then
                -- respawned / changed clothes / model: put the buds back where they belong
                local ped = PlayerPedId()
                for _, e in pairs(ears) do
                    if not DoesEntityExist(e) or not IsEntityAttachedToEntity(e, ped) then attachEars() break end
                end
                if not next(ears) then attachEars() end
                -- lost the case (dropped, given away): the buds go with it
                if n % 15 == 0 then CreateThread(ownsBuds) end
            end
        end
    end
end)

local scene = CB.AncScene or ''
CreateThread(function()
    while true do
        local wait = 1000
        if S.connected then
            wait = 250
            local now = GetGameTimer()
            local ped = PlayerPedId()
            local p = GetEntityCoords(ped)
            if S.convAware and NetworkIsPlayerTalking(PlayerId()) then talkUntil = now + 3500 end
            if S.mode == 'adaptive' and (IsAnyPedShootingInArea(p.x - 40.0, p.y - 40.0, p.z - 15.0, p.x + 40.0, p.y + 40.0, p.z + 15.0, false, false)
                or IsExplosionInSphere(-1, p.x, p.y, p.z, 50.0)) then loudUntil = now + 8000 end
            local talking = now < talkUntil
            if talking ~= ducked then
                ducked = talking
                SendNUIMessage({ action = 'budsDuck', data = { on = talking } })
            end
            local want = scene ~= '' and not talking and (S.mode == 'anc' or (S.mode == 'adaptive' and now >= loudUntil))
            if want ~= ancOn then
                ancOn = want
                if want then StartAudioScene(scene) else StopAudioScene(scene) end
            end
        else
            if ancOn then ancOn = false StopAudioScene(scene) end
            if ducked then ducked = false SendNUIMessage({ action = 'budsDuck', data = { on = false } }) end
        end
        Wait(wait)
    end
end)

CreateThread(function()
    local step = 5
    local lastSent = ''
    local lastReport = 0
    while true do
        Wait(step * 1000)
        if loaded and (S.owned or S.worn) then
            local before = math.min(S.l, S.r)
            if S.worn then
                local rate = (S.connected and (S.playing or InCall)) and (CB.Drain or 0.28) or (CB.DrainIdle or 0.12)
                if S.connected and (S.mode == 'anc' or S.mode == 'adaptive') then rate = rate + (CB.DrainAnc or 0.05) end
                rate = rate * step / 60
                S.l = math.max(0.0, S.l - rate * (0.96 + math.random() * 0.08))
                S.r = math.max(0.0, S.r - rate * (0.96 + math.random() * 0.08))
                local now = math.min(S.l, S.r)
                for _, w in ipairs(CB.Warnings or { 20, 10 }) do
                    if before > w and now <= w and not warned[w] then
                        warned[w] = true
                        if S.connected then
                            SendNUIMessage({ action = 'notify', data = { app = 'settings', title = CB.Label or 'OPS Buds', body = ('Low Battery: %d%% remaining'):format(w) } })
                        end
                    end
                end
            else
                -- in the case: the case tops the buds up while it has charge
                for _, k in ipairs({ 'l', 'r' }) do
                    local add = math.min(100.0 - S[k], (CB.BudCharge or 6.0) * step / 60)
                    local cost = add * (CB.CaseCost or 0.22)
                    if add > 0 and S.c > 0 then
                        if cost > S.c then add, cost = add * S.c / cost, S.c end
                        S[k] = S[k] + add
                        S.c = math.max(0.0, S.c - cost)
                    end
                end
                if math.min(S.l, S.r) > 25 then warned = {} end
            end
            local charging = S.owned and TowersChargerNear and TowersChargerNear() ~= nil or false
            if charging then S.c = math.min(100.0, S.c + (CB.CaseCharge or 2.0) * step / 60) end
            local key = ('%d|%d|%d|%s'):format(round(S.l), round(S.r), round(S.c), tostring(charging))
            if key ~= lastSent or charging ~= S.caseCharging then
                S.caseCharging = charging
                lastSent = key
                push()
            end
            if GetGameTimer() - lastReport > 60000 then
                lastReport = GetGameTimer()
                TriggerServerEvent(PREFIX .. 'budsBattery', S.l, S.r, S.c)
            end
        end
    end
end)

-- character switch: everything comes back with the new character's settings
RegisterNetEvent('esx:onPlayerLogout', function()
    if S.worn then takeOut(true) end
    loaded = false
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeEars()
    holdCase(nil)
    if ancOn and scene ~= '' then StopAudioScene(scene) end
    if loaded then TriggerServerEvent(PREFIX .. 'budsBattery', S.l, S.r, S.c) end
end)
