local nearbyParked = {}
local busy = false

local function notify(msg, t) Bridge.Notify(msg, t) end

local function ModelLabel(model)
    local name = GetDisplayNameFromVehicleModel(model)
    local label = GetLabelText(name)
    return label ~= 'NULL' and label or name
end

local function DrawText3D(x, y, z, text)
    local onScreen, sx, sy = World3dToScreen2d(x, y, z)
    if not onScreen then return end
    SetTextScale(0.32, 0.32)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(sx, sy)
end

---------------------------------------------------------------------------
-- Police: target a parked car to ticket or impound it (Config.PoliceJobs)
---------------------------------------------------------------------------
local isPolice = false
local policeTargets = {} -- [vehicle] = true
local policeUseTarget = false

-- job check is done by the server (works on every framework + standalone ACE)
CreateThread(function()
    while true do
        isPolice = lib.callback.await('rps_parking:isPolice', false) == true
        Wait(15000)
    end
end)

local function TicketVehicle(veh)
    local plate = Entity(veh).state.parked
    if not plate then return end
    local input = lib.inputDialog(('Parking ticket • %s'):format(plate), {
        { type = 'number', label = 'Fine amount ($)', required = true, min = 1, max = Config.MaxTicket, icon = 'dollar-sign' },
        { type = 'input', label = 'Reason', placeholder = 'Parking violation', max = 100 },
    })
    if not input or not input[1] then return end
    local ok, msg = lib.callback.await('rps_parking:ticket', false, VehToNet(veh), input[1], input[2] or '')
    notify(msg, ok and 'success' or 'error')
end

local function ImpoundVehicle(veh)
    local plate = Entity(veh).state.parked
    if not plate then return end
    local input = lib.inputDialog(('Impound • %s'):format(plate), {
        { type = 'input', label = 'Reason', placeholder = 'Impounded by police', max = 100 },
    })
    if not input then return end
    if not lib.progressBar({ duration = 5000, label = 'Impounding vehicle...', canCancel = true,
        disable = { move = true, combat = true, car = true } }) then return notify('Cancelled.', 'error') end
    local ok, msg = lib.callback.await('rps_parking:impound', false, VehToNet(veh), input[1] or '')
    notify(msg, ok and 'success' or 'error')
end

local function CanPolice(entity)
    return isPolice and entity and DoesEntityExist(entity) and Entity(entity).state.parked ~= nil
end

local PoliceOptions = {
    {
        name = 'rps_parking_ticket', icon = 'fas fa-file-invoice-dollar', label = 'Write parking ticket',
        canInteract = function(entity) return CanPolice(entity) end,
        onSelect = function(data) CreateThread(function() TicketVehicle(data.entity) end) end,
    },
    {
        name = 'rps_parking_impound', icon = 'fas fa-truck-pickup', label = 'Impound vehicle',
        canInteract = function(entity) return CanPolice(entity) end,
        onSelect = function(data) CreateThread(function() ImpoundVehicle(data.entity) end) end,
    },
}

CreateThread(function()
    Wait(1000) -- rps_lib detects the target script asynchronously
    policeUseTarget = exports.rps_lib:GetTargetName() ~= 'none'
end)

-- adds the police options to parked cars as they stream in, removes them when gone / unparked
local function SyncPoliceTargets(parkedNow)
    if not policeUseTarget then return end
    for veh in pairs(parkedNow) do
        if not policeTargets[veh] then
            exports.rps_lib:AddEntityTarget(veh, PoliceOptions, 2.5)
            policeTargets[veh] = true
        end
    end
    for veh in pairs(policeTargets) do
        if not parkedNow[veh] then
            if DoesEntityExist(veh) then exports.rps_lib:RemoveEntityTarget(veh, PoliceOptions) end
            policeTargets[veh] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Apply saved properties to (re)spawned vehicles + collect 3D text targets
---------------------------------------------------------------------------
CreateThread(function()
    while true do
        local myId = PlayerId()
        local pcoords = GetEntityCoords(PlayerPedId())
        local found, parkedNow = {}, {}

        for _, veh in ipairs(GetGamePool('CVehicle')) do
            local st = Entity(veh).state
            if st.parkProps and st.propsApplied == false and NetworkGetEntityOwner(veh) == myId then
                lib.setVehicleProperties(veh, st.parkProps)
                st:set('propsApplied', true, true)
            end
            if st.parked then
                parkedNow[veh] = true
                if Config.Show3DText and #(pcoords - GetEntityCoords(veh)) < 12.0 then
                    found[#found + 1] = veh
                end
            end
        end

        nearbyParked = found
        SyncPoliceTargets(parkedNow)
        Wait(1500)
    end
end)

if Config.Show3DText then
    CreateThread(function()
        while true do
            if #nearbyParked > 0 then
                for _, veh in ipairs(nearbyParked) do
                    if DoesEntityExist(veh) then
                        local c = GetEntityCoords(veh)
                        DrawText3D(c.x, c.y, c.z + 1.0, ('~b~PARKED~s~ | %s'):format(Entity(veh).state.parked or ''))
                    end
                end
                Wait(0)
            else
                Wait(500)
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Park
---------------------------------------------------------------------------
local function ParkVehicle(veh)
    local ped = PlayerPedId()
    if GetPedInVehicleSeat(veh, -1) ~= ped then return notify('You must be the driver.', 'error') end
    if GetEntitySpeed(veh) > Config.MaxParkSpeed then return notify('Stop the vehicle first.', 'error') end
    if not NetworkGetEntityIsNetworked(veh) then return notify('This vehicle cannot be parked.', 'error') end

    SetVehicleEngineOn(veh, false, true, true)
    if not lib.progressBar({
        duration = Config.ParkTime, label = 'Parking vehicle...', canCancel = true,
        disable = { car = true, move = true, combat = true },
    }) then return notify('Cancelled.', 'error') end

    local props = lib.getVehicleProperties(veh)
    local ok, msg = lib.callback.await('rps_parking:park', false, VehToNet(veh), props)
    notify(msg, ok and 'success' or 'error')
    if ok then TaskLeaveVehicle(ped, veh, 0) end
end

-- The lot the player is currently driving in (nil outside every lot)
local currentLot
local parkHintShown = false

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local lot
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            local c = GetEntityCoords(veh)
            for _, l in ipairs(Config.ParkingLots) do
                if LotUtil.InLot(l, c) then lot = l break end
            end
        end
        currentLot = lot

        local showHint = lot ~= nil and not busy and not ParkingEditorActive
        if showHint and not parkHintShown then
            lib.showTextUI(('[%s] Park vehicle – %s'):format(Config.ParkKey, lot.label), { icon = 'square-parking' })
            parkHintShown = true
        elseif not showHint and parkHintShown then
            lib.hideTextUI()
            parkHintShown = false
        end
        Wait(500)
    end
end)

-- Park only — unparking is done at the lot's parking machine
-- silent = true for the key: outside a parking lot the key does nothing
local function DoPark(silent)
    if busy or ParkingEditorActive then return end
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh == 0 then return end -- on foot: E stays free for other interactions
    if not currentLot then
        if not silent then notify('You are not in a parking lot.', 'error') end
        return
    end
    busy = true
    ParkVehicle(veh)
    busy = false
end

RegisterCommand('parktoggle', function() DoPark(true) end, false)
RegisterKeyMapping('parktoggle', 'Park vehicle (inside a parking lot)', 'keyboard', Config.ParkKey)
RegisterCommand('park', function() DoPark(false) end, false)

---------------------------------------------------------------------------
-- Parking machine (prop + target) — lists your cars parked at that lot
---------------------------------------------------------------------------
-- Red arrow above your car after unparking – until you get in it (or 2 minutes pass)
local arrowToken = 0
local function ShowCarArrow(where)
    arrowToken = arrowToken + 1
    local token = arrowToken
    CreateThread(function()
        local endAt = GetGameTimer() + 120000
        local height
        while token == arrowToken and GetGameTimer() < endAt do
            local ped = PlayerPedId()
            local veh = NetworkDoesNetworkIdExist(where.netId) and NetToVeh(where.netId) or 0
            local c
            if veh ~= 0 and DoesEntityExist(veh) then
                if GetVehiclePedIsIn(ped, false) == veh then break end
                if not height then
                    local _, max = GetModelDimensions(GetEntityModel(veh))
                    height = max.z
                end
                c = GetEntityCoords(veh)
            else
                c = vec3(where.x, where.y, where.z) -- car not streamed in yet: use its bay
            end
            DrawMarker(2, c.x, c.y, c.z + (height or 1.0) + 1.2, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0,
                0.8, 0.8, 0.8, 230, 40, 40, 220, true, false, 2, true, nil, nil, false)
            Wait(0)
        end
    end)
end

local function UnparkAtMachine(lot, v)
    if v.total > 0 then
        local res = lib.alertDialog({
            header = ('Pay for %s?'):format(v.plate),
            content = ('Parking: $%d  \nFines: $%d  \n\n**Total: $%d**'):format(v.parking, v.fines, v.total),
            centered = true, cancel = true,
        })
        if res ~= 'confirm' then return end
    end

    if not lib.progressBar({
        duration = Config.ParkTime, label = 'Paying at machine...', canCancel = true,
        disable = { move = true, car = true, combat = true },
    }) then return notify('Cancelled.', 'error') end

    local ok, msg, where = lib.callback.await('rps_parking:unpark', false, lot.name, v.plate)
    notify(msg, ok and 'success' or 'error')
    if ok and where then ShowCarArrow(where) end
end

local function OpenMachine(lot)
    local list = lib.callback.await('rps_parking:getAtLot', false, lot.name)
    if not list then return notify('You must be at the parking machine.', 'error') end

    local options = {}
    if #list == 0 then
        options[1] = { title = 'No vehicles parked here', description = 'You have no cars parked at this lot.', icon = 'circle-info', disabled = true }
    end
    for _, v in ipairs(list) do
        local h, m = math.floor(v.minutes / 60), v.minutes % 60
        options[#options + 1] = {
            title = ('%s [%s]'):format(ModelLabel(v.model), v.plate),
            description = ('Bay %d • %dh %02dm • Due: $%d%s'):format(v.spot or 0, h, m, v.total,
                v.fines > 0 and (' (incl. $%d fines)'):format(v.fines) or ''),
            icon = 'car',
            arrow = true,
            onSelect = function() UnparkAtMachine(lot, v) end,
        }
    end

    local price = (lot.pricePerHour or 0) > 0 and ('$%d/hr, max $%d'):format(lot.pricePerHour, lot.maxFee or 0) or 'Free'
    lib.registerContext({ id = 'rps_parking_machine', title = ('%s (%s)'):format(lot.label, price), options = options })
    lib.showContext('rps_parking_machine')
end

local machineProps, machineZones, machinePoints = {}, {}, {}
local useTarget -- nil until rps_lib has detected the target script
local textShownMachine = false

local function SpawnMachine(lot)
    local m, cfg = lot.machine, Config.ParkingMachine
    local model = lib.requestModel(cfg.model)
    local obj = CreateObject(model, m.x, m.y, m.z, false, false, false)
    SetEntityHeading(obj, m.w)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityInvincible(obj, true)
    SetModelAsNoLongerNeeded(model)
    machineProps[lot.name] = obj
end

local function DeleteMachine(name)
    local obj = machineProps[name]
    if obj and DoesEntityExist(obj) then DeleteEntity(obj) end
    machineProps[name] = nil
end

local function ClearMachines()
    for name in pairs(machineProps) do DeleteMachine(name) end
    for _, p in ipairs(machinePoints) do p:remove() end
    for _, id in ipairs(machineZones) do exports.rps_lib:RemoveZone(id) end
    machinePoints, machineZones = {}, {}
    if textShownMachine then lib.hideTextUI(); textShownMachine = false end
end

local function AddTextUIFallback(lot)
    local m = lot.machine
    machinePoints[#machinePoints + 1] = lib.points.new({
        coords = vec3(m.x, m.y, m.z), distance = Config.ParkingMachine.distance,
        nearby = function()
            if not textShownMachine then lib.showTextUI(('[E] %s'):format(Config.ParkingMachine.label)); textShownMachine = true end
            if IsControlJustReleased(0, 38) and not IsPedInAnyVehicle(PlayerPedId(), false) then
                CreateThread(function() OpenMachine(lot) end)
            end
        end,
        onExit = function() if textShownMachine then lib.hideTextUI(); textShownMachine = false end end,
    })
end

local function BuildMachines()
    if useTarget == nil then return end
    ClearMachines()
    local cfg = Config.ParkingMachine
    for _, lot in ipairs(Config.ParkingLots) do
        local m = lot.machine
        if m then
            -- prop only exists while you're near the lot
            machinePoints[#machinePoints + 1] = lib.points.new({
                coords = vec3(m.x, m.y, m.z), distance = 80.0,
                onEnter = function() SpawnMachine(lot) end,
                onExit = function() DeleteMachine(lot.name) end,
            })
            if useTarget then
                machineZones[#machineZones + 1] = exports.rps_lib:AddBoxZone(('rps_parking_machine_%s'):format(lot.name),
                    vec3(m.x, m.y, m.z + 0.5), 1.0, 1.0, m.w, {
                        {
                            name = ('rps_parking_machine_%s'):format(lot.name),
                            icon = cfg.icon, label = cfg.label,
                            onSelect = function() CreateThread(function() OpenMachine(lot) end) end,
                        },
                    }, cfg.distance)
            else
                AddTextUIFallback(lot)
            end
        end
    end
end

CreateThread(function()
    Wait(1000) -- rps_lib detects the target script asynchronously
    useTarget = exports.rps_lib:GetTargetName() ~= 'none'
    BuildMachines()
end)

AddEventHandler('rps_parking:lotsChanged', BuildMachines)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    ClearMachines()
    if parkHintShown then lib.hideTextUI() end
    for veh in pairs(policeTargets) do
        if DoesEntityExist(veh) then exports.rps_lib:RemoveEntityTarget(veh, PoliceOptions) end
    end
end)

---------------------------------------------------------------------------
-- My parked vehicles
---------------------------------------------------------------------------
RegisterCommand('parked', function()
    local list = lib.callback.await('rps_parking:getMine', false)
    if not list or #list == 0 then return notify('You have no parked vehicles.') end

    local options = {}
    for _, v in ipairs(list) do
        options[#options + 1] = {
            title = ('%s [%s]'):format(ModelLabel(v.model), v.plate),
            description = ('%s • Due: $%d%s'):format(v.zone, v.due, v.fines > 0 and (' (incl. $%d fines)'):format(v.fines) or ''),
            icon = 'car',
            onSelect = function()
                SetNewWaypoint(v.x, v.y)
                notify(('Waypoint set to %s.'):format(v.plate), 'success')
            end,
        }
    end
    lib.registerContext({ id = 'rps_parking_list', title = 'My Parked Vehicles', options = options })
    lib.showContext('rps_parking_list')
end, false)

TriggerEvent('chat:addSuggestion', '/park', 'Park your vehicle in the bay you are standing in')
TriggerEvent('chat:addSuggestion', '/parked', 'List your parked vehicles')

---------------------------------------------------------------------------
-- Impound lot
---------------------------------------------------------------------------
local function OpenImpound()
    local list = lib.callback.await('rps_parking:getImpounded', false)
    if not list or #list == 0 then return notify('You have no impounded vehicles.') end

    local options = {}
    for _, v in ipairs(list) do
        options[#options + 1] = {
            title = ('%s [%s]'):format(ModelLabel(v.model), v.plate),
            description = ('Reason: %s • Release fee: $%d'):format(v.reason, v.due),
            icon = 'truck-pickup',
            onSelect = function()
                local res = lib.alertDialog({
                    header = 'Release vehicle', centered = true, cancel = true,
                    content = ('Pay **$%d** to release %s?'):format(v.due, v.plate),
                })
                if res ~= 'confirm' then return end
                local ok, msg = lib.callback.await('rps_parking:retrieve', false, v.plate)
                notify(msg, ok and 'success' or 'error')
            end,
        }
    end
    lib.registerContext({ id = 'rps_parking_impound', title = 'Impound Lot', options = options })
    lib.showContext('rps_parking_impound')
end

local textShown = false
lib.points.new({
    coords = Config.Impound.coords,
    distance = 15.0,
    nearby = function(self)
        local c = self.coords
        DrawMarker(36, c.x, c.y, c.z + 0.2, 0, 0, 0, 0, 0, 0, 0.8, 0.8, 0.8, 60, 150, 255, 180, true, true, 2, false, nil, nil, false)
        if self.currentDistance < 2.0 then
            if not textShown then lib.showTextUI('[E] Impound Lot'); textShown = true end
            if IsControlJustReleased(0, 38) then OpenImpound() end
        elseif textShown then
            lib.hideTextUI(); textShown = false
        end
    end,
    onExit = function()
        if textShown then lib.hideTextUI(); textShown = false end
    end,
})

---------------------------------------------------------------------------
-- Blips
---------------------------------------------------------------------------
local function CreateBlip(coords, sprite, color, label)
    local b = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(b, sprite)
    SetBlipColour(b, color)
    SetBlipScale(b, 0.7)
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(b)
    return b
end

local lotBlips = {}
local function BuildBlips()
    for _, b in ipairs(lotBlips) do RemoveBlip(b) end
    lotBlips = {}
    for _, lot in ipairs(Config.ParkingLots) do
        if lot.blip then
            local price = (lot.pricePerHour or 0) > 0 and ('$%d/hr'):format(lot.pricePerHour) or 'Free'
            lotBlips[#lotBlips + 1] = CreateBlip(lot.coords, 357, 3, ('%s (%s, %d bays)'):format(lot.label, price, #lot.spots))
        end
    end
end

CreateThread(function()
    BuildBlips()
    if Config.Impound.blip then CreateBlip(Config.Impound.coords, 68, 1, 'Impound Lot') end
end)
AddEventHandler('rps_parking:lotsChanged', BuildBlips)

---------------------------------------------------------------------------
-- Parking bay markers (green = free, red = taken) while driving near a lot
---------------------------------------------------------------------------
local nearLots = {}

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local found = {}
        if IsPedInAnyVehicle(ped, false) then
            local c = GetEntityCoords(ped)
            for _, lot in ipairs(Config.ParkingLots) do
                if #(c - lot.coords) < lot.radius + Config.MarkerDistance then found[#found + 1] = lot end
            end
        end
        nearLots = found
        Wait(500)
    end
end)

CreateThread(function()
    local free, taken = Config.MarkerFree, Config.MarkerTaken
    while true do
        if #nearLots > 0 then
            local occupied = GlobalState.rps_parking_taken or {}
            for _, lot in ipairs(nearLots) do
                for i, s in ipairs(lot.spots) do
                    local col = occupied[('%s:%d'):format(lot.name, i)] and taken or free
                    -- flat bay outline
                    DrawMarker(1, s.x, s.y, s.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, s.w,
                        2.4, 4.6, 0.25, col.r, col.g, col.b, col.a, false, false, 2, false, nil, nil, false)
                    -- direction arrow
                    DrawMarker(2, s.x, s.y, s.z + 0.3, 0.0, 0.0, 0.0, 90.0, s.w, 0.0,
                        0.6, 0.6, 0.6, col.r, col.g, col.b, 180, false, false, 2, false, nil, nil, false)
                end
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

---------------------------------------------------------------------------
-- Dev tool: print current vehicle position as a parking bay
---------------------------------------------------------------------------
if Config.EnableSpotTool then
    RegisterCommand('parkspot', function()
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local ent = veh ~= 0 and veh or ped
        local c, h = GetEntityCoords(ent), GetEntityHeading(ent)
        local line = ('vec4(%.2f, %.2f, %.2f, %.1f),'):format(c.x, c.y, c.z, h)
        print(line)
        notify(('Bay printed to F8: %s'):format(line), 'success')
    end, false)
end
