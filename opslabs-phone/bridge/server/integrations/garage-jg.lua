-- jg-advancedgarages. Experimental: from JG's published docs (columns in_garage, garage_id, impound, nickname added to
-- the framework's vehicle table), tested against fakes. Model / fuel / damage come from the framework's own columns.

local function decode(v)
    if type(v) == 'table' then return v end
    local ok, t = pcall(json.decode, v or '')
    return ok and type(t) == 'table' and t or {}
end

local A = { label = 'jg-advancedgarages', resource = 'jg-advancedgarages', status = 'experimental', builtin = true,
    frameworks = { esx = true, qb = true, qbx = true } }

function A.GetVehicles(identifier)
    local esx = FW.Info().framework == 'esx'
    local rows = MySQL.query.await(esx and 'SELECT * FROM owned_vehicles WHERE owner = ?' or 'SELECT * FROM player_vehicles WHERE citizenid = ?', { identifier }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        local props = decode(esx and r.vehicle or r.mods)
        local impounded = IsTrue(r.impound)
        list[#list + 1] = {
            plate = r.plate, name = r.nickname ~= '' and r.nickname or nil, type = r.type or 'car',
            model = props.model or tonumber(r.hash) or (r.vehicle and not esx and joaat(r.vehicle)) or nil,
            stored = IsTrue(r.in_garage) and not impounded, parking = r.garage_id, pound = impounded and 'Impound' or nil,
            fuel = tonumber(r.fuel) or props.fuelLevel, engine = tonumber(r.engine) or props.engineHealth, body = tonumber(r.body) or props.bodyHealth,
            mileage = r.mileage,
        }
    end
    return list
end

Bridge.RegisterIntegration('garage', 'jg-advancedgarages', A)
