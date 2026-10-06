local PREFIX = 'opslabs-phone:'

PhoneOpen = false
InCall = false
local prop
local initialized = false
local typing = false
local flashlight = false

---------------------------------------------------------------------------
-- prop / animation
---------------------------------------------------------------------------

local ANIM_DICT = 'cellphone@'
local ANIMS = {
    text = 'cellphone_text_read_base',
    call = 'cellphone_call_listen_base',
    camera = 'cellphone_photo_idle',
}

local function attachProp()
    if prop and DoesEntityExist(prop) then return end
    lib.requestModel(Config.Prop)
    local ped = PlayerPedId()
    prop = CreateObject(Config.Prop, 0.0, 0.0, 0.0, true, true, false)
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, 28422), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
    SetModelAsNoLongerNeeded(Config.Prop)
    if SafeMagOnProp then SafeMagOnProp(prop) end   -- OPS SafeMag on the back (client/safemag.lua)
end

local function removeProp()
    if SafeMagOffProp then SafeMagOffProp() end
    if prop and DoesEntityExist(prop) then DeleteEntity(prop) end
    prop = nil
end

function PlayPhoneAnim(kind)
    -- the phone is lying on a wireless charger (client/dock.lua): nothing in your hand
    if MyDock and MyDock() then return StopPhoneAnim() end
    -- OPS Buds in: calls are hands-free (client/buds.lua)
    if kind == 'call' and BudsHandsFree and BudsHandsFree() then
        if not PhoneOpen then return StopPhoneAnim() end
        kind = 'text'
    end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) and kind ~= 'call' then
        -- in vehicles the text anim clips through the wheel; keep the prop only
        attachProp()
        return
    end
    lib.requestAnimDict(ANIM_DICT)
    TaskPlayAnim(ped, ANIM_DICT, ANIMS[kind] or ANIMS.text, 3.0, 3.0, -1, 50, 0, false, false, false)
    attachProp()
end

function StopPhoneAnim()
    local ped = PlayerPedId()
    StopAnimTask(ped, ANIM_DICT, ANIMS.text, 2.5)
    StopAnimTask(ped, ANIM_DICT, ANIMS.call, 2.5)
    StopAnimTask(ped, ANIM_DICT, ANIMS.camera, 2.5)
    removeProp()
end

---------------------------------------------------------------------------
-- open / close
---------------------------------------------------------------------------

local function canUsePhone()
    if IsPauseMenuActive() then return false end
    if IsEntityDead(PlayerPedId()) or LocalPlayer.state.isDead then return false end
    if IsPedCuffed(PlayerPedId()) then return false end
    return true
end

-- Loads the phone data into the UI ahead of time so the first open is instant.
local preloading = false
function Preload()
    if initialized then return true end
    while preloading do Wait(50) end
    if initialized then return true end
    preloading = true
    local data = lib.callback.await(PREFIX .. 'init', false)
    preloading = false
    if not data then return false end
    SendNUIMessage({ action = 'init', data = data })
    initialized = true
    if BatteryLoad then BatteryLoad(data.settings and data.settings.battery) end
    if BudsLoad then BudsLoad(data.settings) end
    if SafeMagLoad then SafeMagLoad(data.settings) end
    if HasPhoneCached and HasPhoneCached() == nil then CreateThread(function() RefreshHasPhone() end) end
    return true
end

-- Cached "do I own a phone item" so opening doesn't wait on a server round
-- trip. It is refreshed whenever a phone item enters/leaves the inventory.
local hasPhoneCache = nil

local function refreshHasPhone()
    hasPhoneCache = lib.callback.await(PREFIX .. 'canOpen', false) and true or false
    return hasPhoneCache
end
function HasPhoneCached() return hasPhoneCache end   -- client/battery.lua: no phone in your pockets, no drain
RefreshHasPhone = refreshHasPhone

local function onInventoryChange(item)
    if not Config.RequireItem or Config.Items[item] then
        CreateThread(function()
            refreshHasPhone()
            if not hasPhoneCache and PhoneOpen then ClosePhone() end
        end)
    end
end
RegisterNetEvent('esx:addInventoryItem', onInventoryChange)
RegisterNetEvent('esx:removeInventoryItem', onInventoryChange)

function OpenPhone()
    if PhoneOpen or LaptopOpen or not canUsePhone() then return end
    if not Config.RequireItem then hasPhoneCache = true end
    if hasPhoneCache == nil or hasPhoneCache == false then refreshHasPhone() end
    if not hasPhoneCache then
        lib.notify({ description = "You don't have a phone", type = 'error' })
        return
    end
    if PhoneIsDead and PhoneIsDead() then
        lib.notify({ description = 'Your phone battery is flat. Charge it at a charger or with a power bank.', type = 'error' })
        return
    end
    local dockDist = DockDistance and DockDistance()
    if dockDist and dockDist > ((Config.Dock or {}).UseDistance or 2.2) then
        lib.notify({ description = 'Your phone is on the charger. Go back to it to use it.', type = 'error' })
        return
    end

    if not initialized and not Preload() then return end

    -- opened instantly from the cache; confirm in the background
    CreateThread(function()
        if Config.RequireItem and not refreshHasPhone() and PhoneOpen then
            ClosePhone()
            lib.notify({ description = "You don't have a phone", type = 'error' })
        end
    end)

    PhoneOpen = true
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(not typing)
    SendNUIMessage({ action = 'open' })
    PlayPhoneAnim(InCall and 'call' or 'text')

    CreateThread(function()
        local nextCheck = 0
        while PhoneOpen do
            if Config.DisableControlsWhileOpen and not CameraActive then
                DisableControlAction(0, 1, true)   -- look
                DisableControlAction(0, 2, true)
                DisableControlAction(0, 24, true)  -- attack
                DisableControlAction(0, 25, true)  -- aim
                DisableControlAction(0, 140, true)
                DisableControlAction(0, 141, true)
                DisableControlAction(0, 142, true)
                DisableControlAction(0, 257, true)
                DisableControlAction(0, 263, true)
                DisableControlAction(0, 200, true) -- pause menu (ESC closes the phone)
                DisableControlAction(0, 199, true)
                DisableControlAction(0, 37, true)  -- weapon wheel
                DisablePlayerFiring(PlayerId(), true)
            end
            -- state checks don't need to run every frame
            local now = GetGameTimer()
            if now >= nextCheck then
                nextCheck = now + 250
                if not canUsePhone() then ClosePhone() end
                -- using the phone where it lies on the charger: walking away puts the screen down
                local dd = DockDistance and DockDistance()
                if dd and dd > ((Config.Dock or {}).UseDistance or 2.2) then ClosePhone() end
            end
            Wait(0)
        end
    end)
end

function ClosePhone()
    if not PhoneOpen then return end
    PhoneOpen = false
    typing = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'close' })
    if InCall then
        PlayPhoneAnim('call')
    else
        StopPhoneAnim()
    end
end

function TogglePhone()
    if PhoneOpen then ClosePhone() else OpenPhone() end
end

RegisterCommand(Config.Command, TogglePhone, false)
RegisterKeyMapping(Config.Command, 'Open phone', 'keyboard', Config.Keybind)

RegisterNetEvent(PREFIX .. 'open', OpenPhone)

-- re-init on character switch
RegisterNetEvent('esx:playerLoaded', function()
    initialized = false
    hasPhoneCache = nil
    ClosePhone()
    SendNUIMessage({ action = 'reset' })
    SetTimeout(1500, function()
        Preload()
        refreshHasPhone()
    end)
end)

-- resource (re)started while already in game: preload once the character exists
CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    for _ = 1, 20 do
        if initialized or Preload() then break end
        Wait(3000)
    end
end)

RegisterNetEvent('esx:onPlayerLogout', function()
    initialized = false
    ClosePhone()
    SendNUIMessage({ action = 'reset' })
end)

---------------------------------------------------------------------------
-- NUI bridge
---------------------------------------------------------------------------

-- Generic RPC: the UI calls any server callback registered with Register().
-- Every request answers the UI within RPC_TIMEOUT, even if the server reply
-- is lost (e.g. the resource restarted mid-request) or the callback errors.
local RPC_TIMEOUT = 10000

RegisterNUICallback('rpc', function(body, cb)
    if type(body) ~= 'table' or type(body.name) ~= 'string' or not body.name:match('^[%w_]+$') then
        return cb(nil)
    end
    local answered = false
    local function answer(result)
        if answered then return end
        answered = true
        cb(result)
    end
    SetTimeout(RPC_TIMEOUT, function()
        if not answered then
            print(('^3[opslabs-phone] request "%s" timed out^7'):format(body.name))
            answer({ __failed = 'timeout' })
        end
    end)
    local ok, result = pcall(lib.callback.await, PREFIX .. body.name, false, body.data)
    if not ok then
        local msg = tostring(result)
        print(('^1[opslabs-phone] request "%s" failed: %s^7'):format(body.name, msg))
        -- "callback ... does not exist": the server is running an old file list
        return answer({ __failed = msg:find('does not exist', 1, true) and 'outdated' or 'error' })
    end
    answer(result)
end)

-- Server -> UI pushes
RegisterNetEvent(PREFIX .. 'push', function(action, data)
    SendNUIMessage({ action = action, data = data })
end)

RegisterNUICallback('close', function(_, cb)
    ClosePhone()
    cb(true)
end)

RegisterNUICallback('inputFocus', function(body, cb)
    typing = body.focused == true
    if PhoneOpen then SetNuiFocusKeepInput(not typing) end
    cb(true)
end)

RegisterNUICallback('setWaypoint', function(body, cb)
    local x, y = tonumber(body.x), tonumber(body.y)
    if x and y then
        SetNewWaypoint(x + 0.0, y + 0.0)
        lib.notify({ description = 'GPS waypoint set', type = 'inform' })
    end
    cb(true)
end)

RegisterNUICallback('getLocation', function(_, cb)
    local coords = GetEntityCoords(PlayerPedId())
    local street, cross = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    cb({
        x = coords.x, y = coords.y, z = coords.z, h = GetEntityHeading(PlayerPedId()),
        street = GetStreetNameFromHashKey(street),
        cross = cross ~= 0 and GetStreetNameFromHashKey(cross) or nil,
        zone = GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z)),
    })
end)

local WEATHER_NAMES = {
    [`CLEAR`] = 'clear', [`EXTRASUNNY`] = 'sunny', [`CLOUDS`] = 'cloudy', [`OVERCAST`] = 'overcast',
    [`RAIN`] = 'rain', [`CLEARING`] = 'clearing', [`THUNDER`] = 'thunder', [`SMOG`] = 'smog',
    [`FOGGY`] = 'fog', [`XMAS`] = 'snow', [`SNOW`] = 'snow', [`SNOWLIGHT`] = 'snow',
    [`BLIZZARD`] = 'blizzard', [`HALLOWEEN`] = 'halloween', [`NEUTRAL`] = 'cloudy',
}

RegisterNUICallback('getWorld', function(_, cb)
    local w = GetPrevWeatherTypeHashName()
    local coords = GetEntityCoords(PlayerPedId())
    cb({
        weather = WEATHER_NAMES[w] or 'clear',
        hour = GetClockHours(),
        minute = GetClockMinutes(),
        zone = GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z)),
        serverId = GetPlayerServerId(PlayerId()),
    })
end)

RegisterNUICallback('flashlight', function(body, cb)
    flashlight = body.on == true
    if flashlight then
        CreateThread(function()
            while flashlight do
                local ped = PlayerPedId()
                local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 0.4, 0.4)
                local dir = GetEntityForwardVector(ped)
                DrawSpotLight(pos.x, pos.y, pos.z, dir.x, dir.y, dir.z - 0.15, 255, 255, 240, 25.0, 5.0, 0.0, 30.0, 25.0)
                Wait(0)
            end
        end)
    end
    cb(true)
end)

-- model hash -> display label for the Garage app
RegisterNUICallback('vehicleLabels', function(body, cb)
    local out = {}
    for _, model in ipairs(type(body.models) == 'table' and body.models or {}) do
        local hash = math.tointeger(tonumber(model))
        if hash then
            local name = GetDisplayNameFromVehicleModel(hash)
            local label = GetLabelText(name)
            local make = GetLabelText(GetMakeNameFromVehicleModel(hash))
            out[tostring(hash)] = {
                name = (label ~= 'NULL' and label) or name,
                make = make ~= 'NULL' and make or nil,
            }
        end
    end
    cb(out)
end)

RegisterNUICallback('notifyGame', function(body, cb)
    lib.notify({ title = body.title, description = body.body, type = body.type or 'inform' })
    cb(true)
end)

-- clean up when the resource restarts
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if PhoneOpen then SetNuiFocus(false, false) end
    StopPhoneAnim()
end)

exports('OpenPhone', OpenPhone)
exports('ClosePhone', ClosePhone)
exports('IsPhoneOpen', function() return PhoneOpen end)

-- opslabs-towers: signal bars / Wi-Fi for the phone UI
RegisterNetEvent('opslabs-towers:coverage', function(cov)
    SendNUIMessage({ action = 'coverage', data = cov })
end)
