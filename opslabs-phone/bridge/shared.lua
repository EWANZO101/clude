-- OPS Phone framework bridge: the registry every framework / inventory adapter adds itself to.
-- Built-in adapters live in bridge/server|client/frameworks and bridge/server|client/inventories; your own go in
-- bridge/custom/ (or come from another resource through the RegisterFrameworkAdapter export). See bridge/README.md.

Bridge = Bridge or {}
Bridge.Frameworks = Bridge.Frameworks or {}   -- [name] = adapter
Bridge.Inventories = Bridge.Inventories or {}
Bridge.Version = 1

-- auto-detection order. Qbox before QBCore (Qbox also provides 'qb-core'), custom adapters before all of them.
Bridge.FrameworkOrder = { 'qbx', 'qb', 'esx', 'ox', 'nd', 'vrp' }
Bridge.InventoryOrder = { 'ox_inventory', 'qs-inventory', 'codem-inventory', 'tgiann-inventory', 'ps-inventory', 'lj-inventory', 'qb-inventory' }

-- frameworks we recognise but don't support: say so instead of quietly running standalone
Bridge.Unsupported = {
    essentialmode = 'EssentialMode (replaced by ESX Legacy years ago)',
    vorp_core = 'VORP (RedM)',
    ['rsg-core'] = 'RSG Core (RedM)',
    ['qbr-core'] = 'QBR Core (RedM)',
}

local function register(list, kind, name, def)
    if type(name) ~= 'string' or name == '' or type(def) ~= 'table' then
        print(('^1[opslabs-phone] %s adapter not registered: it needs a name and a table^7'):format(kind))
        return false
    end
    def.name = name
    def.label = def.label or name
    def.status = def.status or 'custom'   -- 'verified' (tested on a live server) | 'experimental' | 'custom'
    if list[name] and list[name].builtin and not def.builtin then
        print(('^3[opslabs-phone] custom %s adapter "%s" replaces the built-in one^7'):format(kind, name))
    end
    list[name] = def
    return true
end

--- Bridge.RegisterFramework('myfw', { label, detect = fn, init = fn, GetPlayer = fn, ... })
function Bridge.RegisterFramework(name, def) return register(Bridge.Frameworks, 'framework', name, def) end

--- Bridge.RegisterInventory('myinv', { label, detect = fn, ItemCount = fn, AddItem = fn, RemoveItem = fn })
function Bridge.RegisterInventory(name, def) return register(Bridge.Inventories, 'inventory', name, def) end

function Bridge.Started(res) return GetResourceState(res) == 'started' end

--- the server owner's choice: convar (setr opslabs_phone:framework qbx) > config.lua > 'auto'
function Bridge.Choice(kind)
    local cv = GetConvar('opslabs_phone:' .. kind, '')
    if cv ~= '' then return cv:lower(), 'convar' end
    local cfg = kind == 'framework' and Config.Framework or Config.Inventory
    if type(cfg) == 'string' and cfg ~= '' then return cfg:lower(), 'config' end
    return 'auto', 'default'
end
