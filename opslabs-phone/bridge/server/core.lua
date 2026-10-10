-- OPS Phone framework bridge (server): picks the framework and inventory adapters, checks they work, and exposes
-- them to the rest of the phone as FW.* — the only way phone code reaches the framework. Nothing outside bridge/
-- knows which framework the server runs.
--
-- Choice: Config.Framework / Config.Inventory in config.lua, or a convar (setr opslabs_phone:framework qbx), default
-- 'auto'. A framework that is missing or fails its check never stops the phone: it falls back to standalone.

FW = {}

local fw, inv            -- the chosen adapters (inv may be the framework itself: 'framework', or nil: 'none')
local invName = 'none'
local ready = false
local info = {}
local loadedHandlers, unloadedHandlers, usableQueue = {}, {}, {}
GlobalState['opslabs-phone:bridge'] = nil   -- clients wait for this run's choice, not the last one

local function log(colour, msg, ...) print(('^%s[opslabs-phone] ' .. msg .. '^7'):format(colour, ...)) end

-- every adapter call goes through here: an adapter error is reported once and never breaks the phone
local warned = {}
local function call(adapter, fn, fallback, ...)
    local f = adapter and adapter[fn]
    if not f then return fallback end
    local ok, a, b = pcall(f, ...)
    if not ok then
        local key = adapter.name .. '.' .. fn
        if not warned[key] then
            warned[key] = true
            log('1', '%s adapter: %s failed (reported once): %s', adapter.label, fn, tostring(a))
        end
        return fallback
    end
    if a == nil then return fallback end
    return a, b
end

local function awaitReady()
    if ready then return true end
    if not coroutine.isyieldable() then return false end
    for _ = 1, 300 do
        Wait(100)
        if ready then return true end
    end
    return ready
end

local function resourceVersion(res)
    local v = res and GetResourceMetadata(res, 'version', 0)
    return v and v ~= '' and v or nil
end

-- frameworks still starting (a restart, or no ensure order): wait for them like any dependency would
local function waitForStarting(list)
    for _ = 1, 150 do
        local starting = false
        for _, a in pairs(list) do
            if a.resource and GetResourceState(a.resource) == 'starting' then starting = true break end
        end
        if not starting then return end
        Wait(100)
    end
end

local function detects(a) return a.detect and call(a, 'detect', false) == true end

local function pickFramework()
    local choice, from = Bridge.Choice('framework')
    if choice ~= 'auto' then
        -- an adapter from another resource (RegisterFrameworkAdapter export) may arrive a moment later
        for _ = 1, 100 do
            if Bridge.Frameworks[choice] then break end
            Wait(100)
        end
        if Bridge.Frameworks[choice] then return Bridge.Frameworks[choice], from end
        local names = {}
        for n in pairs(Bridge.Frameworks) do names[#names + 1] = n end
        table.sort(names)
        log('1', 'Framework "%s" (from %s) has no adapter. Known: %s. Detecting automatically instead.', choice, from, table.concat(names, ', '))
    end
    waitForStarting(Bridge.Frameworks)
    for _, a in pairs(Bridge.Frameworks) do
        if not a.builtin and detects(a) then return a, 'detected' end        -- your own adapters win
    end
    for _, name in ipairs(Bridge.FrameworkOrder) do
        local a = Bridge.Frameworks[name]
        if a and detects(a) then return a, 'detected' end
    end
    for res, label in pairs(Bridge.Unsupported) do
        if Bridge.Started(res) then
            log('3', '%s is running, but OPS Phone has no adapter for it. Running standalone — see bridge/README.md to add one.', label)
        end
    end
    return Bridge.Frameworks.standalone, 'fallback'
end

local function pickInventory()
    local choice, from = Bridge.Choice('inventory')
    if choice == 'none' then return nil, 'none', from end
    if choice == 'framework' then return fw, 'framework', from end
    if choice ~= 'auto' then
        if Bridge.Inventories[choice] then return Bridge.Inventories[choice], choice, from end
        log('1', 'Inventory "%s" (from %s) has no adapter. Detecting automatically instead.', choice, from)
    end
    waitForStarting(Bridge.Inventories)
    for name, a in pairs(Bridge.Inventories) do
        if not a.builtin and detects(a) then return a, name, 'detected' end
    end
    for _, name in ipairs(Bridge.InventoryOrder) do
        local a = Bridge.Inventories[name]
        if a and detects(a) then return a, name, 'detected' end
    end
    if fw.ItemCount then return fw, 'framework', 'detected' end           -- e.g. the ESX inventory
    return nil, 'none', 'fallback'
end

local function hookEvents()
    local recent = {}
    local function source(map, event, ...)
        local ok, src = pcall(map[event], ...)
        if not ok then log('1', '%s adapter: reading the player from %s failed: %s', fw.label, event, tostring(src)) return nil end
        return tonumber(src)
    end
    local ev = fw.events or {}
    for event in pairs(ev.loaded or {}) do
        AddEventHandler(event, function(...)
            local src = source(ev.loaded, event, ...)
            -- frameworks that fire both their own and a compatibility event: handle it once
            if not src or (recent[src] and GetGameTimer() - recent[src] < 3000) then return end
            recent[src] = GetGameTimer()
            for _, fn in ipairs(loadedHandlers) do pcall(fn, src) end
        end)
    end
    for event in pairs(ev.unloaded or {}) do
        AddEventHandler(event, function(...)
            local src = source(ev.unloaded, event, ...)
            if not src then return end
            recent[src] = nil
            for _, fn in ipairs(unloadedHandlers) do pcall(fn, src) end
        end)
    end
end

local function start()
    local source
    fw, source = pickFramework()
    local ok, err = true, nil
    if fw.init then
        local okCall, r, e = pcall(fw.init)
        ok, err = okCall and r ~= false, okCall and e or r
    end
    if not ok then
        log('1', 'Framework %s was found but failed its check: %s', fw.label, tostring(err or 'unknown error'))
        log('1', 'Running STANDALONE so the phone keeps working. Fix the error above and restart opslabs-phone.')
        fw, source = Bridge.Frameworks.standalone, 'fallback'
        if fw.init then pcall(fw.init) end
    end

    local from
    inv, invName, from = pickInventory()
    if inv and inv ~= fw and inv.init then
        local okCall, r, e = pcall(inv.init)
        if not okCall or r == false then
            log('1', 'Inventory %s failed its check: %s — falling back to the framework inventory.', inv.label, tostring(okCall and e or r))
            inv, invName = fw.ItemCount and fw or nil, fw.ItemCount and 'framework' or 'none'
        end
    end

    hookEvents()
    info = {
        framework = fw.name, label = fw.label, status = fw.status, how = source,
        version = resourceVersion(fw.resource), inventory = invName,
        inventoryLabel = inv and (inv == fw and (fw.label .. ' inventory') or inv.label) or 'none',
    }
    -- the client picks the matching client adapters from this
    GlobalState['opslabs-phone:bridge'] = { framework = fw.name, inventory = invName }

    local statusText = ({ verified = '^2verified^7', experimental = '^3experimental — not yet tested on a live server^7', custom = '^5custom adapter^7' })[fw.status] or fw.status
    log('5', 'Framework: ^7%s%s ^5(%s) · %s', fw.label, info.version and (' ' .. info.version) or '', source, statusText)
    log('5', 'Inventory: ^7%s ^5(%s)', info.inventoryLabel, from)
    if fw.name == 'standalone' then
        log('3', 'Standalone: identifiers are FiveM licenses, there is no money or jobs. Set Config.Framework if this is wrong.')
    end
    if invName == 'none' and Config.RequireItem then
        log('3', 'No inventory found: Config.RequireItem is ignored and everyone can open the phone.')
    end

    ready = true
    -- names of players who haven't logged in since this version, from the framework's own character table
    if fw.BackfillNames then
        CreateThread(function()
            while not DatabaseReady do Wait(500) end
            local ok, n = pcall(fw.BackfillNames)
            if ok and (tonumber(n) or 0) > 0 then log('5', 'Saved the character names of %d phone owners from %s.', n, fw.label) end
        end)
    end
    for _, q in ipairs(usableQueue) do FW.UsableItem(q[1], q[2]) end
    usableQueue = nil
    TriggerEvent('opslabs-phone:bridgeReady', info)
end

CreateThread(start)

---------------------------------------------------------------------------
-- FW: what the phone calls
---------------------------------------------------------------------------

function FW.Ready() return ready end
function FW.Info() return info end
function FW.Await() return awaitReady() end

--- { identifier, name, firstname, lastname, job = { name, label, grade = { level, name } } } or nil
function FW.Player(src)
    src = tonumber(src)
    if not src or not awaitReady() then return nil end
    local p = call(fw, 'GetPlayer', nil, src)
    if type(p) ~= 'table' or not p.identifier then return nil end
    p.identifier = tostring(p.identifier)
    if not p.name or p.name == '' then
        p.name = (p.firstname and (p.firstname .. ' ' .. (p.lastname or ''))) or GetPlayerName(src)
    end
    return p
end

function FW.Identifier(src)
    local p = FW.Player(src)
    return p and p.identifier or nil
end

function FW.Name(src)
    local p = FW.Player(src)
    return p and p.name or GetPlayerName(src)
end

function FW.Job(src)
    local p = FW.Player(src)
    return p and p.job and p.job.name or nil
end

function FW.JobLabel(src)
    local p = FW.Player(src)
    return p and p.job and p.job.label or nil
end

--- online player with this identifier, or nil
function FW.SourceOf(identifier)
    if not identifier or not awaitReady() then return nil end
    identifier = tostring(identifier)
    local s = call(fw, 'GetSource', nil, identifier)
    if s then return tonumber(s) end
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if FW.Identifier(src) == identifier then return src end
    end
    return nil
end

--- admin: the opslabs.admin ACE on any framework, or the framework's own admin check (groups = ESX-style groups)
function FW.IsAdmin(src, groups)
    if IsPlayerAceAllowed(src, 'opslabs.admin') then return true end
    if not awaitReady() then return false end
    return call(fw, 'IsAdmin', false, src, groups or {}) == true
end

-- money: account 'bank' or 'cash'
function FW.GetMoney(src, account)
    if not awaitReady() then return 0 end
    return tonumber(call(fw, 'GetMoney', 0, src, account or 'bank')) or 0
end

function FW.AddMoney(src, amount, account, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or not awaitReady() then return false end
    return call(fw, 'AddMoney', false, src, amount, account or 'bank', reason) ~= false
end

--- takes money only if they have enough; returns true when taken
function FW.RemoveMoney(src, amount, account, reason)
    amount = math.floor(tonumber(amount) or 0)
    account = account or 'bank'
    if amount <= 0 or not awaitReady() then return false end
    if FW.GetMoney(src, account) < amount then return false end
    return call(fw, 'RemoveMoney', false, src, amount, account, reason) == true
end

--- offline characters (bank transfers to someone who isn't on): nil when this framework can't
function FW.GetOfflineMoney(identifier, account)
    if not awaitReady() then return nil end
    return call(fw, 'GetOfflineMoney', nil, tostring(identifier), account or 'bank')
end

function FW.AddOfflineMoney(identifier, amount, account)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or not awaitReady() then return false end
    return call(fw, 'AddOfflineMoney', false, tostring(identifier), amount, account or 'bank') == true
end

function FW.RemoveOfflineMoney(identifier, amount, account)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or not awaitReady() then return false end
    return call(fw, 'RemoveOfflineMoney', false, tostring(identifier), amount, account or 'bank') == true
end

--- money into a society / business account (bills to a job, carrier income)
local societyWarned = false
function FW.AddSocietyMoney(society, amount)
    amount = math.floor(tonumber(amount) or 0)
    if not society or society == '' or amount <= 0 or not awaitReady() then return false end
    local done = call(fw, 'AddSocietyMoney', false, society, amount)
    if not done and not societyWarned then
        societyWarned = true
        log('3', 'Could not pay %s into the "%s" society account: %s has no society account integration.', amount, society, fw.label)
    end
    return done == true
end

--- takes money from a society / business account, only if it has enough (a business paying an OPS invoice)
function FW.RemoveSocietyMoney(society, amount)
    amount = math.floor(tonumber(amount) or 0)
    if not society or society == '' or amount <= 0 or not awaitReady() then return false end
    return call(fw, 'RemoveSocietyMoney', false, society, amount) == true
end

-- items: the detected inventory, or the framework's own
local function invOk() return inv ~= nil and awaitReady() end

function FW.HasInventory() return awaitReady() and inv ~= nil end

function FW.ItemCount(src, item)
    if not invOk() then return 0 end
    return tonumber(call(inv, 'ItemCount', 0, src, item)) or 0
end

function FW.AddItem(src, item, count, metadata)
    if not invOk() then return false end
    return call(inv, 'AddItem', false, src, item, count or 1, metadata) ~= false
end

function FW.RemoveItem(src, item, count)
    if not invOk() then return false end
    return call(inv, 'RemoveItem', false, src, item, count or 1) ~= false
end

--- run handler(src) when a player uses this item (queued until the adapters are chosen)
function FW.UsableItem(item, handler)
    if not ready then usableQueue[#usableQueue + 1] = { item, handler } return end
    local function run(src) handler(tonumber(src)) end
    if fw.UsableItem and call(fw, 'UsableItem', false, item, run) ~= false then return end
    if inv and inv ~= fw and inv.UsableItem then call(inv, 'UsableItem', false, item, run) end
end

--- framework notification (falls back to ox_lib's)
function FW.Notify(src, message, kind)
    if ready and call(fw, 'Notify', false, src, message, kind or 'inform') then return end
    TriggerClientEvent('ox_lib:notify', src, { description = message, type = kind or 'inform' })
end

--- bills: { list(identifier) -> { {id, label, amount, target} }, take(identifier, id) -> bill|nil, restore(bill), settle(bill) }
function FW.GetBills(identifier)
    if not awaitReady() then return {} end
    return call(fw, 'GetBills', {}, identifier)
end
function FW.TakeBill(identifier, id)
    if not awaitReady() then return nil end
    return call(fw, 'TakeBill', nil, identifier, id)
end
function FW.RestoreBill(bill) if ready then call(fw, 'RestoreBill', nil, bill) end end
function FW.SettleBill(bill) if ready then call(fw, 'SettleBill', nil, bill) end end

--- garage: { { plate, model, type, name, stored, parking, pound, mileage, fuel, engine, body } }
function FW.GetVehicles(identifier)
    if not awaitReady() then return {} end
    return call(fw, 'GetVehicles', {}, identifier)
end

--- fn(src) when a character finishes loading / logs out (character switch). playerDropped is separate.
function FW.OnPlayerLoaded(fn) loadedHandlers[#loadedHandlers + 1] = fn end
function FW.OnPlayerUnloaded(fn) unloadedHandlers[#unloadedHandlers + 1] = fn end

---------------------------------------------------------------------------
-- exports: adapters and info for other resources
---------------------------------------------------------------------------

-- exports['opslabs-phone']:RegisterFrameworkAdapter('myfw', { detect = ..., GetPlayer = ..., ... })
-- (set Config.Framework = 'myfw' so the phone waits for it; auto-detection runs as the phone starts)
exports('RegisterFrameworkAdapter', function(name, def)
    if ready then log('3', 'Framework adapter "%s" registered after start-up: restart opslabs-phone (or set Config.Framework = "%s").', tostring(name), tostring(name)) end
    return Bridge.RegisterFramework(name, def)
end)
exports('RegisterInventoryAdapter', function(name, def) return Bridge.RegisterInventory(name, def) end)
exports('GetBridgeInfo', function() return info end)

-- /opsphone_bridge (console / admins): what was detected
RegisterCommand('opsphone_bridge', function(src)
    if src ~= 0 and not FW.IsAdmin(src, { 'admin', 'superadmin' }) then return end
    local msg = ('framework %s (%s, %s, %s) · inventory %s'):format(info.label or '?', info.framework or '?', info.status or '?', info.how or '?', info.inventoryLabel or '?')
    if src == 0 then log('5', '%s', msg) else FW.Notify(src, msg, 'inform') end
end, false)
