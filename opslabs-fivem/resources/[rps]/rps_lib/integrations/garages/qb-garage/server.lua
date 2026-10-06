--[[
    integrations/garages/qb-garage/server.lua
    Works against the standard QBCore "player_vehicles" table schema used by
    qb-garages and most of its forks (ss-garage, MojiaGarages, etc). Columns:
    citizenid, plate, vehicle (json-encoded props), state, garage.
    state: 0 = out, 1 = garaged, 2 = impounded.

    Requires oxmysql. If your installed garage script uses a different schema
    or a different query library, adjust the queries below to match.
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages['qb-garage'] = lib.garages['qb-garage'] or {}

local impl = lib.garages['qb-garage']

local STATE_OUT = 0
local STATE_GARAGED = 1
local STATE_IMPOUNDED = 2

--- cb(vehicles) — vehicles = { { plate, vehicle = <decoded props or nil>, stored (bool), garage } }
function impl.GetPlayerVehicles(identifier, cb)
    exports.oxmysql:execute('SELECT plate, vehicle, state, garage FROM player_vehicles WHERE citizenid = ?', { identifier }, function(result)
        local vehicles = {}
        if result then
            for _, row in ipairs(result) do
                vehicles[#vehicles + 1] = {
                    plate = row.plate,
                    vehicle = row.vehicle and json.decode(row.vehicle) or nil,
                    stored = row.state == STATE_GARAGED,
                    garage = row.garage
                }
            end
        end
        cb(vehicles)
    end)
end

--- cb(bool)
function impl.IsVehicleStored(plate, cb)
    exports.oxmysql:execute('SELECT state FROM player_vehicles WHERE plate = ?', { plate }, function(result)
        cb(result and result[1] and result[1].state == STATE_GARAGED or false)
    end)
end

--- stored: true = mark garaged, false = mark out. cb(success) is optional.
function impl.SetVehicleStored(plate, stored, cb)
    local state = stored and STATE_GARAGED or STATE_OUT
    exports.oxmysql:update('UPDATE player_vehicles SET state = ? WHERE plate = ?', { state, plate }, function(rowsChanged)
        if cb then cb(rowsChanged ~= nil and rowsChanged > 0) end
    end)
end

--- cb(bool) — true if the vehicle is currently impounded.
function impl.IsVehicleImpounded(plate, cb)
    exports.oxmysql:execute('SELECT state FROM player_vehicles WHERE plate = ?', { plate }, function(result)
        cb(result and result[1] and result[1].state == STATE_IMPOUNDED or false)
    end)
end
