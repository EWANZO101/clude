-- Which vehicle (by plate) has the MDT laptop mounted right now. The prop itself is purely cosmetic and
-- client-local (same idiom as opslabs-towers' fixtures: every nearby client spawns its own copy from this
-- state, nothing networked) - this table is the only thing that's actually real.

local RES = GetCurrentResourceName()
Installs = {}   -- [plate] = { model }
Install = {}

local function trimPlate(p) return (tostring(p or ''):gsub('%s+$', ''):gsub('^%s+', '')) end

CreateThread(function()
    local sql = LoadResourceFile(RES, 'sql/install.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end

    local rows = MySQL.query.await('SELECT plate, model FROM opslabs_mdt_installs') or {}
    for _, r in ipairs(rows) do Installs[trimPlate(r.plate)] = { model = r.model } end
    print(('[opslabs-mdt] %d laptop(s) already installed'):format(#rows))
end)

--- broadcasts the full table to everyone - clients also pull it once via the callback below on their own start
local function sync()
    TriggerClientEvent('opslabs-mdt:installs', -1, Installs)
end

function Install.Set(plate, model, src)
    plate = trimPlate(plate)
    Installs[plate] = { model = model }
    MySQL.insert.await(
        'INSERT INTO opslabs_mdt_installs (plate, model, installed_by, installed_at) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model = VALUES(model), installed_by = VALUES(installed_by), installed_at = VALUES(installed_at)',
        { plate, model, src and FW.Name(src) or nil, os.time() }
    )
    sync()
end

function Install.Remove(plate)
    plate = trimPlate(plate)
    Installs[plate] = nil
    MySQL.update.await('DELETE FROM opslabs_mdt_installs WHERE plate = ?', { plate })
    sync()
end

function Install.Get(plate) return Installs[trimPlate(plate)] end

lib.callback.register('opslabs-mdt:installs', function(_) return Installs end)

--- the item is used, found a vehicle in range client-side; resolve the entity from its netId server-side
--- rather than trusting a client-supplied plate/model
local function vehicleFromNet(netId)
    local v = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not v or v == 0 or not DoesEntityExist(v) or GetEntityType(v) ~= 2 then return nil end
    return v
end

lib.callback.register('opslabs-mdt:install', function(src, netId)
    Dbg('server install: src=%s netId=%s', src, netId)
    local ok, why = FW.Eligible(src)
    if not ok then Dbg('server install: FW.Eligible failed (%s)', why) return { error = 'You are not issued an MDT (' .. tostring(why) .. ').' } end
    local v = vehicleFromNet(netId)
    if not v then Dbg('server install: vehicleFromNet(%s) resolved to nothing', netId) return { error = 'No vehicle there.' } end
    local plate = GetVehicleNumberPlateText(v):gsub('%s+$', ''):gsub('^%s+', '')
    Dbg('server install: vehicle entity=%s plate=%s model=%s', v, plate, GetEntityModel(v))
    if Install.Get(plate) then Dbg('server install: plate=%s already has a row', plate) return { error = 'This vehicle already has an MDT installed.' } end
    if not FW.HasItem(src, Config.Item) then Dbg('server install: src=%s has no %s', src, Config.Item) return { error = 'You need an MDT laptop to install.' } end
    if not FW.RemoveItem(src, Config.Item, 1) then Dbg('server install: RemoveItem(%s, %s) returned falsy', src, Config.Item) return { error = 'Could not take the laptop from your inventory.' } end
    Install.Set(plate, GetEntityModel(v), src)
    Dbg('server install: plate=%s installed OK', plate)
    return { ok = true }
end)

lib.callback.register('opslabs-mdt:remove', function(src, netId)
    Dbg('server remove: src=%s netId=%s', src, netId)
    local ok, why = FW.Eligible(src)
    if not ok then return { error = 'You are not issued an MDT (' .. tostring(why) .. ').' } end
    local v = vehicleFromNet(netId)
    if not v then return { error = 'No vehicle there.' } end
    local plate = GetVehicleNumberPlateText(v):gsub('%s+$', ''):gsub('^%s+', '')
    if not Install.Get(plate) then Dbg('server remove: plate=%s has no row', plate) return { error = 'No MDT installed here.' } end
    Install.Remove(plate)
    FW.AddItem(src, Config.Item, 1)
    Dbg('server remove: plate=%s removed OK', plate)
    return { ok = true }
end)

Dbg('registering %s as a useable item via rps_lib', Config.Item)
exports.rps_lib:CreateUseableItem(Config.Item, function(src)
    Dbg('useable item fired: src=%s item=%s', src, Config.Item)
    TriggerClientEvent('opslabs-mdt:tryInstall', src)
end)
