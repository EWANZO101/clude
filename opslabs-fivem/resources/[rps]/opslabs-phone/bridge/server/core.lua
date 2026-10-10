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
local loadedHandlers, unloadedHandlers, jobHandlers, usableQueue = {}, {}, {}, {}
GlobalState['opslabs-phone:bridge'] = nil   -- clients wait for this run's choice, not the last one

-- money is whole dollars: round like ESX does (150.50 → 151); nil for nothing / negative
local function amountOf(x)
    x = tonumber(x) or 0
    if x <= 0 then return nil end
    return math.floor(x + 0.5)
end

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
    if a == nil then return fallback, b end   -- keep a reason given with nil (nil, 'Insufficient funds')
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

-- integrations (banking, billing, garage, housing, voice): the chosen resource, else the framework's own, else none
local integ = {}          -- [kind] = adapter (the framework adapter itself when it stands in)
local integName = {}      -- [kind] = name shown in the console / sent to clients

local function pickIntegration(kind)
    local list = Bridge.Integrations[kind]
    local fallbackFn = Bridge.IntegrationFallback[kind]
    local function frameworkOwn()
        if fallbackFn and fw[fallbackFn] then return fw, 'framework', 'framework' end
        return nil, 'none', 'none'
    end
    local choice, from, typed = Bridge.Choice(kind)
    -- the older setting: Config.Calls.UsePmaVoice = false meant no call audio
    if kind == 'voice' and choice == 'auto' and (Config.Calls or {}).UsePmaVoice == false then return nil, 'none', 'config' end
    if choice == 'none' then return nil, 'none', from end
    if choice == 'framework' then return frameworkOwn() end
    if choice ~= 'auto' then
        -- resource names are mixed case (Renewed-Banking): match the setting without caring about case
        local a
        for name, def in pairs(list) do if name:lower() == choice then a, choice = def, name end end
        if a and detects(a) then return a, choice, from end
        if a then
            log('3', '%s: "%s" is set in %s, but %s isn\'t running. Detecting another one instead.', kind, choice, from, a.resource or a.label)
        else
            log('1', '%s: "%s" (from %s) has no adapter. Detecting instead.', kind, typed, from)
        end
    end
    local function usable(a)
        -- adapters made for some frameworks only (e.g. a table layout) say so in `frameworks`
        if a.frameworks and not a.frameworks[fw.name] then return false end
        return detects(a)
    end
    for name, a in pairs(list) do
        if not a.builtin and usable(a) then return a, name, 'detected' end
    end
    for _, name in ipairs(Bridge.IntegrationOrder[kind] or {}) do
        local a = list[name]
        if a and usable(a) then return a, name, 'detected' end
    end
    return frameworkOwn()
end

local function startIntegrations()
    local parts = {}
    for _, kind in ipairs({ 'banking', 'billing', 'garage', 'housing', 'voice' }) do
        waitForStarting(Bridge.Integrations[kind])   -- a bank / garage resource still starting is waited for
        local a, name = pickIntegration(kind)
        if a and a ~= fw and a.init then
            local ok, r, e = pcall(a.init)
            if not ok or r == false then
                log('1', '%s: %s failed its check (%s). Using the framework\'s own instead.', kind, a.label, tostring(ok and e or r))
                if Bridge.IntegrationFallback[kind] and fw[Bridge.IntegrationFallback[kind]] then a, name = fw, 'framework' else a, name = nil, 'none' end
            end
        end
        integ[kind], integName[kind] = a, name
        parts[#parts + 1] = ('%s ^7%s^5'):format(kind, name == 'framework' and (fw.label .. ' (built in)') or (a and a.label or 'none'))
    end
    log('5', 'Integrations: %s', table.concat(parts, ' · '))
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
            -- each in its own thread, as separate event handlers would be: one that waits doesn't hold up the rest
            for _, fn in ipairs(loadedHandlers) do CreateThread(function() fn(src) end) end
        end)
    end
    for event in pairs(ev.job or {}) do
        AddEventHandler(event, function(...)
            local src = source(ev.job, event, ...)
            if src then for _, fn in ipairs(jobHandlers) do CreateThread(function() fn(src) end) end end
        end)
    end
    for event in pairs(ev.unloaded or {}) do
        AddEventHandler(event, function(...)
            local src = source(ev.unloaded, event, ...)
            if not src then return end
            recent[src] = nil
            for _, fn in ipairs(unloadedHandlers) do CreateThread(function() fn(src) end) end
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
    if not ok and fw.name ~= 'standalone' then
        -- a framework IS running but doesn't work (yet): never fall back to standalone — that would give every
        -- player a new phone keyed by their license and skip the item check. Load no phones and keep retrying.
        local picked = fw
        log('1', 'Framework %s was found but failed its check: %s', picked.label, tostring(err or 'unknown error'))
        log('1', 'No phones will load until it works. Retrying every 15 seconds.')
        fw = { name = picked.name, label = picked.label .. ' (not working)', status = 'failed', resource = picked.resource, events = picked.events }
        CreateThread(function()
            while true do
                Wait(15000)
                local okCall, r = pcall(picked.init)
                if okCall and r ~= false then
                    fw = picked
                    if invName == 'none' and picked.ItemCount then inv, invName = picked, 'framework' end
                    info.label, info.status = picked.label, picked.status
                    log('2', 'Framework %s works now: phones load again.', picked.label)
                    -- integrations that fall back to the framework (garage, ox_core accounts …) are picked again
                    startIntegrations()
                    info.integrations = integName
                    GlobalState['opslabs-phone:bridge'] = { framework = fw.name, inventory = invName, voice = integName.voice }
                    break
                end
            end
        end)
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
    startIntegrations()
    info = {
        framework = fw.name, label = fw.label, status = fw.status, how = source,
        version = resourceVersion(fw.resource), inventory = invName,
        inventoryLabel = inv and (inv == fw and (fw.label .. ' inventory') or inv.label) or 'none',
        integrations = integName,
    }
    -- the client picks the matching client adapters from this
    GlobalState['opslabs-phone:bridge'] = { framework = fw.name, inventory = invName, voice = integName.voice }

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
    amount = amountOf(amount)
    if not amount or not awaitReady() then return false end
    if amount == 0 then return true end
    return call(fw, 'AddMoney', false, src, amount, account or 'bank', reason) ~= false
end

--- takes money only if they have enough; returns true when taken
function FW.RemoveMoney(src, amount, account, reason)
    amount = amountOf(amount)
    account = account or 'bank'
    if not amount or not awaitReady() then return false end
    if amount == 0 then return true end
    if FW.GetMoney(src, account) < amount then return false end
    return call(fw, 'RemoveMoney', false, src, amount, account, reason) == true
end

--- offline characters (bank transfers to someone who isn't on): nil when this framework can't
function FW.GetOfflineMoney(identifier, account)
    if not awaitReady() then return nil end
    return call(fw, 'GetOfflineMoney', nil, tostring(identifier), account or 'bank')
end

function FW.AddOfflineMoney(identifier, amount, account)
    amount = amountOf(amount)
    if not amount or not awaitReady() then return false end
    if amount == 0 then return true end
    return call(fw, 'AddOfflineMoney', false, tostring(identifier), amount, account or 'bank') == true
end

function FW.RemoveOfflineMoney(identifier, amount, account)
    amount = amountOf(amount)
    if not amount or not awaitReady() then return false end
    if amount == 0 then return true end
    return call(fw, 'RemoveOfflineMoney', false, tostring(identifier), amount, account or 'bank') == true
end

--- money into a society / business account (bills to a job, carrier income)
local societyWarned = false
function FW.AddSocietyMoney(society, amount)
    amount = amountOf(amount)
    if not society or society == '' or not amount or not awaitReady() then return false end
    if amount == 0 then return true end
    local done = call(integ.banking, 'AddSocietyMoney', false, society, amount)
    if not done and not societyWarned then
        societyWarned = true
        log('3', 'Could not pay %s into the "%s" society account (banking: %s). Set Config.Integrations.banking to your banking resource.', amount, society, integName.banking or 'none')
    end
    return done == true
end

--- takes money from a society / business account, only if it has enough (a business paying an OPS invoice)
function FW.RemoveSocietyMoney(society, amount)
    amount = amountOf(amount)
    if not society or society == '' or not amount or not awaitReady() then return false end
    if amount == 0 then return true end
    return call(integ.banking, 'RemoveSocietyMoney', false, society, amount) == true
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
    return call(integ.billing, 'GetBills', {}, identifier)
end
function FW.TakeBill(identifier, id)
    if not awaitReady() then return nil end
    return call(integ.billing, 'TakeBill', nil, identifier, id)
end
function FW.RestoreBill(bill) if ready then call(integ.billing, 'RestoreBill', nil, bill) end end

--- pays one of the character's bills from their bank. Returns the bill, or nil and a message for the player.
--- Billing integrations that pay in one step (ox_core invoices) have PayBill(src, identifier, id) -> bill | nil, err;
--- the rest: take the bill off the list first (so it can't be paid twice), take the money, give it to who's owed.
local billLocks = {}   -- one payment per bill at a time (two fast taps, or the phone and another menu)

function FW.PayBill(src, identifier, id)
    if not awaitReady() or not integ.billing then return nil, 'Bills are not available' end
    local key = tostring(integName.billing) .. ':' .. tostring(id)
    if billLocks[key] then return nil, 'This bill is already being paid' end
    billLocks[key] = true
    local ok, bill, err = pcall(function()
        if integ.billing.PayBill then
            local b, e = call(integ.billing, 'PayBill', nil, src, identifier, id)
            if not b then return nil, e or 'Could not pay the bill' end
            return b
        end
        local b = call(integ.billing, 'TakeBill', nil, identifier, id)
        if not b then return nil, 'Bill not found or already paid' end
        if not FW.RemoveMoney(src, b.amount, Config.Bank.Account, 'Bill payment') then
            call(integ.billing, 'RestoreBill', nil, b)   -- put the bill back
            return nil, 'Insufficient funds'
        end
        -- whoever is owed couldn't be paid: give the money back and put the bill back, never lose it
        if call(integ.billing, 'SettleBill', false, b, src) ~= true then
            FW.AddMoney(src, b.amount, Config.Bank.Account, 'Bill payment refund')
            call(integ.billing, 'RestoreBill', nil, b)
            log('3', 'Bill %s (%s) could not be paid to %s: refunded and kept unpaid.', tostring(b.id), tostring(b.label), tostring(b.target or b.sender))
            return nil, "This bill can't be paid right now"
        end
        return b
    end)
    billLocks[key] = nil
    if not ok then return nil, 'Could not pay the bill' end
    return bill, err
end
function FW.SettleBill(bill, payer) if ready then call(integ.billing, 'SettleBill', nil, bill, payer) end end

--- garage: { { plate, model, type, name, stored, parking, pound, mileage, fuel, engine, body } }
function FW.GetVehicles(identifier)
    if not awaitReady() then return {} end
    return call(integ.garage, 'GetVehicles', {}, identifier)
end

--- housing: { { id, label, x, y, z, kind = 'owned' | 'rented' | 'key' } } — the character's homes (Maps → My Homes)
function FW.GetHomes(identifier)
    if not awaitReady() then return {} end
    return call(integ.housing, 'GetHomes', {}, identifier)
end

--- a phone payment in the banking resource's own history, if it keeps one (amount < 0 = money out)
function FW.LogTransaction(identifier, amount, label)
    if not ready or not integ.banking or integ.banking == fw then return end
    call(integ.banking, 'LogTransaction', nil, identifier, amount, label)
end

--- call audio connected on the server (SaltyChat, YaCA). Client-side systems (pma-voice …) ignore these.
function FW.VoiceCallStarted(callId, sources)
    if ready and integ.voice and integ.voice.ServerJoin then call(integ.voice, 'ServerJoin', nil, { id = callId, channel = callId }, sources) end
end
function FW.VoiceCallEnded(callId, sources)
    if ready and integ.voice and integ.voice.ServerLeave then call(integ.voice, 'ServerLeave', nil, { id = callId, channel = callId }, sources) end
end

--- the integration chosen for a kind ('banking' …): its name, or 'framework' / 'none'
function FW.Integration(kind) return integName[kind] or 'none' end

--- fn(src) when a character finishes loading / logs out (character switch). playerDropped is separate.
function FW.OnPlayerLoaded(fn) loadedHandlers[#loadedHandlers + 1] = fn end
function FW.OnPlayerUnloaded(fn) unloadedHandlers[#unloadedHandlers + 1] = fn end
--- fn(src) when a player's job changes during the session
function FW.OnJobChanged(fn) jobHandlers[#jobHandlers + 1] = fn end

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
