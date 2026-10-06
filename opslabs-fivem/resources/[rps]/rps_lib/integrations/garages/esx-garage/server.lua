--[[
    integrations/garages/esx-garage/server.lua
    Works against the standard ESX "owned_vehicles" table schema used by
    esx_advancedgarage, esx_garage, and most forks. Columns: owner, plate,
    vehicle (json-encoded props), stored (0/1), job, type.

    Requires oxmysql. If your installed garage script uses a different schema
    or a different query library, adjust the queries below to match.
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages['esx-garage'] = lib.garages['esx-garage'] or {}

local impl = lib.garages['esx-garage']

--- cb(vehicles) — vehicles = { { plate, vehicle = <decoded props or nil>, stored (bool) } }
function impl.GetPlayerVehicles(identifier, cb)
    exports.oxmysql:execute('SELECT plate, vehicle, stored FROM owned_vehicles WHERE owner = ?', { identifier }, function(result)
        local vehicles = {}
        if result then
            for _, row in ipairs(result) do
                vehicles[#vehicles + 1] = {
                    plate = row.plate,
                    vehicle = row.vehicle and json.decode(row.vehicle) or nil,
                    stored = row.stored == 1
                }
            end
        end
        cb(vehicles)
    end)
end

--- cb(bool)
function impl.IsVehicleStored(plate, cb)
    exports.oxmysql:execute('SELECT stored FROM owned_vehicles WHERE plate = ?', { plate }, function(result)
        cb(result and result[1] and result[1].stored == 1 or false)
    end)
end

--- stored: true = mark stored, false = mark out. cb(success) is optional.
function impl.SetVehicleStored(plate, stored, cb)
    exports.oxmysql:update('UPDATE owned_vehicles SET stored = ? WHERE plate = ?', { stored and 1 or 0, plate }, function(rowsChanged)
        if cb then cb(rowsChanged ~= nil and rowsChanged > 0) end
    end)
end
