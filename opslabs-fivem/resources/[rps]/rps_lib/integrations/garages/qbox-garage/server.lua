--[[
    integrations/garages/qbox-garage/server.lua
    Uses Qbox's own documented exports (qbx_vehicles + qbx_garages) rather than
    querying the database directly — Qbox explicitly asks third-party
    resources to go through these exports instead of touching player_vehicles
    directly, since the schema is theirs to change.

    VehicleState enum (confirmed from Qbox docs): OUT = 0, GARAGED = 1, IMPOUNDED = 2.

    Requires qbx_vehicles and qbx_garages (both part of a standard Qbox setup).
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages['qbox-garage'] = lib.garages['qbox-garage'] or {}

local impl = lib.garages['qbox-garage']

local STATE_OUT = 0
local STATE_GARAGED = 1
local STATE_IMPOUNDED = 2

--- cb(vehicles) — vehicles = { { plate, vehicle = <ox_lib props or nil>, stored (bool), garage } }
function impl.GetPlayerVehicles(identifier, cb)
    local rows = exports.qbx_vehicles:GetPlayerVehicles({ citizenid = identifier }) or {}
    local vehicles = {}
    for _, row in ipairs(rows) do
        vehicles[#vehicles + 1] = {
            plate = row.props and row.props.plate or nil,
            vehicle = row.props,
            stored = row.state == STATE_GARAGED,
            garage = row.garage
        }
    end
    cb(vehicles)
end

--- cb(bool)
function impl.IsVehicleStored(plate, cb)
    local vehicleId = exports.qbx_vehicles:GetVehicleIdByPlate(plate)
    if not vehicleId then
        cb(false)
        return
    end
    local row = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
    cb(row ~= nil and row.state == STATE_GARAGED)
end

--- stored: true = mark garaged in its current/last known garage. cb(success) is optional.
--- NOTE: qbx_vehicles/qbx_garages have no documented DB-only "mark as taken out" export —
--- normally a vehicle only becomes OUT as a side effect of qbx_garages' own spawnVehicle
--- callback actually spawning it. Passing stored = false is therefore a no-op here.
function impl.SetVehicleStored(plate, stored, cb)
    local vehicleId = exports.qbx_vehicles:GetVehicleIdByPlate(plate)
    if not vehicleId then
        if cb then cb(false) end
        return
    end

    if not stored then
        lib.print('SetVehicleStored(false) is not supported for qbox-garage — a vehicle is only marked OUT by qbx_garages\' own spawnVehicle flow')
        if cb then cb(false) end
        return
    end

    local row = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
    if not row or not row.garage then
        if cb then cb(false) end
        return
    end

    local success = exports.qbx_garages:SetVehicleGarage(vehicleId, row.garage)
    if cb then cb(success or false) end
end

--- cb(bool) — true if the vehicle is currently impounded.
function impl.IsVehicleImpounded(plate, cb)
    local vehicleId = exports.qbx_vehicles:GetVehicleIdByPlate(plate)
    if not vehicleId then
        cb(false)
        return
    end
    local row = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
    cb(row ~= nil and row.state == STATE_IMPOUNDED)
end
