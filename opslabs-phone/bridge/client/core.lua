-- OPS Phone framework bridge (client): uses the client adapters matching what the server chose (GlobalState) and
-- turns each framework's "character loaded / logged out" and inventory events into FW.On… callbacks.

FW = {}

local loaded, unloaded, invChanged = {}, {}, {}
local invEvents = false
local function run(list, ...) for _, fn in ipairs(list) do pcall(fn, ...) end end

-- "something changed, item unknown" can arrive many times a second (QBCore player data): pass it on once per second
local unknownPending = false
local function inventoryChanged(item)
    if item ~= nil then return run(invChanged, item) end
    if unknownPending then return end
    unknownPending = true
    SetTimeout(1000, function() unknownPending = false run(invChanged, nil) end)
end

--- fn() when the character has loaded (also on a character switch)
function FW.OnPlayerLoaded(fn) loaded[#loaded + 1] = fn end
--- fn() when the character logs out (character switch / multichar menu)
function FW.OnPlayerUnloaded(fn) unloaded[#unloaded + 1] = fn end
--- fn(item) when the local player's items change; item is nil when the inventory can't say which
function FW.OnInventoryChanged(fn) invChanged[#invChanged + 1] = fn end
--- false when the inventory can't tell us about changes: callers re-check items themselves (e.g. on every open)
function FW.HasInventoryEvents() return invEvents end

local function hook(adapter, withInventory)
    if not adapter then return end
    local ev = adapter.events or {}
    if withInventory and (next(ev.inventory or {}) or adapter.watchInventory) then invEvents = true end
    for event, getArgs in pairs(ev.loaded or {}) do
        RegisterNetEvent(event, function(...) if getArgs == true or getArgs(...) ~= false then run(loaded) end end)
    end
    for event, getArgs in pairs(ev.unloaded or {}) do
        RegisterNetEvent(event, function(...) if getArgs == true or getArgs(...) ~= false then run(unloaded) end end)
    end
    for event, getItem in pairs(withInventory and ev.inventory or {}) do
        local handler = function(...)
            local ok, item = pcall(getItem, ...)
            if ok and item ~= false then inventoryChanged(item) end
        end
        -- local events (another client resource) and net events (from the server) both reach the phone
        if (adapter.localEvents or {})[event] then AddEventHandler(event, handler) else RegisterNetEvent(event, handler) end
    end
    -- adapters without events can watch the inventory themselves: watchInventory(changed) calls changed(item)
    if withInventory and adapter.watchInventory then pcall(adapter.watchInventory, inventoryChanged) end
end

CreateThread(function()
    -- the server decides (it can check the framework works); wait for it, then pick the same names here
    local chosen
    for _ = 1, 600 do
        chosen = GlobalState['opslabs-phone:bridge']
        if chosen then break end
        Wait(100)
    end
    chosen = chosen or {}
    local fwName, invName = chosen.framework or 'standalone', chosen.inventory or 'none'
    local fwA = Bridge.Frameworks[fwName]
    if not fwA then
        print(('^3[opslabs-phone] no client adapter for framework "%s": character switches are not detected (add bridge/custom/client/%s.lua)^7'):format(fwName, fwName))
        fwA = Bridge.Frameworks.standalone
    end
    hook(fwA, invName == 'framework')
    local invA = Bridge.Inventories[invName]
    if invName ~= 'framework' and invName ~= 'none' and not invA then
        print(('^3[opslabs-phone] no client adapter for inventory "%s": the phone item is checked each time the phone opens^7'):format(invName))
    end
    hook(invA, true)
end)
