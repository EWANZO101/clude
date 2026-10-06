-- Wireless charger dock: put your phone down on a Qi pad / stand (opslabs-towers). The item leaves your inventory
-- (server/dock.lua) and the phone lies on the charger as a prop everyone sees, with its screen lit while it charges.
-- You can still use it (F1) standing beside it; walk away and the screen closes. E picks it up again.

local CD = Config.Dock or {}

function MyDock() return nil end
function DockDistance() return nil end
function DockCharging() return nil end
if CD.Enabled == false then return end

local docks = {}          -- fixture id -> { id, model, x, y, z, heading, owner, color }
local props = {}          -- fixture id -> { ent, model }
local myDockId = nil

local function towers() return GetResourceState('opslabs-towers') == 'started' end

local function liveCharger(id)
    if not towers() then return false end
    local ok, live = pcall(function() return exports['opslabs-towers']:IsMainsLive(id) end)
    return ok and live == true
end

--- the dock my phone is lying on
function MyDock() return myDockId and docks[myDockId] or nil end

function DockDistance()
    local d = MyDock()
    if not d then return nil end
    return #(GetEntityCoords(PlayerPedId()) - vector3(d.x, d.y, d.z))
end

--- client/battery.lua: 'wireless' while my docked phone sits on a live charger
function DockCharging()
    local d = MyDock()
    return d and liveCharger(d.id) and 'wireless' or nil
end

--- where a phone sits on a charger, in the world
local function spot(d)
    local s = (CD.Spots or {})[d.model] or { pos = vector3(0.0, 0.0, 0.01), pitch = 0.0 }
    local h = math.rad(d.heading or 0.0)
    local c, sn = math.cos(h), math.sin(h)
    local o = s.pos
    return vector3(d.x + o.x * c - o.y * sn, d.y + o.x * sn + o.y * c, d.z + o.z), s.pitch or 0.0
end

local function modelFor(on)
    local name = (CD.Models or {})[on and 'on' or 'off']
    local h = name and joaat(name)
    if h and IsModelInCdimage(h) then return h end
    return Config.Prop
end

local function dropProp(id)
    local p = props[id]
    if p and DoesEntityExist(p.ent) then DeleteEntity(p.ent) end
    props[id] = nil
end

local function placeProp(d)
    local model = modelFor(liveCharger(d.id))
    local p = props[d.id]
    if p and p.model == model and DoesEntityExist(p.ent) then return end
    dropProp(d.id)
    if not lib.requestModel(model, 5000) then return end
    local pos, pitch = spot(d)
    local e = CreateObjectNoOffset(model, pos.x, pos.y, pos.z, false, false, false)
    SetEntityRotation(e, pitch, 0.0, d.heading or 0.0, 2, false)
    SetEntityCoordsNoOffset(e, pos.x, pos.y, pos.z, false, false, false)
    FreezeEntityPosition(e, true)
    SetEntityCollision(e, false, false)
    SetModelAsNoLongerNeeded(model)
    props[d.id] = { ent = e, model = model }
end

local function setDocks(list)
    local me = GetPlayerServerId(PlayerId())
    local wasMine = myDockId
    docks, myDockId = {}, nil
    for _, d in pairs(list or {}) do
        docks[d.id] = d
        if d.owner == me then myDockId = d.id end
    end
    for id in pairs(props) do if not docks[id] then dropProp(id) end end
    if (wasMine ~= nil) ~= (myDockId ~= nil) and RefreshHasPhone then CreateThread(function() RefreshHasPhone() end) end
end

AddStateBagChangeHandler('opsphone:docks', 'global', function(_, _, value) setDocks(value) end)
CreateThread(function() setDocks(GlobalState['opsphone:docks']) end)

-- the server says my phone went down / came back
RegisterNetEvent('opslabs-phone:docked', function(down, live)
    if down then
        lib.notify({ type = 'inform', title = 'Phone', description = live and 'Phone on the charger: charging wirelessly' or 'Phone on the charger (the charger has no power)' })
        if PhoneOpen then StopPhoneAnim() end
    else
        if PhoneOpen then PlayPhoneAnim(InCall and 'call' or 'text') elseif InCall then PlayPhoneAnim('call') end
    end
    if RefreshHasPhone then CreateThread(function() RefreshHasPhone() end) end
end)

---------------------------------------------------------------------------
-- props near the player (and the screen lighting up / going dark with the charger's power)
---------------------------------------------------------------------------

CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        for id, d in pairs(docks) do
            local dist = #(pos - vector3(d.x, d.y, d.z))
            if dist < 45.0 then placeProp(d) elseif dist > 55.0 then dropProp(id) end
        end
        Wait(1500)
    end
end)

---------------------------------------------------------------------------
-- put down / pick up
---------------------------------------------------------------------------

local function putDownAnim()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return end
    lib.requestAnimDict('pickup_object')
    TaskPlayAnim(ped, 'pickup_object', 'putdown_low', 5.0, 1.5, 900, 48, 0, false, false, false)
    RemoveAnimDict('pickup_object')
end

local function canAct()
    local ped = PlayerPedId()
    return not IsPedInAnyVehicle(ped, false) and not IsEntityDead(ped) and not LocalPlayer.state.isDead and not IsPedCuffed(ped)
        and not IsPauseMenuActive()
end

local busyUntil = 0
local function dock(fixture)
    if GetGameTimer() < busyUntil then return end
    busyUntil = GetGameTimer() + 2000
    putDownAnim()
    TriggerServerEvent('opslabs-phone:dock', fixture.id)
end

local function undock(id)
    if GetGameTimer() < busyUntil then return end
    busyUntil = GetGameTimer() + 2000
    putDownAnim()
    TriggerServerEvent('opslabs-phone:undock', id)
end

local function nearestDock(maxDist)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bestD
    for id, d in pairs(docks) do
        local dist = #(pos - vector3(d.x, d.y, d.z))
        if dist <= maxDist and (not bestD or dist < bestD) then best, bestD = d, dist end
    end
    return best
end

local shown = nil
local function prompt(text)
    if text == shown then return end
    shown = text
    if text then lib.showTextUI(text, { position = 'right-center', icon = 'mobile-screen' }) else lib.hideTextUI() end
end

CreateThread(function()
    local key = CD.Key or 38
    local reach = CD.PromptDistance or 1.6
    local still, autoDone = 0, nil
    while true do
        local wait = 600
        local text, action
        if towers() and canAct() then
            local d = nearestDock(reach)
            if d then
                local me = GetPlayerServerId(PlayerId())
                if d.owner == me then
                    text, action = ('[E] Pick up phone · [%s] Use it'):format(Config.Keybind or 'F1'), function() undock(d.id) end
                elseif CD.OwnerOnly == false then
                    text, action = '[E] Take phone', function() undock(d.id) end
                end
            elseif not MyDock() and HasPhoneCached and HasPhoneCached() then
                local ok, f = pcall(function() return exports['opslabs-towers']:WirelessChargerNear(reach) end)
                if ok and f and not docks[f.id] and (CD.Spots or {})[f.model] then
                    if CD.Auto then
                        -- stand still beside a free charger for a moment and the phone goes down by itself
                        if autoDone ~= f.id and GetEntitySpeed(PlayerPedId()) < 0.2 then
                            if still == 0 then still = GetGameTimer() end
                            if GetGameTimer() - still >= (CD.AutoDelay or 2500) then autoDone = f.id dock(f) end
                        else
                            still = 0
                        end
                    else
                        text, action = '[E] Put phone on the charger', function() dock(f) end
                    end
                else
                    still, autoDone = 0, nil
                end
            else
                still = 0
            end
        end
        prompt(text)
        if action then
            wait = 0
            if IsControlJustReleased(0, key) and not PhoneOpen then action() end
        elseif CD.Auto then
            wait = 250
        end
        Wait(wait)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(props) do dropProp(id) end
    if shown then lib.hideTextUI() end
end)
