local Parked = {}        -- [plate] = data (live, non-impounded)
local ImpoundParked      -- defined in the police section
local Occupied = {}      -- ["lot:spot"] = plate
local LotsByName = {}

-- Rebuilds the lookup + sends every lot to the clients (GlobalState)
local function PublishLots()
    local encoded = {}
    for k in pairs(LotsByName) do LotsByName[k] = nil end
    for _, lot in ipairs(Config.ParkingLots) do
        LotsByName[lot.name] = lot
        encoded[#encoded + 1] = LotUtil.Encode(lot)
    end
    GlobalState.rps_parking_lots = encoded
end

---------------------------------------------------------------------------
-- Parking lots are stored in the `ParkingLots` table (edit them in-game: /parkadmin -> Lot editor)
---------------------------------------------------------------------------
local function jsonOrNil(v) return v and json.encode(v) or nil end
local function decodeJson(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok, v = pcall(json.decode, s)
    return ok and v or nil
end

local function SaveLotRow(lot)
    local e = LotUtil.Encode(lot)
    MySQL.query.await([[
        INSERT INTO ParkingLots (name, label, price_per_hour, max_fee, blip, coords, radius, machine, zone, spots)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE label = VALUES(label), price_per_hour = VALUES(price_per_hour), max_fee = VALUES(max_fee),
            blip = VALUES(blip), coords = VALUES(coords), radius = VALUES(radius), machine = VALUES(machine),
            zone = VALUES(zone), spots = VALUES(spots)
    ]], { e.name, e.label, e.pricePerHour, e.maxFee, e.blip and 1 or 0, jsonOrNil(e.coords), e.radius,
        jsonOrNil(e.machine), jsonOrNil(e.zone), json.encode(e.spots) })
end

local function RowToLot(r)
    return LotUtil.Decode({
        name = r.name, label = r.label, pricePerHour = r.price_per_hour, maxFee = r.max_fee,
        blip = r.blip == true or tonumber(r.blip) == 1,
        coords = decodeJson(r.coords), radius = r.radius, machine = decodeJson(r.machine),
        zone = decodeJson(r.zone), spots = decodeJson(r.spots) or {},
    })
end

-- Inserted once when the table is empty (the old config.lua lots)
local SEED_LOTS = {
    {
        name = 'legion', label = 'Legion Square Parking', pricePerHour = 25, maxFee = 300, blip = true,
        coords = { 228.0, -790.0, 30.6 }, radius = 50.0,
        machine = { 214.5374, -807.0289, 30.8034, 152.7073 },
        spots = {
            { 222.02, -804.19, 30.26, 248.5 }, { 223.93, -799.11, 30.26, 248.5 }, { 226.46, -794.33, 30.26, 248.5 },
            { 228.20, -789.40, 30.26, 248.5 }, { 230.10, -784.50, 30.26, 248.5 }, { 232.10, -779.60, 30.26, 248.5 },
        },
    },
    {
        name = 'pier', label = 'Del Perro Pier Parking', pricePerHour = 0, maxFee = 0, blip = true,
        coords = { -1637.0, -905.0, 8.6 }, radius = 45.0,
        machine = { -1634.50, -897.00, 8.60, 140.0 },
        spots = {
            { -1645.0, -895.0, 8.6, 320.0 }, { -1642.8, -893.2, 8.6, 320.0 },
            { -1640.6, -891.4, 8.6, 320.0 }, { -1638.4, -889.6, 8.6, 320.0 },
        },
    },
}

local function LoadLots()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `ParkingLots` (
            `name` VARCHAR(50) NOT NULL,
            `label` VARCHAR(60) NOT NULL,
            `price_per_hour` INT NOT NULL DEFAULT 0,
            `max_fee` INT NOT NULL DEFAULT 0,
            `blip` TINYINT NOT NULL DEFAULT 1,
            `coords` VARCHAR(100) DEFAULT NULL,
            `radius` FLOAT DEFAULT NULL,
            `machine` VARCHAR(100) DEFAULT NULL,
            `zone` LONGTEXT DEFAULT NULL,
            `spots` LONGTEXT NOT NULL,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`name`)
        )
    ]])

    if (tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM ParkingLots')) or 0) == 0 then
        local seeds = {}
        for _, t in ipairs(SEED_LOTS) do seeds[t.name] = t end

        -- carry over lots saved by the previous editor version (parking_lots table)
        local hasOld = (tonumber(MySQL.scalar.await([[
            SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'parking_lots'
        ]])) or 0) > 0
        if hasOld then
            for _, row in ipairs(MySQL.query.await('SELECT name, data FROM parking_lots') or {}) do
                local t = decodeJson(row.data)
                if t and t.deleted then seeds[row.name] = nil
                elseif t then seeds[row.name] = t end
            end
        end

        local n = 0
        for name, t in pairs(seeds) do
            local lot, err = LotUtil.Decode(t)
            if lot then SaveLotRow(lot); n = n + 1
            else print(('^1[rps_parking] Could not import lot "%s": %s^0'):format(name, err)) end
        end
        print(('[rps_parking] ParkingLots table created with %d lots%s'):format(n, hasOld and ' (imported from parking_lots)' or ''))
    end

    local lots = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM ParkingLots ORDER BY label') or {}) do
        local lot, err = RowToLot(r)
        if lot then lots[#lots + 1] = lot
        else print(('^1[rps_parking] Lot "%s" in ParkingLots is invalid: %s^0'):format(r.name, err)) end
    end
    for i = #Config.ParkingLots, 1, -1 do Config.ParkingLots[i] = nil end
    for i, l in ipairs(lots) do Config.ParkingLots[i] = l end
    PublishLots()

    for _, lot in ipairs(Config.ParkingLots) do
        if not lot.machine then
            print(('^3[rps_parking] Lot "%s" has no machine set – players cannot unpark there.^0'):format(lot.name))
        end
    end
    print(('[rps_parking] Loaded %d parking lots'):format(#Config.ParkingLots))
end

local function trim(s) return (s:gsub('^%s*(.-)%s*$', '%1')) end
local function spotKey(lot, spot) return ('%s:%d'):format(lot, spot) end

local function notify(src, msg, t) Bridge.Notify(src, msg, t) end

-- Replicate taken bays to clients (for the red/green markers)
local function SyncOccupied()
    local taken = {}
    for k in pairs(Occupied) do taken[k] = true end
    GlobalState.rps_parking_taken = taken
end

local function SetOccupied(data, value)
    if data.zone and data.spot then
        Occupied[spotKey(data.zone, data.spot)] = value and data.plate or nil
        SyncOccupied()
    end
end

---------------------------------------------------------------------------
-- Logging (database + optional Discord)
---------------------------------------------------------------------------
local LogColors = { park = 3447003, unpark = 3066993, ticket = 15105570, impound = 15158332,
    retrieve = 10181046, expire = 9807270 }

local function SendWebhook(action, e, actorName)
    local url = Config.Logs.webhook
    if not url or url == '' then return end
    local key = action:sub(1, 6) == 'admin_' and 'admin' or action
    if not Config.Logs.webhookActions[key] then return end

    local fields = {
        { name = 'Plate', value = e.plate or '-', inline = true },
        { name = 'By', value = actorName, inline = true },
    }
    local lot = e.lot and LotsByName[e.lot]
    if lot then fields[#fields + 1] = { name = 'Location', value = e.spot and ('%s, bay %d'):format(lot.label, e.spot) or lot.label, inline = true } end
    if (e.amount or 0) + (e.fines or 0) > 0 then
        fields[#fields + 1] = { name = 'Amount', value = ('$%d (fines $%d)'):format((e.amount or 0) + (e.fines or 0), e.fines or 0), inline = true }
    end
    if e.details and e.details ~= '' then fields[#fields + 1] = { name = 'Details', value = e.details } end

    PerformHttpRequest(url, function() end, 'POST', json.encode({
        username = 'Parking Logs',
        embeds = { {
            title = action:upper():gsub('_', ' '),
            color = LogColors[action] or 16776960,
            fields = fields,
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        } },
    }), { ['Content-Type'] = 'application/json' })
end

-- e = { plate, src, owner, lot, spot, amount, fines, details }
local function Log(action, e)
    local actor, actorName = 'system', 'System'
    if e.src then
        actor = Bridge.GetIdentifier(e.src) or ('src:%d'):format(e.src)
        actorName = Bridge.GetName(e.src)
    end
    MySQL.insert(
        'INSERT INTO parking_logs (action, plate, actor, actor_name, owner, lot, spot, amount, fines, details) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { action, e.plate, actor, actorName, e.owner, e.lot, e.spot, e.amount or 0, e.fines or 0,
          e.details and tostring(e.details):sub(1, 255) or nil })
    SendWebhook(action, e, actorName)
end

local function IsVehicleEmpty(veh)
    for seat = -1, 14 do
        local p = GetPedInVehicleSeat(veh, seat)
        if p and p ~= 0 then return false end
    end
    return true
end

local function AngleDiff(a, b)
    local d = math.abs((a - b) % 360.0)
    return d > 180.0 and 360.0 - d or d
end

-- Finds the free bay the vehicle is standing in. Returns lot, spotIndex, snappedHeading | nil, reason
local function FindSpot(coords, heading)
    local nearLot = false
    for _, lot in ipairs(Config.ParkingLots) do
        if LotUtil.InLot(lot, coords) then
            nearLot = true
            for i, s in ipairs(lot.spots) do
                if #(coords.xy - s.xy) < Config.SpotRadius then
                    if Occupied[spotKey(lot.name, i)] then
                        return nil, 'This parking bay is already taken.'
                    end
                    local diff = AngleDiff(heading, s.w)
                    if diff <= Config.SpotMaxAngle then return lot, i, s.w end
                    if diff >= 180.0 - Config.SpotMaxAngle then return lot, i, (s.w + 180.0) % 360.0 end
                    return nil, 'Straighten your vehicle inside the bay.'
                end
            end
        end
    end
    if nearLot then return nil, 'Drive into a free (green) parking bay.' end
    return nil, 'You can only park inside a parking lot bay.'
end

-- returns total, parkingFee
local function CalculateFee(data)
    local parking = 0
    local lot = data.zone and LotsByName[data.zone]
    if lot and (lot.pricePerHour or 0) > 0 then
        local hours = math.max(1, math.ceil((os.time() - (data.parked_ts or os.time())) / 3600))
        parking = hours * lot.pricePerHour
        if lot.maxFee and lot.maxFee > 0 then parking = math.min(parking, lot.maxFee) end
    end
    return parking + (data.fines or 0), parking
end

local function ApplyParkedState(veh, data, propsAlreadyApplied)
    SetVehicleNumberPlateText(veh, data.plate)
    SetVehicleDoorsLocked(veh, 2)
    if Config.SnapToSpot then
        SetEntityCoords(veh, data.x, data.y, data.z, false, false, false, false)
        SetEntityHeading(veh, data.heading)
    end
    if Config.FreezeParked then FreezeEntityPosition(veh, true) end
    if SetEntityOrphanMode then SetEntityOrphanMode(veh, 2) end

    local st = Entity(veh).state
    st:set('parked', data.plate, true)
    st:set('parkProps', data.props, true)
    st:set('propsApplied', propsAlreadyApplied == true, true)
    data.entity = veh
end

local function ReleaseVehicle(veh)
    local st = Entity(veh).state
    st:set('parked', nil, true)
    st:set('parkProps', nil, true)
    st:set('propsApplied', nil, true)
    SetVehicleDoorsLocked(veh, 1)
    FreezeEntityPosition(veh, false)
    if SetEntityOrphanMode then SetEntityOrphanMode(veh, 0) end
end

local function SpawnVehicle(model, vtype, x, y, z, h)
    local veh = CreateVehicleServerSetter(model, vtype or 'automobile', x, y, z, h)
    local timeout = GetGameTimer() + 5000
    while not DoesEntityExist(veh) do
        if GetGameTimer() > timeout then return nil end
        Wait(0)
    end
    return veh
end

local function SpawnParked(data)
    local veh = SpawnVehicle(data.model, data.vtype, data.x, data.y, data.z, data.heading)
    if not veh then
        print(('[rps_parking] Failed to spawn parked vehicle %s'):format(data.plate))
        return false
    end
    ApplyParkedState(veh, data, false)
    return true
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `advanced_parking` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `plate` VARCHAR(12) NOT NULL,
            `owner` VARCHAR(64) NOT NULL,
            `model` BIGINT NOT NULL,
            `vtype` VARCHAR(20) NOT NULL DEFAULT 'automobile',
            `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL, `heading` FLOAT NOT NULL,
            `props` LONGTEXT NOT NULL,
            `owner_name` VARCHAR(100) DEFAULT NULL,
            `zone` VARCHAR(50) DEFAULT NULL,
            `spot` INT DEFAULT NULL,
            `fines` INT NOT NULL DEFAULT 0,
            `impounded` TINYINT NOT NULL DEFAULT 0,
            `impound_reason` VARCHAR(255) DEFAULT NULL,
            `parked_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), UNIQUE KEY `plate` (`plate`), KEY `owner` (`owner`)
        )
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `parking_logs` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `action` VARCHAR(20) NOT NULL,
            `plate` VARCHAR(12) DEFAULT NULL,
            `actor` VARCHAR(64) NOT NULL DEFAULT 'system',
            `actor_name` VARCHAR(100) DEFAULT NULL,
            `owner` VARCHAR(64) DEFAULT NULL,
            `lot` VARCHAR(50) DEFAULT NULL,
            `spot` INT DEFAULT NULL,
            `amount` INT NOT NULL DEFAULT 0,
            `fines` INT NOT NULL DEFAULT 0,
            `details` VARCHAR(255) DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), KEY `plate` (`plate`), KEY `action_time` (`action`, `created_at`), KEY `created_at` (`created_at`)
        )
    ]])

    LoadLots()

    -- migrate older versions
    local function EnsureColumn(column, ddl)
        local has = MySQL.scalar.await([[
            SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'advanced_parking' AND COLUMN_NAME = ?
        ]], { column })
        if has == 0 then
            MySQL.query.await(('ALTER TABLE advanced_parking ADD COLUMN %s'):format(ddl))
            print(('[rps_parking] Database migrated (added %s column)'):format(column))
        end
    end
    EnsureColumn('spot', '`spot` INT DEFAULT NULL AFTER `zone`')
    EnsureColumn('owner_name', '`owner_name` VARCHAR(100) DEFAULT NULL AFTER `props`')

    if (Config.Logs.retentionDays or 0) > 0 then
        MySQL.update.await('DELETE FROM parking_logs WHERE created_at < (NOW() - INTERVAL ? DAY)', { Config.Logs.retentionDays })
    end

    local toExpire = MySQL.query.await(
        'SELECT plate, owner, zone, spot FROM advanced_parking WHERE impounded = 0 AND parked_at < (NOW() - INTERVAL ? DAY)',
        { Config.MaxParkDays }) or {}
    if #toExpire > 0 then
        MySQL.update.await(
            'UPDATE advanced_parking SET impounded = 1, impound_reason = ? WHERE impounded = 0 AND parked_at < (NOW() - INTERVAL ? DAY)',
            { 'Abandoned vehicle (parked too long)', Config.MaxParkDays })
        for _, r in ipairs(toExpire) do
            Log('expire', { plate = r.plate, owner = r.owner, lot = r.zone, spot = r.spot,
                details = ('Parked longer than %d days'):format(Config.MaxParkDays) })
        end
        print(('[rps_parking] Auto-impounded %d abandoned vehicles'):format(#toExpire))
    end

    local rows = MySQL.query.await('SELECT *, UNIX_TIMESTAMP(parked_at) AS parked_ts FROM advanced_parking WHERE impounded = 0') or {}
    for _, row in ipairs(rows) do
        row.props = json.decode(row.props) or {}
        Parked[row.plate] = row
        if row.zone and row.spot then Occupied[spotKey(row.zone, row.spot)] = row.plate end
        SpawnParked(row)
        Wait(50)
    end
    SyncOccupied()
    print(('[rps_parking] Loaded %d parked vehicles'):format(#rows))

    -- Watchdog: respawn parked vehicles that got deleted
    while true do
        Wait(Config.RespawnInterval * 1000)
        for plate, data in pairs(Parked) do
            if not data.busy then
                local veh = data.entity
                if not veh or not DoesEntityExist(veh) or Entity(veh).state.parked ~= plate then
                    SpawnParked(data)
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, data in pairs(Parked) do
        if data.entity and DoesEntityExist(data.entity) then DeleteEntity(data.entity) end
    end
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function GetParkedFromNet(src, netId, maxDist)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil, 'Vehicle not found.' end
    local plate = Entity(veh).state.parked
    local data = plate and Parked[plate]
    if not data then return nil, 'This vehicle is not parked.' end
    local dist = #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(veh))
    if dist > (maxDist or Config.UnparkDistance) + 2.0 then return nil, 'You are too far away.' end
    return data, veh
end

local function LotLabel(data)
    local lot = data.zone and LotsByName[data.zone]
    if not lot then return 'Unknown location' end
    return data.spot and ('%s • Bay %d'):format(lot.label, data.spot) or lot.label
end

---------------------------------------------------------------------------
-- Park
---------------------------------------------------------------------------
lib.callback.register('rps_parking:park', function(src, netId, props)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false, 'Vehicle not found.' end

    local ped = GetPlayerPed(src)
    if GetPedInVehicleSeat(veh, -1) ~= ped then return false, 'You must be the driver.' end
    if #GetEntityVelocity(veh) > Config.MaxParkSpeed then return false, 'Stop the vehicle first.' end
    if type(props) ~= 'table' or #json.encode(props) > 30000 then return false, 'Invalid vehicle data.' end

    local plate = trim(GetVehicleNumberPlateText(veh))
    if Parked[plate] then return false, 'This vehicle is already parked.' end
    if MySQL.scalar.await('SELECT 1 FROM advanced_parking WHERE plate = ?', { plate }) then
        return false, 'This vehicle has an open parking record (check the impound).'
    end

    local coords = GetEntityCoords(veh)
    local lot, spot, snapHeading = FindSpot(coords, GetEntityHeading(veh))
    if not lot then return false, spot end

    if not Bridge.IsVehicleOwner(src, plate) then return false, 'You do not own this vehicle.' end
    local owner = Bridge.GetIdentifier(src)
    if not owner then return false, 'Player not loaded.' end

    local count = 0
    for _, d in pairs(Parked) do if d.owner == owner then count = count + 1 end end
    if count >= Config.MaxParkedPerPlayer then
        return false, ('You can only have %d vehicles parked.'):format(Config.MaxParkedPerPlayer)
    end

    props.plate = plate
    props.model = GetEntityModel(veh)

    local s = lot.spots[spot]
    local x, y, h = coords.x, coords.y, GetEntityHeading(veh)
    if Config.SnapToSpot then x, y, h = s.x, s.y, snapHeading end

    local data = {
        plate = plate, owner = owner, model = props.model, vtype = GetVehicleType(veh) or 'automobile',
        x = x, y = y, z = coords.z, heading = h,
        props = props, zone = lot.name, spot = spot, fines = 0, parked_ts = os.time(), busy = true,
        owner_name = Bridge.GetName(src),
    }

    MySQL.insert.await(
        'INSERT INTO advanced_parking (plate, owner, owner_name, model, vtype, x, y, z, heading, props, zone, spot) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { plate, owner, data.owner_name, data.model, data.vtype, data.x, data.y, data.z, data.heading, json.encode(props), lot.name, spot })
    Log('park', { plate = plate, src = src, owner = owner, lot = lot.name, spot = spot })

    Parked[plate] = data
    data.entity = veh
    SetOccupied(data, true)

    CreateThread(function()
        local timeout = GetGameTimer() + 10000
        while DoesEntityExist(veh) and not IsVehicleEmpty(veh) and GetGameTimer() < timeout do Wait(250) end
        if DoesEntityExist(veh) then ApplyParkedState(veh, data, true) end
        data.busy = false
    end)

    if (lot.pricePerHour or 0) > 0 then
        return true, ('Parked in %s, bay %d ($%d/hr, max $%d).'):format(lot.label, spot, lot.pricePerHour, lot.maxFee or 0)
    end
    return true, ('Parked in %s, bay %d (free).'):format(lot.label, spot)
end)

---------------------------------------------------------------------------
-- Unpark (only at a lot's parking machine)
---------------------------------------------------------------------------
local function AtMachine(src, lot)
    local m = lot and lot.machine
    if not m then return false end
    return #(GetEntityCoords(GetPlayerPed(src)) - vec3(m.x, m.y, m.z)) <= Config.ParkingMachine.distance + 3.0
end

-- Your cars parked at this lot
lib.callback.register('rps_parking:getAtLot', function(src, lotName)
    local lot = LotsByName[lotName]
    if not AtMachine(src, lot) then return nil end
    local owner = Bridge.GetIdentifier(src)
    local list = {}
    for _, d in pairs(Parked) do
        if d.owner == owner and d.zone == lotName then
            local total, parking = CalculateFee(d)
            list[#list + 1] = {
                plate = d.plate, model = d.model, spot = d.spot, x = d.x, y = d.y,
                total = total, parking = parking, fines = d.fines or 0,
                minutes = math.floor((os.time() - (d.parked_ts or os.time())) / 60),
            }
        end
    end
    table.sort(list, function(a, b) return (a.spot or 0) < (b.spot or 0) end)
    return list
end)

lib.callback.register('rps_parking:unpark', function(src, lotName, plate)
    local lot = LotsByName[lotName]
    if not AtMachine(src, lot) then return false, 'You must be at the parking machine.' end
    local data = type(plate) == 'string' and Parked[plate]
    if not data or data.zone ~= lotName then return false, 'That vehicle is not parked here.' end
    if data.busy then return false, 'Please wait a moment.' end
    if Bridge.GetIdentifier(src) ~= data.owner then return false, 'This is not your vehicle.' end

    data.busy = true
    local veh = data.entity
    if not veh or not DoesEntityExist(veh) then
        if not SpawnParked(data) then
            data.busy = false
            return false, 'Your vehicle could not be found. Try again in a moment.'
        end
        veh = data.entity
        -- let the nearest client apply saved mods before the state bags are cleared
        local timeout = GetGameTimer() + 5000
        while DoesEntityExist(veh) and not Entity(veh).state.propsApplied and GetGameTimer() < timeout do Wait(100) end
    end

    local total, parking = CalculateFee(data)
    if not Bridge.RemoveMoney(src, total, 'parking-fees') then
        data.busy = false
        return false, ('You need $%d to pay your parking fees & fines.'):format(total)
    end

    MySQL.query.await('DELETE FROM advanced_parking WHERE plate = ?', { data.plate })
    Parked[data.plate] = nil
    SetOccupied(data, false)
    ReleaseVehicle(veh)
    Config.GiveKeys(src, data.plate, veh)
    Log('unpark', { plate = data.plate, src = src, owner = data.owner, lot = data.zone, spot = data.spot,
        amount = parking, fines = total - parking,
        details = ('Parked %d min'):format(math.floor((os.time() - (data.parked_ts or os.time())) / 60)) })

    -- 3rd value: the car's net id + position, so the client can point the player to it
    local where = { netId = NetworkGetNetworkIdFromEntity(veh), x = data.x, y = data.y, z = data.z }
    if total > 0 then return true, ('Paid $%d. Vehicle in bay %d unlocked.'):format(total, data.spot or 0), where end
    return true, ('Vehicle in bay %d unlocked.'):format(data.spot or 0), where
end)

---------------------------------------------------------------------------
-- My vehicles / impound
---------------------------------------------------------------------------
lib.callback.register('rps_parking:getMine', function(src)
    local owner = Bridge.GetIdentifier(src)
    local list = {}
    for _, d in pairs(Parked) do
        if d.owner == owner then
            list[#list + 1] = {
                plate = d.plate, model = d.model, x = d.x, y = d.y,
                zone = LotLabel(d), due = (CalculateFee(d)), fines = d.fines or 0,
            }
        end
    end
    return list
end)

lib.callback.register('rps_parking:getImpounded', function(src)
    local owner = Bridge.GetIdentifier(src)
    local rows = MySQL.query.await(
        'SELECT *, UNIX_TIMESTAMP(parked_at) AS parked_ts FROM advanced_parking WHERE owner = ? AND impounded = 1', { owner }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = {
            plate = r.plate, model = r.model, reason = r.impound_reason or 'Unknown',
            due = Config.Impound.fee + (CalculateFee(r)),
        }
    end
    return list
end)

lib.callback.register('rps_parking:retrieve', function(src, plate)
    local ped = GetPlayerPed(src)
    if #(GetEntityCoords(ped) - Config.Impound.coords) > 5.0 then return false, 'You are not at the impound lot.' end

    local owner = Bridge.GetIdentifier(src)
    local row = MySQL.single.await(
        'SELECT *, UNIX_TIMESTAMP(parked_at) AS parked_ts FROM advanced_parking WHERE plate = ? AND owner = ? AND impounded = 1',
        { plate, owner })
    if not row then return false, 'Vehicle not found in the impound.' end

    local rowTotal, rowParking = CalculateFee(row)
    local total = Config.Impound.fee + rowTotal
    if not Bridge.RemoveMoney(src, total, 'impound-fees') then
        return false, ('You need $%d to release this vehicle.'):format(total)
    end
    Log('retrieve', { plate = row.plate, src = src, owner = row.owner, lot = row.zone, spot = row.spot,
        amount = Config.Impound.fee + rowParking, fines = rowTotal - rowParking, details = row.impound_reason })

    MySQL.query.await('DELETE FROM advanced_parking WHERE plate = ?', { plate })

    local s = Config.Impound.spawn
    local veh = SpawnVehicle(row.model, row.vtype, s.x, s.y, s.z, s.w)
    if not veh then return false, 'Failed to spawn vehicle, contact staff.' end

    SetVehicleNumberPlateText(veh, row.plate)
    local st = Entity(veh).state
    st:set('parkProps', json.decode(row.props), true)
    st:set('propsApplied', false, true)

    Wait(300)
    TaskWarpPedIntoVehicle(ped, veh, -1)
    Config.GiveKeys(src, row.plate, veh)
    return true, ('Paid $%d. Drive safe!'):format(total)
end)

---------------------------------------------------------------------------
-- Police
---------------------------------------------------------------------------
ImpoundParked = function(data, veh, reason, src, action)
    reason = reason:sub(1, 250)
    MySQL.update.await('UPDATE advanced_parking SET impounded = 1, impound_reason = ? WHERE plate = ?', { reason, data.plate })
    Parked[data.plate] = nil
    SetOccupied(data, false)
    if veh and DoesEntityExist(veh) then DeleteEntity(veh) end
    Log(action or 'impound', { plate = data.plate, src = src, owner = data.owner, lot = data.zone, spot = data.spot, details = reason })

    local ownerSrc = Bridge.FindPlayer(data.owner)
    if ownerSrc then notify(ownerSrc, ('Your vehicle %s was impounded: %s'):format(data.plate, reason), 'error') end
end

local function IsPolice(src) return Config.PoliceJobs[Bridge.GetJob(src) or ''] == true end

-- clients use this to show / hide the police target options on parked cars
lib.callback.register('rps_parking:isPolice', function(src) return IsPolice(src) end)

lib.callback.register('rps_parking:ticket', function(src, netId, amount, reason)
    if not IsPolice(src) then return false, 'You are not authorized.' end
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 or amount > Config.MaxTicket then return false, ('Amount must be 1 - %d.'):format(Config.MaxTicket) end

    local data, err = GetParkedFromNet(src, netId)
    if not data then return false, err end

    data.fines = (data.fines or 0) + amount
    MySQL.update.await('UPDATE advanced_parking SET fines = ? WHERE plate = ?', { data.fines, data.plate })
    Log('ticket', { plate = data.plate, src = src, owner = data.owner, lot = data.zone, spot = data.spot,
        fines = amount, details = (reason and reason ~= '') and reason or 'Parking violation' })

    local ownerSrc = Bridge.FindPlayer(data.owner)
    if ownerSrc then
        notify(ownerSrc, ('Your vehicle %s received a $%d ticket: %s'):format(data.plate, amount,
            (reason and reason ~= '') and reason or 'Parking violation'), 'warning')
    end
    return true, ('Ticketed %s for $%d.'):format(data.plate, amount)
end)

lib.callback.register('rps_parking:impound', function(src, netId, reason)
    if not IsPolice(src) then return false, 'You are not authorized.' end
    local data, veh = GetParkedFromNet(src, netId)
    if not data then return false, veh end
    if data.busy then return false, 'Please wait a moment.' end

    ImpoundParked(data, veh, (reason and reason ~= '') and reason or 'Impounded by police', src, 'impound')
    return true, ('Impounded %s.'):format(data.plate)
end)

---------------------------------------------------------------------------
-- Exports (for garages / car-wipe scripts)
---------------------------------------------------------------------------
exports('IsVehicleParked', function(plate) return Parked[trim(plate)] ~= nil end)
exports('GetParkedVehicle', function(plate)
    local d = Parked[trim(plate)]
    return d and { plate = d.plate, owner = d.owner, lot = d.zone, spot = d.spot, coords = vec3(d.x, d.y, d.z), entity = d.entity }
end)
exports('IsSpotTaken', function(lot, spot) return Occupied[spotKey(lot, spot)] ~= nil end)

---------------------------------------------------------------------------
-- Admin panel (logistics: stats, revenue, logs, management)
---------------------------------------------------------------------------
local function IsAdmin(src) return Bridge.IsAdmin(src) end
local function num(v) return math.floor(tonumber(v) or 0) end

local LOG_COLUMNS = [[action, plate, actor_name, owner, lot, spot, amount, fines, details,
    DATE_FORMAT(created_at, '%d %b %H:%i') AS time]]

lib.callback.register('rps_parking:admin:overview', function(src)
    if not IsAdmin(src) then return nil end

    local lots, lotIndex = {}, {}
    for _, lot in ipairs(Config.ParkingLots) do
        local entry = { name = lot.name, label = lot.label, total = #lot.spots, taken = 0,
            price = lot.pricePerHour or 0, week = 0, weekCount = 0, outstanding = 0 }
        for i in ipairs(lot.spots) do
            if Occupied[spotKey(lot.name, i)] then entry.taken = entry.taken + 1 end
        end
        lots[#lots + 1] = entry
        lotIndex[lot.name] = entry
    end

    local parked, outstanding = 0, 0
    for _, d in pairs(Parked) do
        parked = parked + 1
        local due = CalculateFee(d)
        outstanding = outstanding + due
        if lotIndex[d.zone] then lotIndex[d.zone].outstanding = lotIndex[d.zone].outstanding + due end
    end

    local rev = MySQL.single.await([[
        SELECT
            COALESCE(SUM(CASE WHEN created_at >= CURDATE() THEN amount + fines END), 0) AS today,
            COALESCE(SUM(CASE WHEN created_at >= NOW() - INTERVAL 7 DAY THEN amount + fines END), 0) AS week,
            COALESCE(SUM(amount + fines), 0) AS total
        FROM parking_logs WHERE action IN ('unpark', 'retrieve')
    ]]) or {}

    for _, r in ipairs(MySQL.query.await([[
        SELECT lot, SUM(amount + fines) AS rev, COUNT(*) AS n FROM parking_logs
        WHERE action = 'unpark' AND created_at >= NOW() - INTERVAL 7 DAY GROUP BY lot
    ]]) or {}) do
        if r.lot and lotIndex[r.lot] then
            lotIndex[r.lot].week = num(r.rev)
            lotIndex[r.lot].weekCount = num(r.n)
        end
    end

    local today = {}
    for _, r in ipairs(MySQL.query.await(
        'SELECT action, COUNT(*) AS n FROM parking_logs WHERE created_at >= CURDATE() GROUP BY action') or {}) do
        today[r.action] = num(r.n)
    end

    return {
        lots = lots,
        parked = parked,
        outstanding = outstanding,
        impounded = num(MySQL.scalar.await('SELECT COUNT(*) FROM advanced_parking WHERE impounded = 1')),
        revenue = { today = num(rev.today), week = num(rev.week), total = num(rev.total) },
        today = today,
        retention = Config.Logs.retentionDays or 0,
    }
end)

lib.callback.register('rps_parking:admin:lot', function(src, lotName)
    if not IsAdmin(src) then return nil end
    local lot = LotsByName[lotName]
    if not lot then return nil end

    local bays = {}
    for i in ipairs(lot.spots) do
        local plate = Occupied[spotKey(lot.name, i)]
        local d = plate and Parked[plate]
        if d then
            bays[i] = { spot = i, plate = plate, owner = d.owner_name or d.owner, model = d.model,
                minutes = math.floor((os.time() - (d.parked_ts or os.time())) / 60),
                due = (CalculateFee(d)), fines = d.fines or 0 }
        else
            bays[i] = { spot = i }
        end
    end
    return { label = lot.label, bays = bays }
end)

lib.callback.register('rps_parking:admin:vehicle', function(src, plate)
    if not IsAdmin(src) or type(plate) ~= 'string' then return nil end
    plate = trim(plate):upper()

    local info
    local d = Parked[plate]
    if d then
        local lot = LotsByName[d.zone]
        info = { status = 'parked', plate = plate, owner = d.owner_name or d.owner, model = d.model,
            location = lot and ('%s, bay %s'):format(lot.label, d.spot or '?') or 'Unknown',
            minutes = math.floor((os.time() - (d.parked_ts or os.time())) / 60),
            due = (CalculateFee(d)), fines = d.fines or 0 }
    else
        local row = MySQL.single.await(
            'SELECT *, UNIX_TIMESTAMP(parked_at) AS parked_ts FROM advanced_parking WHERE plate = ?', { plate })
        if row then
            info = { status = num(row.impounded) == 1 and 'impounded' or 'unknown', plate = plate,
                owner = row.owner_name or row.owner, model = row.model, reason = row.impound_reason,
                location = 'Impound lot', fines = row.fines or 0,
                due = Config.Impound.fee + (CalculateFee(row)) }
        end
    end

    local logs = MySQL.query.await(('SELECT %s FROM parking_logs WHERE plate = ? ORDER BY id DESC LIMIT 25'):format(LOG_COLUMNS), { plate }) or {}
    return { info = info, logs = logs }
end)

lib.callback.register('rps_parking:admin:logs', function(src, action)
    if not IsAdmin(src) then return nil end
    if action and action ~= 'all' then
        return MySQL.query.await(('SELECT %s FROM parking_logs WHERE action = ? ORDER BY id DESC LIMIT 40'):format(LOG_COLUMNS), { action }) or {}
    end
    return MySQL.query.await(('SELECT %s FROM parking_logs ORDER BY id DESC LIMIT 40'):format(LOG_COLUMNS)) or {}
end)

lib.callback.register('rps_parking:admin:impounded', function(src)
    if not IsAdmin(src) then return nil end
    return MySQL.query.await([[
        SELECT plate, model, COALESCE(owner_name, owner) AS owner, impound_reason AS reason, fines
        FROM advanced_parking WHERE impounded = 1 ORDER BY parked_at DESC LIMIT 60
    ]]) or {}
end)

lib.callback.register('rps_parking:admin:action', function(src, plate, action, arg)
    if not IsAdmin(src) or type(plate) ~= 'string' then return false, 'Not authorized.' end
    plate = trim(plate):upper()
    local d = Parked[plate]

    if action == 'teleport' then
        if not d then return false, 'Vehicle is not parked.' end
        return true, 'Teleported.', { x = d.x, y = d.y, z = d.z }
    end

    if action == 'release' then
        if not d then return false, 'Vehicle is not parked.' end
        if d.busy then return false, 'Vehicle is busy, try again.' end
        MySQL.query.await('DELETE FROM advanced_parking WHERE plate = ?', { plate })
        Parked[plate] = nil
        SetOccupied(d, false)
        if d.entity and DoesEntityExist(d.entity) then ReleaseVehicle(d.entity) end
        Log('admin_release', { plate = plate, src = src, owner = d.owner, lot = d.zone, spot = d.spot,
            details = arg and arg ~= '' and arg or 'Force unparked, fees waived' })
        local ownerSrc = Bridge.FindPlayer(d.owner)
        if ownerSrc then notify(ownerSrc, ('Your vehicle %s was unlocked by staff (fees waived).'):format(plate), 'inform') end
        return true, ('Released %s.'):format(plate)
    end

    if action == 'impound' then
        if not d then return false, 'Vehicle is not parked.' end
        if d.busy then return false, 'Vehicle is busy, try again.' end
        ImpoundParked(d, d.entity, (arg and arg ~= '') and arg or 'Impounded by staff', src, 'admin_impound')
        return true, ('Impounded %s.'):format(plate)
    end

    if action == 'clearfines' then
        local old
        if d then
            old = d.fines or 0
            d.fines = 0
        else
            old = num(MySQL.scalar.await('SELECT fines FROM advanced_parking WHERE plate = ?', { plate }))
        end
        MySQL.update.await('UPDATE advanced_parking SET fines = 0 WHERE plate = ?', { plate })
        Log('admin_waive', { plate = plate, src = src, owner = d and d.owner, lot = d and d.zone, spot = d and d.spot,
            details = ('Waived $%d in fines'):format(old) })
        return true, ('Cleared $%d in fines on %s.'):format(old, plate)
    end

    if action == 'delete' then
        if d then return false, 'Release or impound the parked vehicle first.' end
        local row = MySQL.single.await('SELECT owner, zone, spot FROM advanced_parking WHERE plate = ?', { plate })
        if not row then return false, 'No record for that plate.' end
        MySQL.query.await('DELETE FROM advanced_parking WHERE plate = ?', { plate })
        Log('admin_delete', { plate = plate, src = src, owner = row.owner, lot = row.zone, spot = row.spot,
            details = 'Impound record deleted' })
        return true, ('Deleted record for %s.'):format(plate)
    end

    return false, 'Unknown action.'
end)

---------------------------------------------------------------------------
-- Lot editor (create / edit / delete parking lots in-game)
---------------------------------------------------------------------------
local function LotIndex(name)
    for i, l in ipairs(Config.ParkingLots) do if l.name == name then return i end end
end

lib.callback.register('rps_parking:editor:canUse', function(src) return IsAdmin(src) end)

lib.callback.register('rps_parking:editor:save', function(src, encoded, isNew)
    if not IsAdmin(src) then return false, 'Not authorized.' end
    local lot, err = LotUtil.Decode(encoded)
    if not lot then return false, err end

    local idx = LotIndex(lot.name)
    if isNew and idx then return false, ('A lot named "%s" already exists.'):format(lot.name) end
    if not isNew and not idx then return false, 'That lot no longer exists.' end
    local old = idx and Config.ParkingLots[idx]

    -- Parked cars must keep their bay: find each one's bay in the new layout
    local remap = {}
    for plate, d in pairs(Parked) do
        if d.zone == lot.name then
            local s = old and d.spot and old.spots[d.spot]
            local newSpot
            if s then
                for j, n in ipairs(lot.spots) do
                    if #(n.xy - s.xy) < 0.75 then newSpot = j break end
                end
            end
            if not newSpot then
                return false, ('Bay %s has a parked car (%s). Release it before removing/moving that bay.'):format(d.spot or '?', plate)
            end
            if newSpot ~= d.spot then remap[#remap + 1] = { d = d, spot = newSpot } end
        end
    end

    SaveLotRow(lot)

    for _, r in ipairs(remap) do Occupied[spotKey(lot.name, r.d.spot)] = nil end
    for _, r in ipairs(remap) do
        r.d.spot = r.spot
        Occupied[spotKey(lot.name, r.spot)] = r.d.plate
        MySQL.update('UPDATE advanced_parking SET spot = ? WHERE plate = ?', { r.spot, r.d.plate })
    end
    SyncOccupied()

    if idx then Config.ParkingLots[idx] = lot else Config.ParkingLots[#Config.ParkingLots + 1] = lot end
    PublishLots()
    Log('admin_lot', { src = src, lot = lot.name,
        details = ('%s lot "%s" (%d bays)'):format(isNew and 'Created' or 'Edited', lot.label, #lot.spots) })
    return true, ('Saved %s (%d bays).'):format(lot.label, #lot.spots)
end)

lib.callback.register('rps_parking:editor:delete', function(src, name)
    if not IsAdmin(src) then return false, 'Not authorized.' end
    local idx = LotIndex(name)
    if not idx then return false, 'That lot no longer exists.' end
    for plate, d in pairs(Parked) do
        if d.zone == name then return false, ('%s is still parked here. Release or impound it first.'):format(plate) end
    end
    local lot = Config.ParkingLots[idx]
    MySQL.query.await('DELETE FROM ParkingLots WHERE name = ?', { name })
    table.remove(Config.ParkingLots, idx)
    PublishLots()
    Log('admin_lot', { src = src, lot = name, details = ('Deleted lot "%s"'):format(lot.label) })
    return true, ('Deleted %s.'):format(lot.label)
end)
