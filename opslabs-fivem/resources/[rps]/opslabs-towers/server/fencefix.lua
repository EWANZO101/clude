-- Re-grounds already-placed Security & fencing fixtures (opslabs_fence_*) whose Z was saved wrong by the
-- old line-placement tool (client/roadworks.lua's lineMode, before its height-probe fix) on sloped ground -
-- floating or buried fence posts/panels. Admin-triggered: the server has no world geometry of its own, so
-- it borrows an online admin's client to survey real ground height (client/showcase.lua's existing
-- opslabs-towers:showcase:survey, the same one server/routes.lua uses for pole auto-link planning).

local function fenceFixtures()
    local out = {}
    for id, f in pairs(Cabling.fixtures) do
        if f.model:find('^opslabs_fence_') then out[#out + 1] = { id = id, x = f.x, y = f.y, z = f.z, model = f.model } end
    end
    return out
end

lib.callback.register('opslabs-towers:fence:regrade', function(src)
    if not IsTowerAdmin(src) then return { error = 'not allowed' } end
    local list = fenceFixtures()
    if #list == 0 then return { ok = true, checked = 0, fixed = 0 } end

    local points = {}
    for i, f in ipairs(list) do points[i] = { x = f.x, y = f.y } end
    local okc, zs = pcall(lib.callback.await, 'opslabs-towers:showcase:survey', src, points)
    if not okc or type(zs) ~= 'table' then return { error = 'The survey failed — stay online and in-game while it runs' } end

    -- snapshot what's about to change, same spirit as server/danger.lua's pre-wipe backups
    local backup, fixed = {}, 0
    for i, f in ipairs(list) do
        local z = zs[i]
        if type(z) == 'number' and math.abs(z - f.z) > 0.05 then
            backup[#backup + 1] = { id = f.id, model = f.model, x = f.x, y = f.y, z = f.z }
            Cabling.fixtures[f.id].z = z
            MySQL.update.await('UPDATE opslabs_towers_fixtures SET z = ? WHERE id = ?', { z, f.id })
            fixed = fixed + 1
        end
    end
    if fixed > 0 then
        SaveResourceFile(GetCurrentResourceName(), ('fence_regrade_backups/regrade-%s.json'):format(os.date('%Y%m%d-%H%M%S')), json.encode(backup), -1)
        if CablingChanged then CablingChanged() end
    end
    return { ok = true, checked = #list, fixed = fixed }
end)
