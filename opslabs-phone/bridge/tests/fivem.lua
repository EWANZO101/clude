-- A small fake of the FiveM server / client Lua runtime, enough to load the bridge and its adapters outside the game.
-- Used by bridge/tests/run.lua (lua5.4 bridge/tests/run.lua). Not loaded by the resource.

local H = {}

---------------------------------------------------------------------------
-- json (enough for framework data: objects, arrays, strings, numbers, booleans, null)
---------------------------------------------------------------------------
local json = {}
local function enc(v, out)
    local t = type(v)
    if t == 'nil' then out[#out + 1] = 'null'
    elseif t == 'boolean' or t == 'number' then out[#out + 1] = tostring(v)
    elseif t == 'string' then out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return ({ ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n' })[c] or ('\\u%04x'):format(c:byte()) end) .. '"'
    elseif t == 'table' then
        if #v > 0 or next(v) == nil then
            out[#out + 1] = '['
            for i, x in ipairs(v) do if i > 1 then out[#out + 1] = ',' end enc(x, out) end
            out[#out + 1] = ']'
        else
            out[#out + 1] = '{'
            local first = true
            for k, x in pairs(v) do
                if not first then out[#out + 1] = ',' end
                first = false
                enc(tostring(k), out) out[#out + 1] = ':' enc(x, out)
            end
            out[#out + 1] = '}'
        end
    end
end
function json.encode(v) local out = {} enc(v, out) return table.concat(out) end
function json.decode(s)
    if type(s) ~= 'string' then return nil end
    local i = 1
    local function ws() i = s:find('[^%s]', i) or #s + 1 end
    local val
    local function str()
        local j, out = i + 1, {}
        while true do
            local c = s:sub(j, j)
            if c == '"' then i = j + 1 return table.concat(out) end
            if c == '\\' then
                local n = s:sub(j + 1, j + 1)
                out[#out + 1] = ({ n = '\n', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' })[n] or ''
                j = j + 2
            else out[#out + 1] = c j = j + 1 end
        end
    end
    function val()
        ws()
        local c = s:sub(i, i)
        if c == '{' then
            local o = {} i = i + 1 ws()
            if s:sub(i, i) == '}' then i = i + 1 return o end
            while true do
                ws() local k = str() ws() i = i + 1
                o[k] = val() ws()
                local d = s:sub(i, i) i = i + 1
                if d == '}' then return o end
            end
        elseif c == '[' then
            local a = {} i = i + 1 ws()
            if s:sub(i, i) == ']' then i = i + 1 return a end
            while true do
                a[#a + 1] = val() ws()
                local d = s:sub(i, i) i = i + 1
                if d == ']' then return a end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == 'true' then i = i + 4 return true
        elseif s:sub(i, i + 4) == 'false' then i = i + 5 return false
        elseif s:sub(i, i + 3) == 'null' then i = i + 4 return nil
        else
            local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
            i = i + #num
            return tonumber(num)
        end
    end
    local ok, r = pcall(val)
    return ok and r or nil
end
H.json = json

---------------------------------------------------------------------------
-- a fresh runtime: H.reset{ side = 'server' | 'client' }
---------------------------------------------------------------------------
function H.reset(opts)
    opts = opts or {}
    local now, threads, timers = 0, {}, {}
    local handlers, netEvents = {}, {}
    H.logs, H.clientEvents, H.sql, H.commands = {}, {}, {}, {}
    H.resources, H.exportsOf, H.convars, H.aces, H.players = {}, {}, {}, {}, {}
    H.sqlHandler = function() return nil end

    _G.json = json
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        H.logs[#H.logs + 1] = table.concat(parts, ' '):gsub('%^%d', '')
    end
    _G.GetGameTimer = function() return now end
    _G.Wait = function(ms) coroutine.yield(ms or 0) end
    _G.Citizen = { Wait = _G.Wait, CreateThread = nil, Await = nil }
    _G.CreateThread = function(fn)
        local co = coroutine.create(fn)
        threads[#threads + 1] = { co = co, at = now }
    end
    _G.Citizen.CreateThread = _G.CreateThread
    _G.SetTimeout = function(ms, fn) timers[#timers + 1] = { at = now + ms, fn = fn } end
    _G.promise = {
        new = function()
            local p = { done = false }
            function p:resolve(v) if not self.done then self.done, self.value = true, v end end
            return p
        end,
    }
    _G.Citizen.Await = function(p)
        while not p.done do coroutine.yield(0) end
        return p.value
    end

    _G.GetResourceState = function(res) return H.resources[res] or 'missing' end
    _G.GetResourceMetadata = function(res, key) return (H.resources[res] and key == 'version') and '1.0.0-test' or nil end
    _G.GetCurrentResourceName = function() return 'opslabs-phone' end
    _G.GetConvar = function(k, d) return H.convars[k] or d end
    _G.IsPlayerAceAllowed = function(src, ace) return (H.aces[src] or {})[ace] == true end
    _G.GetPlayers = function() local out = {} for s in pairs(H.players) do out[#out + 1] = tostring(s) end return out end
    _G.GetPlayerName = function(src) return (H.players[tonumber(src)] or {}).name end
    _G.GetPlayerIdentifierByType = function(src, kind) return ((H.players[tonumber(src)] or {}).ids or {})[kind] end
    _G.GlobalState = {}
    _G.RegisterCommand = function(name, fn) H.commands[name] = fn end
    _G.TriggerClientEvent = function(name, target, ...) H.clientEvents[#H.clientEvents + 1] = { name = name, target = target, args = { ... } } end

    _G.AddEventHandler = function(name, fn)
        handlers[name] = handlers[name] or {}
        table.insert(handlers[name], fn)
    end
    _G.RegisterNetEvent = function(name, fn) netEvents[name] = true if fn then _G.AddEventHandler(name, fn) end end
    _G.TriggerEvent = function(name, ...)
        for _, fn in ipairs(handlers[name] or {}) do
            local args = table.pack(...)
            local co = coroutine.create(function() fn(table.unpack(args, 1, args.n)) end)
            local ok, err = coroutine.resume(co)
            if not ok then error(err, 0) end
            if coroutine.status(co) ~= 'dead' then threads[#threads + 1] = { co = co, at = now } end
        end
    end
    -- a net event from the server (client side) or a client (server side): `source` is set like FiveM does
    H.emit = function(name, src, ...)
        _G.source = src
        _G.TriggerEvent(name, ...)
    end
    H.hasHandler = function(name) return handlers[name] ~= nil end

    -- exports.res:fn(...) and exports('Name', fn)
    H.ownExports = {}
    _G.exports = setmetatable({}, {
        __index = function(_, res)
            local e = H.exportsOf[res]
            if not e then error(('No such export resource %s'):format(res), 2) end
            return e
        end,
        __call = function(_, name, fn) H.ownExports[name] = fn end,
    })

    -- MySQL (oxmysql): every call goes to H.sqlHandler(kind, query, params)
    local function q(kind) return { await = function(query, params) H.sql[#H.sql + 1] = { kind = kind, query = query, params = params } return H.sqlHandler(kind, query, params or {}) end } end
    _G.MySQL = { scalar = q('scalar'), single = q('single'), query = q('query'), update = q('update'), insert = q('insert') }
    setmetatable(_G.MySQL.update, { __call = function(_, query, params) return _G.MySQL.update.await(query, params) end })
    setmetatable(_G.MySQL.query, { __call = function(_, query, params) return _G.MySQL.query.await(query, params) end })

    _G.Config = { Bank = { Account = 'bank' }, RequireItem = true, Items = { phone = 'black' }, Framework = 'auto', Inventory = 'auto' }
    _G.joaat = function(s) local h = 0 for c in tostring(s):gmatch('.') do h = (h * 31 + c:byte()) % 4294967296 end return h end
    _G.LoadResourceFile = function(res, path) return (H.files[res] or {})[path] end
    H.files = {}
    _G.IsTrue = function(v) return v == true or v == 1 or v == '1' or v == 'true' end
    _G.DatabaseReady = true
    _G.Bridge, _G.FW, _G.source = nil, nil, nil

    --- run threads / timers until nothing is waiting (or `ms` of fake time has passed)
    H.run = function(ms)
        local limit = now + (ms or 60000)
        while now <= limit do
            local progressed = false
            for i = #timers, 1, -1 do
                if timers[i].at <= now then local t = table.remove(timers, i) CreateThread(t.fn) progressed = true end
            end
            for i = #threads, 1, -1 do
                local t = threads[i]
                if t.at <= now then
                    local ok, wait = coroutine.resume(t.co)
                    if not ok then table.remove(threads, i) error(wait, 0) end
                    if coroutine.status(t.co) == 'dead' then table.remove(threads, i) else t.at = now + (wait or 0) end
                    progressed = true
                end
            end
            if #threads == 0 and #timers == 0 then return end
            if not progressed then now = now + 50 end
        end
    end
    --- run fn inside a thread (so FW calls may wait) and return what it returned
    H.call = function(fn)
        local result
        CreateThread(function() result = table.pack(fn()) end)
        H.run()
        return table.unpack(result or {}, 1, result and result.n or 0)
    end
end

--- load files from the resource (paths relative to the resource root)
function H.load(root, files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(root .. '/' .. f)
        if not chunk then error(err, 0) end
        chunk()
    end
end

function H.logged(pattern)
    for _, l in ipairs(H.logs) do if l:find(pattern) then return l end end
    return nil
end

return H
