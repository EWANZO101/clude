-- OPS City Kit — server: persistence + admin check for the outdoor dressing props placed in client/main.lua.

local props = {}   -- id -> { id, model, category, x, y, z, heading, created_by }
local ready = false

local function broadcast(target) TriggerClientEvent('opslabs-citykit:list', target or -1, props) end

local function load_()
    local rows = MySQL.query.await('SELECT id, model, category, x, y, z, heading, created_by FROM opslabs_citykit_props', {}) or {}
    props = {}
    for _, r in ipairs(rows) do props[r.id] = r end
    ready = true
end
CreateThread(function()
    local ok, err = pcall(load_)
    if not ok then print(('^1[opslabs-citykit] could not load props (did you run sql/install.sql?): %s^7'):format(tostring(err))) end
end)

---------------------------------------------------------------------------
-- admin check — same pattern as opslabs-towers (server/main.lua IsTowerAdmin)
---------------------------------------------------------------------------
function IsCityKitAdmin(src)
    if IsPlayerAceAllowed(src, Config.AdminAce or 'opslabs.citykit') then return true end
    local license = GetPlayerIdentifierByType(src, 'license')
    for _, l in ipairs(Config.AdminLicenses or {}) do
        if l == license then return true end
    end
    return FW.IsAdmin and FW.IsAdmin(src, Config.AdminGroups) or false
end

lib.callback.register('opslabs-citykit:isAdmin', function(src) return IsCityKitAdmin(src) end)

RegisterNetEvent('opslabs-citykit:ready', function()
    local src = source
    if ready then broadcast(src) end
end)

---------------------------------------------------------------------------
-- place / move / delete
---------------------------------------------------------------------------

local function validModel(model)
    for _, c in ipairs(Config.Categories or {}) do
        for _, it in ipairs(c.items or {}) do if it.model == model then return c.id end end
    end
    return nil
end

lib.callback.register('opslabs-citykit:save', function(src, data)
    if not IsCityKitAdmin(src) then return { error = 'Only a city-kit admin can place props' } end
    if type(data) ~= 'table' or type(data.model) ~= 'string' then return { error = 'Bad request' } end
    local category = validModel(data.model)
    if not category then return { error = 'That model is not in the catalog' } end
    local x, y, z, heading = tonumber(data.x), tonumber(data.y), tonumber(data.z), tonumber(data.heading) or 0.0
    if not (x and y and z) then return { error = 'Bad position' } end
    local by = FW.Name and FW.Name(src) or GetPlayerName(src)
    local id = MySQL.insert.await('INSERT INTO opslabs_citykit_props (model, category, x, y, z, heading, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { data.model, category, x, y, z, heading, by })
    if not id then return { error = 'Database error' } end
    local row = { id = id, model = data.model, category = category, x = x, y = y, z = z, heading = heading, created_by = by }
    props[id] = row
    broadcast()
    return { ok = true, prop = row }
end)

lib.callback.register('opslabs-citykit:move', function(src, id, data)
    if not IsCityKitAdmin(src) then return { error = 'Only a city-kit admin can move props' } end
    local row = props[tonumber(id) or -1]
    if not row then return { error = 'Not found' } end
    local x, y, z, heading = tonumber(data.x), tonumber(data.y), tonumber(data.z), tonumber(data.heading) or row.heading
    if not (x and y and z) then return { error = 'Bad position' } end
    row.x, row.y, row.z, row.heading = x, y, z, heading
    MySQL.update.await('UPDATE opslabs_citykit_props SET x = ?, y = ?, z = ?, heading = ? WHERE id = ?', { x, y, z, heading, row.id })
    broadcast()
    return { ok = true }
end)

lib.callback.register('opslabs-citykit:delete', function(src, id)
    if not IsCityKitAdmin(src) then return { error = 'Only a city-kit admin can remove props' } end
    local row = props[tonumber(id) or -1]
    if not row then return { error = 'Not found' } end
    props[row.id] = nil
    MySQL.update.await('DELETE FROM opslabs_citykit_props WHERE id = ?', { row.id })
    broadcast()
    return { ok = true }
end)
