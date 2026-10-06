-- Danger zone (server/danger.lua): mass delete behind a username + password, for tower admins.
-- /towers → Danger zone. First login admin / admin → must set a new username and password straight away.

local DZ = Config.Danger or {}
if DZ.Enabled == false then return end

local RED = '#ff453a'
local DangerMenu

local function cb(name, ...) return lib.callback.await('opslabs-towers:danger:' .. name, false, ...) end
local function err(r) lib.notify({ type = 'error', title = 'Danger zone', description = (r and r.error) or 'Failed' }) end

local function changePassword(forced)
    local v = lib.inputDialog(forced and 'Change the default login first' or 'Change username & password', {
        { type = 'input', label = 'New username', description = forced and 'admin / admin can’t stay — anyone could guess it' or nil, required = true, min = 3, max = 32 },
        { type = 'input', label = 'New password', password = true, required = true, min = 8, description = 'At least 8 characters' },
        { type = 'input', label = 'Repeat the password', password = true, required = true },
    })
    if not v then return false end
    local r = cb('setPassword', v[1], v[2], v[3])
    if not r or r.error then err(r) return changePassword(forced) end
    lib.notify({ type = 'success', title = 'Danger zone', description = 'Login changed — keep it somewhere safe' })
    return true
end

local function login()
    local v = lib.inputDialog('Danger zone · log in', {
        { type = 'input', label = 'Username', required = true },
        { type = 'input', label = 'Password', password = true, required = true },
    })
    if not v then return false end
    local r = cb('login', v[1], v[2])
    if not r or r.error then err(r) return false end
    if r.mustChange and not changePassword(true) then
        cb('lock')
        lib.notify({ type = 'error', title = 'Danger zone', description = 'Locked again — the default login has to be changed before you can delete anything' })
        return false
    end
    return true
end

local function massDelete()
    local v = lib.inputDialog('Mass delete · where', {
        { type = 'select', label = 'Area', required = true, default = 'radius', options = {
            { value = 'radius', label = 'Around me (radius)' }, { value = 'all', label = 'The whole map' } } },
        { type = 'number', label = 'Radius (metres, around me)', default = 100, min = 1, max = 20000 },
    })
    if not v then return DangerMenu() end
    local p = GetEntityCoords(PlayerPedId())
    local scope = v[1] == 'all' and { all = true } or { r = tonumber(v[2]) or 100, x = p.x, y = p.y }
    local res = cb('groups', scope)
    if not res or res.error then err(res) return DangerMenu() end
    if #res.groups == 0 then lib.notify({ type = 'inform', description = 'Nothing built in that area' }) return DangerMenu() end
    local opts, total = {}, 0
    for _, g in ipairs(res.groups) do
        opts[#opts + 1] = { value = g.key, label = ('%s (%d)'):format(g.label, g.n) }
        total = total + g.n
    end
    local pick = lib.inputDialog(('Mass delete · what (%d items in range)'):format(total), {
        { type = 'select', label = 'Quick pick', default = 'none', options = {
            { value = 'none', label = 'Only what I tick below' },
            { value = 'grid', label = 'Power grid: poles, pole kit, pylons, substations, stations, overhead conductor' },
            { value = 'power', label = 'The whole power network (all SAPL + solar kit, every power cable)' },
            { value = 'all', label = 'EVERYTHING in range' } } },
        { type = 'multi-select', label = 'Groups', options = opts, searchable = true },
    })
    if not pick then return DangerMenu() end
    local keys, seen = {}, {}
    local function add(k) if not seen[k] then seen[k] = true keys[#keys + 1] = k end end
    for _, k in ipairs(pick[2] or {}) do add(k) end
    for _, g in ipairs(res.groups) do
        if pick[1] == 'all' or (pick[1] == 'grid' and g.grid) or (pick[1] == 'power' and g.power) then add(g.key) end
    end
    if #keys == 0 then lib.notify({ type = 'error', description = 'Nothing picked' }) return massDelete() end
    local n, lines = 0, {}
    for _, g in ipairs(res.groups) do if seen[g.key] then n = n + g.n lines[#lines + 1] = ('- %s: **%d**'):format(g.label, g.n) end end
    local ok = lib.alertDialog({ header = ('Delete %d item(s)?'):format(n), centered = true, cancel = true, size = 'lg',
        content = ('%s  \n  \n%s  \n  \nA backup is saved first and can be restored from the Danger zone.'):format(
            scope.all and '**Across the WHOLE map.**' or ('Within **%d m** of you.'):format(scope.r), table.concat(lines, '  \n')) })
    if ok ~= 'confirm' then return DangerMenu() end
    local t = lib.inputDialog('Type DELETE to confirm', { { type = 'input', label = ('This removes %d item(s)'):format(n), required = true } })
    if not t or t[1] ~= 'DELETE' then lib.notify({ type = 'inform', description = 'Cancelled — nothing deleted' }) return DangerMenu() end
    local r = cb('wipe', scope, keys, t[1])
    if not r or r.error then err(r) return DangerMenu() end
    lib.notify({ type = 'success', title = 'Danger zone', duration = 9000,
        description = ('Deleted %d: %d kit, %d cable runs, %d boxes, %d masts. Backup saved.'):format(r.total, r.fixtures, r.runs, r.boxes, r.towers) })
    DangerMenu()
end

local function backups()
    local r = cb('backups')
    if not r or r.error then return err(r) end
    local opts = {}
    for _, b in ipairs(r.list or {}) do
        opts[#opts + 1] = { title = ('%s · %d item(s)'):format(b.what or 'Wipe', b.n or 0), icon = 'clock-rotate-left',
            description = ('%s · by %s · %s'):format(b.where or '', b.by or '?', (b.file or ''):match('wipe%-(%d+%-%d+)') or ''),
            onSelect = function()
                if lib.alertDialog({ header = 'Restore this wipe?', content = ('Puts back %d item(s) with their original ids. Masts / Wi-Fi come back after a resource restart.'):format(b.n or 0),
                    centered = true, cancel = true }) ~= 'confirm' then return backups() end
                local x = cb('restore', b.file)
                if not x or x.error then err(x) else lib.notify({ type = 'success', description = ('Restored %d item(s)%s'):format(x.n, (x.masts or 0) > 0 and ' — restart opslabs-towers for the masts' or '') }) end
                DangerMenu()
            end }
    end
    if #opts == 0 then opts[1] = { title = 'No backups yet', readOnly = true } end
    lib.registerContext({ id = 'danger_backups', title = 'Restore a wipe', options = opts })
    lib.showContext('danger_backups')
end

DangerMenu = function()
    local st = cb('state')
    if not st or not st.admin then return lib.notify({ type = 'error', description = 'Tower admins only' }) end
    if st.locked and st.locked > 0 then return lib.notify({ type = 'error', title = 'Danger zone', description = ('Locked after wrong passwords — %d min left'):format(math.ceil(st.locked / 60)) }) end
    if not st.session then
        if not login() then return end
        st = cb('state')
    elseif st.mustChange then
        if not changePassword(true) then return end
    end
    lib.registerContext({ id = 'towers_danger', title = 'Danger zone', options = {
        { title = 'Unlocked', description = ('Locks itself in %d min'):format(math.ceil((st.expires or 0) / 60)), icon = 'lock-open', iconColor = RED, readOnly = true },
        { title = 'Mass delete…', description = 'Parts of the power network or anything else · around you or across the map · backed up first', icon = 'dumpster-fire', iconColor = RED, onSelect = massDelete },
        { title = 'Restore a wipe', description = 'Undo a mass delete from its backup', icon = 'clock-rotate-left', iconColor = '#30d158', arrow = true, onSelect = backups },
        { title = 'Change username & password', icon = 'key', onSelect = function() changePassword(false) DangerMenu() end },
        { title = 'Lock now', icon = 'lock', onSelect = function() cb('lock') lib.notify({ type = 'inform', description = 'Danger zone locked' }) end },
    } })
    lib.showContext('towers_danger')
end

function OpenDangerZone() DangerMenu() end
