-- Housing on QBCore / Qbox. Experimental: from each resource's SQL (qb-houses, ps-housing, qbx_properties), tested
-- against fakes. ps-housing and qbx_properties both call their table `properties` but with different columns — each
-- adapter only runs when its own resource does. Apartments and MLO homes without a door position are left out.

local function decode(v)
    if type(v) == 'table' then return v end
    local ok, t = pcall(json.decode, v or '')
    return ok and type(t) == 'table' and t or nil
end

local QB = { frameworks = { qb = true, qbx = true } }

-- qb-houses: player_houses (citizenid, keyholders JSON) + houselocations (label, coords {"enter":{x,y,z}})
Bridge.RegisterIntegration('housing', 'qb-houses', setmetatable({
    label = 'qb-houses', resource = 'qb-houses', status = 'experimental', builtin = true,
    GetHomes = function(identifier)
        local rows = MySQL.query.await([[SELECT h.house, h.citizenid, h.keyholders, l.label, l.coords FROM player_houses h
            JOIN houselocations l ON l.name = h.house WHERE h.citizenid = ? OR JSON_CONTAINS(h.keyholders, JSON_QUOTE(?))]], { identifier, identifier }) or {}
        local out = {}
        for _, r in ipairs(rows) do
            local c = (decode(r.coords) or {}).enter
            if c and c.x then out[#out + 1] = { id = r.house, label = r.label or r.house, x = c.x, y = c.y, z = c.z, kind = r.citizenid == identifier and 'owned' or 'key' } end
        end
        return out
    end,
}, { __index = QB }))

-- ps-housing: properties (owner_citizenid, has_access JSON, street, door_data JSON {x,y,z,…}, apartment)
Bridge.RegisterIntegration('housing', 'ps-housing', setmetatable({
    label = 'ps-housing', resource = 'ps-housing', status = 'experimental', builtin = true,
    GetHomes = function(identifier)
        local rows = MySQL.query.await([[SELECT property_id, owner_citizenid, street, apartment, door_data FROM properties
            WHERE owner_citizenid = ? OR JSON_CONTAINS(has_access, JSON_QUOTE(?))]], { identifier, identifier }) or {}
        local out = {}
        for _, r in ipairs(rows) do
            local d = decode(r.door_data)
            if d and d.x then
                out[#out + 1] = { id = r.property_id, label = r.street or r.apartment or ('Property ' .. r.property_id), x = d.x, y = d.y, z = d.z,
                    kind = r.owner_citizenid == identifier and 'owned' or 'key' }
            end
        end
        return out
    end,
}, { __index = QB }))

-- qbx_properties: properties (owner, keyholders JSON, property_name, coords JSON {x,y,z}, rent_interval NULL = owned)
Bridge.RegisterIntegration('housing', 'qbx_properties', setmetatable({
    label = 'qbx_properties', resource = 'qbx_properties', status = 'experimental', builtin = true,
    GetHomes = function(identifier)
        local rows = MySQL.query.await([[SELECT id, property_name, coords, owner, rent_interval FROM properties
            WHERE owner = ? OR JSON_CONTAINS(keyholders, JSON_QUOTE(?))]], { identifier, identifier }) or {}
        local out = {}
        for _, r in ipairs(rows) do
            local c = decode(r.coords)
            if c and c.x then
                local kind = r.owner ~= identifier and 'key' or (r.rent_interval and 'rented' or 'owned')
                out[#out + 1] = { id = r.id, label = r.property_name or ('Property ' .. r.id), x = c.x, y = c.y, z = c.z, kind = kind }
            end
        end
        return out
    end,
}, { __index = QB }))
