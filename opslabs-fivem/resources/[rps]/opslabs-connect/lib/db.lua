-- opslabs-connect/lib/db.lua — include right after '@oxmysql/lib/MySQL.lua' in a resource's server_scripts.
--
-- When this server is connected to the OPS Hub with a token (hosted mode), every query that touches an OPS table
-- (ops_* / opslabs_* in the SQL, or as a parameter of an information_schema check) goes to this server's hosted
-- database through opslabs-connect; everything else (users, billing, owned_vehicles, items …) stays on the local
-- oxmysql database. Same API and same results as oxmysql — the rest of the resource doesn't change.
-- Without a token (or without opslabs-connect) this file does nothing.

local CONNECT = 'opslabs-connect'
if GetResourceState(CONNECT) ~= 'started' and GetResourceState(CONNECT) ~= 'starting' then return end
local okHosted, hosted = pcall(function() return exports[CONNECT]:isHosted() end)
if not okHosted or not hosted then return end

local LocalMySQL = {}
for _, m in ipairs({ 'scalar', 'single', 'query', 'insert', 'update', 'transaction', 'prepare', 'rawExecute', 'ready' }) do LocalMySQL[m] = MySQL[m] end
OpsLocalMySQL = LocalMySQL      -- the untouched local oxmysql methods, if a resource ever needs them directly

local find, type = string.find, type

local function opsName(s)
    return find(s, '%f[%w_]opslabs_[%w_]') or find(s, '%f[%w_]ops_[%w_]')
end

local function isOps(sql, params)
    if type(sql) ~= 'string' then return false end
    if opsName(sql) then return true end
    if type(params) == 'table' and find(sql, 'information_schema', 1, true) then
        for _, v in pairs(params) do
            if type(v) == 'string' and (find(v, '^opslabs_') or find(v, '^ops_')) then return true end
        end
    end
    return false
end

local function isOpsTx(queries)
    if type(queries) ~= 'table' then return false end
    for _, q in ipairs(queries) do
        local text = type(q) == 'string' and q or (type(q) == 'table' and (q.query or q[1]))
        if type(text) == 'string' and opsName(text) then return true end
    end
    return false
end

local function hostedAwait(op, sql, params)
    local p = promise.new()
    exports[CONNECT]:db(op, sql, params, function(res, err)
        if err then p:reject(err) else p:resolve(res) end
    end)
    return Citizen.Await(p)
end

local function isCb(v)
    return type(v) == 'function' or (type(v) == 'table' and v.__cfx_functionReference ~= nil)
end

for _, method in ipairs({ 'scalar', 'single', 'query', 'insert', 'update' }) do
    local orig = LocalMySQL[method]
    MySQL[method] = setmetatable({
        await = function(sql, params)
            if isCb(params) then params = nil end
            if isOps(sql, params) then return hostedAwait(method, sql, params) end
            return orig.await(sql, params)
        end,
    }, {
        __call = function(_, sql, params, cb)
            if isCb(params) then cb, params = params, nil end
            if not isOps(sql, params) then return orig(sql, params, cb) end
            exports[CONNECT]:db(method, sql, params, function(res)
                if cb then cb(res) end                    -- like oxmysql: errors are printed, the callback gets nil
            end)
        end,
    })
end

local origTx = LocalMySQL.transaction
MySQL.transaction = setmetatable({
    await = function(queries, params)
        if not isOpsTx(queries) then return origTx.await(queries, params) end
        return hostedAwait('transaction', queries, params)
    end,
}, {
    __call = function(_, queries, params, cb)
        if isCb(params) then cb, params = params, nil end
        if not isOpsTx(queries) then return origTx(queries, params, cb) end
        exports[CONNECT]:db('transaction', queries, params, function(res)
            if cb then cb(res and true or false) end
        end)
    end,
})

-- ready = the local database AND the hosted one
local origReady = LocalMySQL.ready
local function hostedReady()
    origReady.await()
    exports[CONNECT]:awaitReady(120000)
end
MySQL.ready = setmetatable({ await = hostedReady }, {
    __call = function(_, cb)
        Citizen.CreateThreadNow(function()
            hostedReady()
            if cb then cb() end
        end)
    end,
})

print(('^5[%s]^7 OPS tables → hosted OPS Hub database (opslabs-connect)'):format(GetCurrentResourceName()))
