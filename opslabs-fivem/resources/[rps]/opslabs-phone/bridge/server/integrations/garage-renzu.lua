-- renzu_garage (ESX). Experimental: from its ESX_garage.sql (garage_id, impound, stored added to owned_vehicles),
-- tested against fakes.

local A = { label = 'renzu_garage', resource = 'renzu_garage', status = 'experimental', builtin = true, frameworks = { esx = true } }

function A.GetVehicles(identifier)
    local rows = MySQL.query.await('SELECT * FROM owned_vehicles WHERE owner = ?', { identifier }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        local ok, props = pcall(json.decode, r.vehicle or '{}')
        props = ok and type(props) == 'table' and props or {}
        local impounded = IsTrue(r.impound)
        list[#list + 1] = {
            plate = r.plate, model = props.model, type = r.type or 'car', stored = IsTrue(r.stored) and not impounded,
            parking = r.garage_id, pound = impounded and 'Impound' or nil,
            fuel = props.fuelLevel, engine = props.engineHealth, body = props.bodyHealth,
        }
    end
    return list
end

Bridge.RegisterIntegration('garage', 'renzu_garage', A)
