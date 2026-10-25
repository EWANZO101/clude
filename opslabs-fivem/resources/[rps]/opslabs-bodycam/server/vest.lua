-- The black vest: usable item (framework, or ox_inventory's item export), the /vest command and the item check.
-- What you see (vest + camera props) is client/vest.lua.

local V = Config.Vest or {}
if V.Enabled == false then return end

local function use(src, by)
    src = tonumber(src)
    if src then TriggerClientEvent('opslabs-bodycam:useVest', src, by) end
end

CreateThread(function()
    Wait(1500)      -- after Bridge.Init (server/main.lua)
    if V.Item and V.Item ~= '' then
        if Bridge.UsableItem(V.Item, function(src) use(src, 'item') end) then
            print(('[opslabs-bodycam] Vest item: %s (%s)'):format(V.Item, Bridge.name))
        else
            print(('[opslabs-bodycam] Vest item: %s — add  server = { export = \'opslabs-bodycam.useVest\' }  to its ox_inventory entry'):format(V.Item))
        end
    end
end)

-- ox_inventory: ['ops_vest'] = { …, server = { export = 'opslabs-bodycam.useVest' } }  (servers without a framework)
exports('useVest', function(event, _, inventory)
    if event == 'usingItem' and inventory and inventory.id then use(inventory.id, 'item') end
end)

RegisterNetEvent('opslabs-bodycam:vestCommand', function(wantOn)
    local src = source
    if wantOn and V.CommandNeedsAccess ~= false then
        local ok = Bridge.Eligible(src)
        if not ok and not (V.Item and V.Item ~= '' and Bridge.HasItem(src, V.Item)) then
            return TriggerClientEvent('opslabs-bodycam:notify', src, 'Only officers issued a bodycam can put the vest on', 'error')
        end
    end
    use(src, 'command')
end)

RegisterNetEvent('opslabs-bodycam:vestCheck', function()
    local src = source
    if V.Item and V.Item ~= '' and not Bridge.HasItem(src, V.Item) then TriggerClientEvent('opslabs-bodycam:takeOffVest', src) end
end)

-- other scripts can read it: Player(src).state.opsVest
RegisterNetEvent('opslabs-bodycam:vestState', function(on) Player(source).state:set('opsVest', on == true, true) end)
