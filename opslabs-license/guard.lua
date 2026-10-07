-- OPSHUB guard — loaded into every OPS / rps resource ('@opslabs-license/guard.lua' in its fxmanifest, right after
-- '@ox_lib/init.lua'). It wraps the ways a resource takes player actions, so every action goes through OPSHUB:
--
--   server: net events (RegisterNetEvent / RegisterServerEvent / AddEventHandler on a net event), ox_lib callbacks,
--           commands, the resource's HTTP handler
--   client: NUI callbacks (every menu / screen click), commands (and so key mappings)
--
-- Each action is allowed only while this server's OPSHUB license session is live (signed by OPSHUB, renewed by check-ins
-- every couple of minutes — no check-in for the session's length and nothing runs) and, for a licensed resource, while
-- its module is granted. Every action let through is counted and reported to OPSHUB with the next check-in.
--
-- A resource can leave a few names open while it's unlicensed (the phone's license screen):  OPSHUB_OPEN['name'] = true
-- and choose what a refused callback returns:  OPSHUB_DENIED = { … }

local RES = GetCurrentResourceName()
if RES == 'opslabs-license' then return end
local LIC = 'opslabs-license'
local SERVER = IsDuplicityVersion()

OPSHUB_OPEN = OPSHUB_OPEN or {}

---------------------------------------------------------------------------
-- is this resource allowed right now?
---------------------------------------------------------------------------
local okNow, okAt = false, -100000
local clientState = nil

local function allowed()
    local t = GetGameTimer()
    if t - okAt < 1000 then return okNow end
    okAt = t
    if SERVER then
        if GetResourceState(LIC) ~= 'started' then okNow = false return false end
        local ok, r = pcall(function() return exports[LIC]:Allows(RES) end)
        okNow = ok and r == true
    else
        local s = clientState
        okNow = s ~= nil and s.status == 'active' and not (s.denied and s.denied[RES])
    end
    return okNow
end
OPSHUB_ALLOWED = allowed

if not SERVER then
    RegisterNetEvent('opslabs-license:state', function(s) clientState = s okAt = -100000 end)
    CreateThread(function()
        while not NetworkIsSessionStarted() do Wait(500) end
        TriggerServerEvent('opslabs-license:hello')
        -- ask again until the license resource answers (it may start after this one)
        local tries = 0
        while not clientState and tries < 30 do Wait(5000) tries = tries + 1 TriggerServerEvent('opslabs-license:hello') end
    end)
end

---------------------------------------------------------------------------
-- counting (server): sent to opslabs-license, which reports it to OPSHUB
---------------------------------------------------------------------------
local counts = {}
local function hit(kind, name)
    local k = kind .. ':' .. tostring(name)
    counts[k] = (counts[k] or 0) + 1
end
if SERVER then
    CreateThread(function()
        while true do
            Wait(30000)
            if next(counts) and GetResourceState(LIC) == 'started' then
                local c = counts
                counts = {}
                pcall(function() exports[LIC]:ReportUsage(RES, c) end)
            end
        end
    end)
end

local told = {}
local function refused(src)
    src = tonumber(src)
    if SERVER and src and src > 0 and (told[src] or 0) < GetGameTimer() then
        told[src] = GetGameTimer() + 20000
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', title = 'OPSHUB', description = 'This isn\'t licensed on this server right now', duration = 6000 })
    end
end

--- fn wrapped: runs only when allowed. srcOf(...) finds the player for the refusal notice.
local function guarded(kind, name, fn, srcOf)
    return function(...)
        if not OPSHUB_OPEN[name] and not allowed() then
            refused(srcOf and srcOf(...) or (SERVER and source) or nil)
            return OPSHUB_DENIED
        end
        if SERVER then hit(kind, name) end
        return fn(...)
    end
end

---------------------------------------------------------------------------
-- wrap the ways actions come in
---------------------------------------------------------------------------
local netEvents = {}
local function isOwn(name) return type(name) == 'string' and name:find('^opslabs%-license:') ~= nil end

if SERVER then
    local _RegisterNetEvent, _AddEventHandler, _RegisterServerEvent = RegisterNetEvent, AddEventHandler, RegisterServerEvent
    RegisterNetEvent = function(name, fn)
        netEvents[name] = true
        if type(fn) == 'function' and not isOwn(name) then return _RegisterNetEvent(name, guarded('event', name, fn)) end
        return _RegisterNetEvent(name, fn)
    end
    RegisterServerEvent = function(name, fn)
        netEvents[name] = true
        if type(fn) == 'function' and not isOwn(name) then return _RegisterServerEvent(name, guarded('event', name, fn)) end
        return _RegisterServerEvent(name, fn)
    end
    AddEventHandler = function(name, fn)
        if netEvents[name] and type(fn) == 'function' and not isOwn(name) then return _AddEventHandler(name, guarded('event', name, fn)) end
        return _AddEventHandler(name, fn)
    end
    local _SetHttpHandler = SetHttpHandler
    if _SetHttpHandler then
        SetHttpHandler = function(fn)
            return _SetHttpHandler(function(req, res)
                if not allowed() then
                    pcall(res.writeHead, 503, { ['Content-Type'] = 'application/json' })
                    pcall(res.send, '{"error":"This server is not licensed by OPSHUB right now"}')
                    return
                end
                hit('http', (req.path or ''):gsub('%?.*$', ''):sub(1, 60))
                return fn(req, res)
            end)
        end
    end
end

local _RegisterCommand = RegisterCommand
RegisterCommand = function(name, fn, restricted)
    if type(fn) ~= 'function' then return _RegisterCommand(name, fn, restricted) end
    return _RegisterCommand(name, guarded('command', name, fn, function(src) return src end), restricted)
end

if not SERVER then
    local _RegisterNUICallback = RegisterNUICallback
    RegisterNUICallback = function(name, fn)
        return _RegisterNUICallback(name, function(body, cb)
            if not OPSHUB_OPEN[name] and not allowed() then
                return cb(OPSHUB_DENIED or { __license = RES })
            end
            return fn(body, cb)
        end)
    end
end

-- ox_lib callbacks (server: a player asking; the first argument is the player)
if lib and lib.callback and lib.callback.register then
    local _register = lib.callback.register
    lib.callback.register = function(name, fn)
        if type(fn) ~= 'function' or not SERVER then return _register(name, fn) end
        return _register(name, guarded('callback', name, fn, function(src) return src end))
    end
end
