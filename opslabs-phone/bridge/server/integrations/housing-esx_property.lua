-- esx_property 2.0: properties live in its properties.json (Owner = identifier, Keys = { [identifier] = … },
-- Entrance = coords). Verified against the live server's esx_property files.

local A = { label = 'esx_property', resource = 'esx_property', status = 'verified', builtin = true, frameworks = { esx = true } }

function A.GetHomes(identifier)
    local raw = LoadResourceFile('esx_property', 'properties.json')
    local ok, list = pcall(json.decode, raw or '[]')
    local out = {}
    for i, p in ipairs(ok and type(list) == 'table' and list or {}) do
        local e = p.Entrance
        local kind = (p.Owned and p.Owner == identifier) and 'owned' or (type(p.Keys) == 'table' and p.Keys[identifier] and 'key') or nil
        if kind and e and e.x then
            out[#out + 1] = { id = i, label = (p.setName and p.setName ~= '' and p.setName) or p.Name or ('Property ' .. i), x = e.x, y = e.y, z = e.z, kind = kind }
        end
    end
    return out
end

Bridge.RegisterIntegration('housing', 'esx_property', A)
