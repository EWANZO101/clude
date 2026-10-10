-- OPS Phone framework bridge: the registry every framework / inventory adapter adds itself to.
-- Built-in adapters live in bridge/server|client/frameworks and bridge/server|client/inventories; your own go in
-- bridge/custom/ (or come from another resource through the RegisterFrameworkAdapter export). See bridge/README.md.

Bridge = Bridge or {}
Bridge.Frameworks = Bridge.Frameworks or {}   -- [name] = adapter
Bridge.Inventories = Bridge.Inventories or {}
-- third-party resources the phone works with, by kind (phase 2): [kind][name] = adapter
Bridge.Integrations = Bridge.Integrations or { banking = {}, billing = {}, garage = {}, housing = {}, voice = {} }
Bridge.Version = 1

-- auto-detection order. Qbox before QBCore (Qbox also provides 'qb-core'), custom adapters before all of them.
Bridge.FrameworkOrder = { 'qbx', 'qb', 'esx', 'ox', 'nd', 'vrp' }
Bridge.InventoryOrder = { 'ox_inventory', 'qs-inventory', 'codem-inventory', 'tgiann-inventory', 'ps-inventory', 'lj-inventory', 'qb-inventory' }

-- integrations: auto-detection order per kind. When none of these runs, the framework's own handling is used
-- (e.g. esx_billing / owned_vehicles on ESX), then none.
Bridge.IntegrationOrder = {
    banking = { 'Renewed-Banking', 'okokBanking', 'qb-banking', 'esx_addonaccount' },   -- Renewed first: it also answers as qb-management / esx_society
    billing = { 'esx_billing', 'ox_core' },
    garage = { 'jg-advancedgarages', 'renzu_garage' },   -- esx_garage / qb-garages / qbx_garages use the framework's own table
    housing = { 'ps-housing', 'qbx_properties', 'qb-houses', 'esx_property' },
    voice = { 'pma-voice', 'saltychat', 'yaca-voice', 'mumble-voip', 'tokovoip_script' },
}
-- what the framework adapter must have to stand in for a kind
Bridge.IntegrationFallback = { banking = 'AddSocietyMoney', billing = 'GetBills', garage = 'GetVehicles', housing = 'GetHomes' }

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

--- Bridge.RegisterIntegration('billing', 'mybilling', { label, resource, detect = fn, GetBills = fn, … }) — see bridge/README.md
function Bridge.RegisterIntegration(kind, name, def)
    if not Bridge.Integrations[kind] then
        print(('^1[opslabs-phone] unknown integration kind "%s" (banking, billing, garage, housing, voice)^7'):format(tostring(kind)))
        return false
    end
    -- an integration with a resource is "detected" when that resource runs, unless it says otherwise
    if type(def) == 'table' and not def.detect and def.resource then
        def.detect = function() return Bridge.Started(def.resource) end
    end
    return register(Bridge.Integrations[kind], kind, name, def)
end

function Bridge.Started(res) return GetResourceState(res) == 'started' end

--- the server owner's choice: convar (setr opslabs_phone:framework qbx) > config.lua > 'auto'
--- (the name comes back lowercase, as typed second: integration names are resource names like Renewed-Banking)
function Bridge.Choice(kind)
    local cv = GetConvar('opslabs_phone:' .. kind, '')
    if cv ~= '' then return cv:lower(), 'convar', cv end
    local cfg = (kind == 'framework' and Config.Framework) or (kind == 'inventory' and Config.Inventory) or (Config.Integrations or {})[kind]
    if type(cfg) == 'string' and cfg ~= '' then return cfg:lower(), 'config', cfg end
    return 'auto', 'default', 'auto'
end
