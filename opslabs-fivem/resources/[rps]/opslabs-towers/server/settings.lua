-- Live settings: every value in this resource's config.lua can be overridden from OPS Hub → Settings or the OPS Work
-- admin screen. Overrides live in ops_settings (path "<resource>:<Key.Sub.Key>", JSON value) and are applied on start
-- and within ~15 s of a change (also pushed to players' clients). The defaults and the comments from config.lua are
-- published to ops_config_dump so OPS Hub can show every setting with its explanation.
-- Note: a few values are read once when a script loads; those need a resource restart (OPS Hub says which are live).

local RES = GetCurrentResourceName()
local DEFAULTS = {}
local applied = {}               -- path -> true (currently overridden)
local lastSeen = 0
OpsSettings = { changed = {} }

local function serialisable(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == 'number' or t == 'string' or t == 'boolean' then return v end
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then return { __vec = true, x = v.x, y = v.y, z = v.z, w = v.w } end
    if t ~= 'table' or depth > 8 then return nil end
    local out = {}
    for k, x in pairs(v) do
        if type(k) == 'string' or type(k) == 'number' then
            local s = serialisable(x, depth + 1)
            if s ~= nil then out[k] = s end
        end
    end
    return out
end

local function copy(v) if type(v) ~= 'table' then return v end local o = {} for k, x in pairs(v) do o[k] = copy(x) end return o end

local function splitPath(p)
    local parts = {}
    for seg in p:gmatch('[^%.]+') do parts[#parts + 1] = tonumber(seg) or seg end
    return parts
end

local function getAt(root, parts)
    local t = root
    for i = 1, #parts do if type(t) ~= 'table' then return nil end t = t[parts[i]] end
    return t
end

local function setAt(root, parts, value)
    local t = root
    for i = 1, #parts - 1 do
        if type(t[parts[i]]) ~= 'table' then return false end
        t = t[parts[i]]
    end
    t[parts[#parts]] = value
    return true
end

--- comments from config.lua: "Section.Key" -> comment (a trailing -- comment, or the comment lines just above)
local function parseComments()
    local text = LoadResourceFile(RES, 'config.lua') or ''
    local out, stack, pending = {}, {}, {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        local code, comment = line:match('^(.-)%-%-%s*(.*)$')
        code = code or line
        local root = code:match('^%s*Config%.([%w_]+)%s*=')
        if code:match('^%s*$') and comment then pending[#pending + 1] = comment
        else
            local prefix = table.concat(stack, '.')
            if root then
                stack = {}
                prefix = ''
                local note = comment or (#pending > 0 and table.concat(pending, ' ') or nil)
                if note then out[root] = note end
                if code:match('=%s*{') and not code:match('}%s*,?%s*$') then stack = { root } end
            else
                for key in code:gmatch('([%a_][%w_]*)%s*=') do
                    local note = comment or (#pending > 0 and table.concat(pending, ' ') or nil)
                    if note then out[(prefix ~= '' and (prefix .. '.') or '') .. key] = note end
                end
                local opener = code:match('^%s*([%a_][%w_]*)%s*=%s*{%s*$')
                local _, opens = code:gsub('{', '')
                local _, closes = code:gsub('}', '')
                if opener and opens > closes then stack[#stack + 1] = opener
                elseif opens > closes then for _ = 1, opens - closes do stack[#stack + 1] = '[]' end
                elseif closes > opens then for _ = 1, closes - opens do if #stack > 0 then table.remove(stack) end end end
            end
            pending = {}
        end
    end
    -- drop paths through anonymous tables
    for k in pairs(out) do if k:find('%[%]') then out[k] = nil end end
    return out
end

local function applyOne(path, value)
    local parts = splitPath(path)
    if #parts == 0 or getAt(DEFAULTS, { parts[1] }) == nil then return false end
    if setAt(Config, parts, value) then OpsSettings.changed[path] = true return true end
    return false
end

local function restore(path)
    local parts = splitPath(path)
    setAt(Config, parts, copy(getAt(DEFAULTS, parts)))
end

local function sync(first)
    local ok, rows = pcall(MySQL.query.await, 'SELECT path, value, updated_at FROM ops_settings WHERE path LIKE ?', { RES .. ':%' })
    if not ok then return end
    local now, changed = {}, {}
    local maxAt = lastSeen
    for _, r in ipairs(rows or {}) do
        local p = r.path:sub(#RES + 2)
        now[p] = true
        if first or not applied[p] or (r.updated_at or 0) > lastSeen then
            local okj, v = pcall(json.decode, r.value)
            if okj and applyOne(p, v) then changed[#changed + 1] = p applied[p] = true end
        end
        if (r.updated_at or 0) > maxAt then maxAt = r.updated_at end
    end
    for p in pairs(applied) do if not now[p] then restore(p) applied[p] = nil changed[#changed + 1] = p end end
    lastSeen = maxAt
    if #changed > 0 then
        local overrides = {}
        for p in pairs(applied) do overrides[p] = getAt(Config, splitPath(p)) end
        GlobalState['opscfg:' .. RES] = overrides
        TriggerEvent('opslabs:configChanged', RES, changed)
        if not first then print(('^3[%s] settings changed: %s^7'):format(RES, table.concat(changed, ', '))) end
    end
end

CreateThread(function()
    DEFAULTS = copy(Config)
    while not MySQL or not MySQL.query do Wait(500) end
    if AwaitDatabase then AwaitDatabase() else Wait(3000) end
    pcall(MySQL.query.await, [[CREATE TABLE IF NOT EXISTS ops_settings (path VARCHAR(190) NOT NULL PRIMARY KEY, value LONGTEXT NOT NULL,
        updated_by VARCHAR(60) NULL, updated_at INT NOT NULL DEFAULT 0)]])
    pcall(MySQL.query.await, [[CREATE TABLE IF NOT EXISTS ops_config_dump (resource VARCHAR(60) NOT NULL PRIMARY KEY, config LONGTEXT NOT NULL,
        comments LONGTEXT NULL, updated_at INT NOT NULL DEFAULT 0)]])
    pcall(MySQL.query.await, 'INSERT INTO ops_config_dump (resource, config, comments, updated_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE config = VALUES(config), comments = VALUES(comments), updated_at = VALUES(updated_at)',
        { RES, json.encode(serialisable(DEFAULTS) or {}), json.encode(parseComments()), os.time() })
    sync(true)
    while true do
        Wait(15000)
        pcall(sync, false)
    end
end)

--- set / clear an override from in game (OPS Work admin); value = nil clears it
function OpsSettingSet(path, value, by)
    if value == nil then
        MySQL.update.await('DELETE FROM ops_settings WHERE path = ?', { RES .. ':' .. path })
    else
        MySQL.query.await('INSERT INTO ops_settings (path, value, updated_by, updated_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)',
            { RES .. ':' .. path, json.encode(value), by, os.time() })
    end
    sync(false)
    return true
end
function OpsSettingDefault(path) return copy(getAt(DEFAULTS, splitPath(path))) end
-- other resources (the phone's Developer app): read / change a setting of this resource
exports('GetSetting', function(path) return copy(getAt(Config, splitPath(tostring(path or '')))) end)
exports('SetSetting', function(path, value, by) return OpsSettingSet(tostring(path), value, by and tostring(by):sub(1, 60) or 'dev app') end)

